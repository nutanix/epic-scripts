#!/usr/bin/bash

set -ex

#------------------------------------------------------------------------------

# Copyright (c) 2023 Nutanix Inc. All rights reserved.
#
# Maintainer:   Jon Kohler (jon@nutanix.com)
# Contributors: Scott Fadden
#               Charles Sharp
#               Kyle Anderson

#------------------------------------------------------------------------------

## About
# This script is used to manage data cloning and out-of-system backups for
# Epic's Operational Database, based on InterSystems IRIS, when running on
# top of Nutanix AOS storage and Nutanix Acropolis Hypervisor (AHV).
#
# This script is intended to be a functional sample to assist with managing
# backups in a production Epic ODB implementation. Modifications will be
# required to "personalize" this script to the target environment.
#
# This script is designed to run within a RHEL VM that does *not* run Epic
# ODB itself, but rather acts as an "utility" VM to both schedule the execution
# of this script as well as act as the "backup target" for your chosen 3rd
# party backup software.
#
# This "utility" VM must to be run in the same AHV cluster as the Epic ODB
# instances to be backed up, so that we can mount the volume group(s) in a
# hot-add manner.
#
# The script is designed to handle a single Epic environment at a time, such
# that you can have multiple instantiations of this same script to manage the
# various Epic environments (e.g. PRD, TST, RPT, DR).

#------------------------------------------------------------------------------

## General Script Logic
# - Parse through existing VG (volume group) clones to see if we need to clean
#   up any legacy clones that have aged out
# - Freeze target IRIS instance (e.g. PRD, TST, RPT, DR)
# - Take a VG clone on Nutanix AOS
# - Thaw target IRIS instance
# - Mount VG clone to a "mount" VM
# - Kick off backup job in 3rd party out-of-system backup provider

#------------------------------------------------------------------------------

## Script Usage Instructions
# 1. Allow the userid running this script passwordless ssh access
#    to the CVM (configure through Prism) and the VM hosting
#    the target VG.
# 2. Add freeze and thaw commands for the target Epic environment.
# 3. Customize Environment Configuration Variables.
# 4. Add 3rd party backup command(s) and configure scheduling (e.g. crontab).
#      Note: You may wish to do the scheduling FROM the backup software itself.
#      In that case, skip this step and just use this script as a "pre-backup"
#      script that gets called as part of the backup job itself.

#------------------------------------------------------------------------------

# Environment Bootstrap Instructions
# 1. Setup AHV-MOUNT-VM as a RHEL8 or higher release.
# 2. Ensure SSH key exists on AHV-MOUNT-VM
#      Usually done with ssh-keygen
# 3. Ensure passwordless SSH setup between AHV-MOUNT-VM and TARGET_ODB_IP
#      Usually done with ssh-copyid
# 4. Add SSH public key to Nutanix cluster using the "lockdown mode" feature
#      Note: This does not require to set up "Full" lockdown mode, unless that
#      feature is desired by your organization
# 5. On AHV-MOUNT-VM, ensure dmidecode package is installed
#      RHEL8+: dnf install dmidecode
# 6. For persistency of MP[0] mount point over reboots, you can configure the
#    mount point in fstab; however, that is not required as the script will
#    simply remount it every time a new run is kicked off.
#      Note: If you do decide to use fstab, ensure that the "nofail" mount
#      option is used, so that if for whatever reason that volume is detached
#      and then AHV-MOUNT-VM is rebooted, it will avoid going into emergency
#      mode shell.

#------------------------------------------------------------------------------

## Environment Configuration Variables
# Configure these parameters to match the target environment. These are one time
# customizations for this script for any given environment

# Target ODB VM Details
# - This would be a VM on the same cluster as the AHV_MOUNT_VM
# - This is used to reach into that VM and do the freeze/thaw commands
TARGET_ODB_IP="a.b.c.d"
TARGET_ODB_ACCT="epicadm"
TARGET_ODB_ENV[0]="prd"

# Nutanix AOS Cluster Details
# - Use the IP of any AOS CVM (controller VM) in the target cluster
CVM_ACCT="nutanix"
CVM_IP="a.b.c.d"

# Utility/Mount VM Details
# - This is the VM in AHV that will mount the disk clones
# - This variable needs to be the exact name of the VM as it is listed in
#   Nutanix Prism.
AHV_MOUNT_VM="MOUNT-VM-NAME-HERE"

# Nutanix Volume Group (VG) name
# - This script assumes there is a single data volume group per backup
# - This VG may contain many individual vdisks and this script assumes that all
#   disk(s) within the Nutanix-side volume group are aggregated into
#   a Linux LVM2 volume group.
NTNX_SOURCE_VG[0]="EPIC-DATA-VG-NAME-HERE"


# Linux LVM Volume Group name
# - This is the name as listed in Linux "vgs" output.
LVM_VG[0]="prdvg"

# Mount point for volume group
# - This is the directory that the Linux LVM2 will be mounted on. This can be
#   different than how it is mounted within the ODB instance itself, and would
#   be the directory where you point the backup software to stream the data
#   from.
MP[0]="/mnt/backups/folder-name-here"

# Number of clones to keep
# - This is useful to keep a couple of the recent clones on the system, such
#   that if rapid recovery is needed, the snapshot/clone data is already
#   on-disk.
# - The script assumes that backups will be run nightly and that keeping
#   excessive copies is unproductive, given that the delta change rate day
#   over day makes older data less and less useful.
NUM_KEEP=2

#------------------------------------------------------------------------------

## Internal script variables and helpers

PREFIX_DATE=`date +%s`
ACLI="/usr/local/nutanix/bin/acli"

# Function:  getmyvmid
#   Match this hostname to the vm_uuid
getmyvmid () {
  vmid=`sudo /usr/sbin/dmidecode | grep UUID | awk '{ print $2 }'`
  echo $vmid
}

# Function: getmyvmname
#   Match this hostname to the vm name
getmyvmname () {
  ### What host am I on?
  vmname=`ssh ${CVM_ACCT}@${CVM_IP} "${ACLI} vm.list | grep ${1} " 2> /dev/null | awk '{ print $1}'`
  echo $vmname
}

myvmid=$(getmyvmid)
myvmname=$(getmyvmname $myvmid)
echo "This VM name is " $myvmname " vm_uuid " $myvmid

#------------------------------------------------------------------------------

## BEGIN SCRIPT OPERATIONS
echo "STEP 1: Cleanup environment"
# - Check for old clones and remove any over NUM_KEEP
# - Clone order is based on EPOCH timestamp name prefix

# Unmount cloned file system
# - Note: We pipe these to || true because on the very first run or a run where
#   the mount was previously detached separately, this would fail as the script
#   as we have set -ex configured.
echo "Unmount previous volumes and remove VG from LVM database"
umount ${MP[0]} || true
vgremove ${LVM_VG[0]} -y || true

# Get the list of block devices excluding /dev/sda and sr0 cd rom drive
# - Note: We also pipe this to || true as it would otherwise fail if the mount
#   was previously detached (or otherwise not present).
devices=$(lsblk -ndo NAME | grep -v sda | grep -v sr0) || true

# Add LVM devices dynamically
for device in $devices; do
  lvmdevices -y --deldev "/dev/$device"
done

# Detach existing clones from VM
echo "Detach previous clone(s), if already attached"
for i in `ssh ${CVM_ACCT}@${CVM_IP} "${ACLI} vg.list | grep 'copy-${TARGET_ODB_ENV[0]}' | awk '{ print $1 }'" 2> /dev/null`
do
  cnt=`ssh ${CVM_ACCT}@${CVM_IP} "${ACLI} vg.get ${i} | grep 'vm_uuid:.*${myvmid}' | wc -l " 2> /dev/null`
  echo "Count for " $i " is " $cnt
  if (( cnt > 0 )); then
      ret=`ssh ${CVM_ACCT}@${CVM_IP} "${ACLI} vg.detach_from_vm ${i} ${myvmname} " 2> /dev/null`
      echo "Detached clone " ${i} " Ret = " $ret
  fi
done

numclone=`ssh ${CVM_ACCT}@${CVM_IP} "${ACLI} vg.list | grep [0-9].*-copy-${TARGET_ODB_ENV[0]} | wc -l" 2> /dev/null`

# Delete expired clones
echo "Current Number of Clones " $numclone " for " ${TARGET_ODB_ENV[0]}
while(( numclone >= NUM_KEEP )); do
  rmvg=`ssh ${CVM_ACCT}@${CVM_IP} "${ACLI} vg.list | /usr/bin/grep [0-9].*-copy-${TARGET_ODB_ENV[0]} | /usr/bin/sort -n | /usr/bin/head -1 | /usr/bin/sed 's/  /\:/'"  2> /dev/null`
  echo "Removing VG " ${rmvg}
  echo  ${CVM_ACCT}@${CVM_IP} "/usr/bin/echo yes | ${ACLI} vg.delete ${rmvg}"
  ssh ${CVM_ACCT}@${CVM_IP} "/usr/bin/echo yes | ${ACLI} vg.delete ${rmvg}"
  numclone=`ssh ${CVM_ACCT}@${CVM_IP} ${ACLI} vg.list | grep [0-9].*-copy-${TARGET_ODB_ENV[0]} | wc -l`
done


#------------------------------------------------------------------------------

echo "STEP 2: Freeze target ODB"
ssh ${TARGET_ODB_ACCT}@${TARGET_ODB_IP} "echo -n "Freezing ${TARGET_ODB_ENV[0]}: " ; /epic/${TARGET_ODB_ENV[0]}/bin/instfreeze"
echo ""

#------------------------------------------------------------------------------

## Step 3: Clone the VG
echo "Creating new clone " ${PREFIX_DATE}-copy-${TARGET_ODB_ENV[0]}
ssh ${CVM_ACCT}@${CVM_IP} ${ACLI} vg.clone ${PREFIX_DATE}-copy-${TARGET_ODB_ENV[0]} clone_from_vg=${NTNX_SOURCE_VG[0]}

#------------------------------------------------------------------------------

## Step 4: Thaw target ODB
ssh ${TARGET_ODB_ACCT}@${TARGET_ODB_IP} "echo -n "Thawing ${TARGET_ODB_ENV[0]}: " ; /epic/${TARGET_ODB_ENV[0]}/bin/instthaw"
echo ""

#------------------------------------------------------------------------------

## Step 5: Mount the clone
# Attach new clone
echo "Attach " ${PREFIX_DATE}-copy-${TARGET_ODB_ENV[0]}
ssh ${CVM_ACCT}@${CVM_IP} "${ACLI} vg.attach_to_vm ${PREFIX_DATE}-copy-${TARGET_ODB_ENV[0]} ${AHV_MOUNT_VM}"

# Clean up LVM metadata
pvscan --cache

# Get the list of block devices excluding /dev/sda
devices=$(lsblk -ndo NAME | grep -v "sda" | grep -v sr0)

# Add LVM devices dynamically
for device in $devices; do
  lvmdevices -y --adddev "/dev/$device"
done

# Activate all availible LVM Volumes
vgchange -ay

# Get device name
dev_path=`/usr/sbin/lvdisplay ${LVM_VG[0]} | awk '{ if( $2 == "Path" ) print $3 }'`

# Mount the File System
/usr/bin/mount $dev_path ${MP[0]}
df
ret=`/usr/bin/df | grep "${MP[0]}" | wc -l`
if(( ret == 1 )); then
  echo "Backup file system ${MP[0]} is ready."
else
  echo "Backup file system ${MP[0]} did not mount properly"
  exit
fi

#------------------------------------------------------------------------------

echo "STEP 6: Kick off 3rd party out-of-system backup"
echo "Kick off backup for " ${PREFIX_DATE}-copy-${TARGET_ODB_ENV[0]}

# Note: See reference scripts directory for sample scripts that can be copy
# and pasted into this section of the script. The intended use is that once the
# clone is properly mounted on AHV-MOUNT-VM, the backup job needs to be queued
# up, so that the 3rd party backup system runs a file system backup to stream
# the contents of MP[0] mount directory to backup storage.

# Note: Alternatively, you can use this example script as a "pre-backup" script
# from the 3rd party backup system, which most/all vendors have the ability to
# do. This would then replace the need to schedule this with Linux crontab,
# such that the backup software would schedule and control the execution of all
# jobs.

#------------------------------------------------------------------------------

# TODOs
# - Make runtime variables script inputs (script.sh $1 $2 $3) to avoid customization
# - Expand error handling