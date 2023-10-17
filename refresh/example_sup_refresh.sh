#!/usr/bin/bash

set -ex

#------------------------------------------------------------------------------

# Copyright (c) 2023 Nutanix Inc. All rights reserved.
#
# Maintainer:   Jon Kohler (jon@nutanix.com)
# Contributors: Charles Sharp

#------------------------------------------------------------------------------

## About
# This script is used to manage data cloning for refreshing SUP from PRD for
# Epic's Operational Database, based on InterSystems IRIS, when running on
# top of Nutanix AOS storage and Nutanix Acropolis Hypervisor (AHV).
#
# This script is intended to be a functional sample to assist with managing
# refreshes in a production Epic ODB implementation. Modifications will be
# required to "personalize" this script to the target environment.
#
# This script is designed to run within the SUP VM, which must be run in the
# same AHV cluster as the Epic ODB PRD instance, so that we can mount the
# volume group(s) in a hot-add manner. It is possible to have PRD and SUP in
# separate clusters; however, that scenario is not covered in this example.
#
# The script is designed to handle a single Epic environment at a time, e.g.
# PRD -> SUP; however, you can have multiple instantiations of this same script
# to manage the various Epic environments (e.g. SUP -> REL, etc).

## Environment Configuration Variables
# Configure these parameters to match the target environment. These are one time
# customizations for this script for any given environment

#------------------------------------------------------------------------------

# Environment Bootstrap Instructions
# 1. Ensure SSH key exists on SUP VM
#      reference: ssh-keygen
# 2. Ensure passwordless SSH setup between SUP VM and TARGET_ODB_IP
#      reference: ssh-copy-id 1.2.3.4 (TARGET_ODB_IP here)
# 3. Add SSH public key to Nutanix cluster using the "lockdown mode" feature
#      Note: This does not require to set up "Full" lockdown mode, unless that
#      feature is desired by your organization.
# 4. On SUP VM, ensure dmidecode and psmisc package is installed

#------------------------------------------------------------------------------

# Target ODB VM Details
# - This would be a VM on the same cluster as the AHV_MOUNT_VM
# - This is used to reach into that VM and do the freeze/thaw commands
TARGET_ODB_IP="1.2.3.4"
TARGET_ODB_ACCT="epicadm"
TARGET_ODB_ENV[0]="prd"

# Nutanix AOS Cluster Details
# - Use the IP of any AOS CVM (controller VM) in the target cluster
CVM_ACCT="nutanix"
CVM_IP="1.2.3.5"

# Nutanix Volume Group (VG) name
# - This script assumes there is a single data volume group per backup
# - This VG may contain many individual vdisks and this script assumes that all
#   disk(s) within the Nutanix-side volume group are aggregated into
#   a Linux LVM2 volume group.
TARGET_NTNX_VG[0]="prd-odb-data-nutanix-vg-name-here"

# Linux LVM Volume Group name
# - This is the name as listed in Linux "vgs" output.
# - For sup refreshes, we will be cloning the prd vg and renaming it, such
#   that we do not have conflicts, so we will need the logical name of each
#   group here.
PRD_LVM_VG[0]="prdvg"
SUP_LVM_VG[0]="supvg"

# Linux LVM Volume Group name
PRD_LVM_LV[0]="prd01lv"
SUP_LVM_LV[0]="sup01lv"

# Mount point for volume group
# - This is the directory that the Linux LVM2 will be mounted on. This can be
#   different than how it is mounted within the ODB instance itself, and would
#   be the directory where you point the backup software to stream the data
#   from.
MP[0]="/epic/sup01"

# Number of clones to keep
# - This is useful to keep a couple of the recent clones on the system, such
#   that if rapid recovery is needed, the snapshot/clone data is already
#   on-disk.
# - The script assumes that backups will be run nightly and that keeping
#   excessive copies is unproductive, given that the delta change rate day
#   over day makes older data less and less useful.
# - For sup refreshes, it does not usually make sense to keep any previous
#   clones around; however, if required, you can change this to keep them
#   on disk for a N amount of generations.
NUM_KEEP=0

###############################################################################
## Script Helpers - Error Checking
###############################################################################

ErrCheck() {
  if [[ $? -ne 0 ]]; then
    ERRMSG=$@
    echo "ERROR: $ERRMSG"
    echo "Exiting with failure"
    exit 1
  fi
}

###############################################################################
## Script Helpers
###############################################################################

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
# - Kill off any active processes that might prevent umount
# - Check for old clones and remove any over NUM_KEEP
# - Clone order is based on EPOCH timestamp name prefix

#######################################
#Debug - to see what process is using this directory
#fuser -m ${MP[0]}
#######################################
#Kill process
echo "$(date) === Kill Process ==="
#fuser -km ${MP[0]}
#fuser -km /epic/sup01
###--->Another /usr/sbin/fuser -u -k -9 -m ${MP[0]}
###--Best OPTION
sudo /usr/sbin/fuser -u -k -9 -m /dev/mapper/${SUP_LVM_VG[0]}-${SUP_LVM_LV[0]} ||true
ErrCheck

# Unmount cloned file system
# - Unmount previous volumes and remove VG from LVM database
# - Note: We pipe these to || true because on the very first run or a run where
#   the mount was previously detached separately, this would fail as the script
#   as we have set -ex configured.
echo "$(date) === umount file User Process ==="
sudo /usr/bin/umount ${MP[0]} || true
ErrCheck

# Deactivate VG
echo "$(date) === Deactivate the VG ==="
sudo /usr/sbin/vgchange -a n ${SUP_LVM_VG[0]} || true
ErrCheck

# Export VG
echo "$(date) === Export the VG ==="
sudo /usr/sbin/vgexport ${SUP_LVM_VG[0]} || true
ErrCheck

# Detach existing clones from VM
echo "Detach previous clone(s), if already attached"
for i in `ssh ${CVM_ACCT}@${CVM_IP} "${ACLI} vg.list | grep 'copy4sup-${TARGET_NTNX_VG[0]}' | awk '{ print $1 }'" 2> /dev/null`
do
  cnt=`ssh ${CVM_ACCT}@${CVM_IP} "${ACLI} vg.get ${i} | grep 'vm_uuid:.*${myvmid}' | wc -l " 2> /dev/null`
  echo "Count for " $i " is " $cnt
  if (( cnt > 0 )); then
      ret=`ssh ${CVM_ACCT}@${CVM_IP} "${ACLI} vg.detach_from_vm ${i} ${myvmname} " 2> /dev/null`
      echo "Detached clone " ${i} " Ret = " $ret
  fi
done

numclone=`ssh ${CVM_ACCT}@${CVM_IP} "${ACLI} vg.list | grep [0-9].*-copy4sup-${TARGET_NTNX_VG[0]} | wc -l" 2> /dev/null`

# Delete expired clones
echo "Current Number of Clones " $numclone " for " ${TARGET_NTNX_VG[0]}
while(( numclone > NUM_KEEP )); do
  rmvg=`ssh ${CVM_ACCT}@${CVM_IP} "${ACLI} vg.list | /usr/bin/grep [0-9].*-copy4sup-${TARGET_NTNX_VG[0]} | /usr/bin/sort -n | /usr/bin/head -1 | /usr/bin/sed 's/\s.*$//'"  2> /dev/null`
  echo "Removing VG " ${rmvg}
  echo  ${CVM_ACCT}@${CVM_IP} "/usr/bin/echo yes | ${ACLI} vg.delete ${rmvg}"
  ssh ${CVM_ACCT}@${CVM_IP} "/usr/bin/echo yes | ${ACLI} vg.delete ${rmvg}"
  numclone=`ssh ${CVM_ACCT}@${CVM_IP} ${ACLI} vg.list | grep [0-9].*-copy4sup-${TARGET_NTNX_VG[0]} | wc -l`
done

ErrCheck "Failed to remove old clones"


#------------------------------------------------------------------------------

echo "STEP 2: Freeze target ODB"
ssh ${TARGET_ODB_ACCT}@${TARGET_ODB_IP} "echo -n "Freezing ${TARGET_ODB_ENV[0]}: " ; /epic/${TARGET_ODB_ENV[0]}/bin/instfreeze"
echo ""

#------------------------------------------------------------------------------

echo "STEP 3: Clone the VG"
echo "Creating new clone " ${PREFIX_DATE}-copy4sup-${TARGET_NTNX_VG[0]}
ssh ${CVM_ACCT}@${CVM_IP} ${ACLI} vg.clone ${PREFIX_DATE}-copy4sup-${TARGET_NTNX_VG[0]} clone_from_vg=${TARGET_NTNX_VG[0]}

ErrCheck "Failed to clone the VG"

#------------------------------------------------------------------------------

echo "STEP 4: Thaw target ODB"
ssh ${TARGET_ODB_ACCT}@${TARGET_ODB_IP} "echo -n "Thawing ${TARGET_ODB_ENV[0]}: " ; /epic/${TARGET_ODB_ENV[0]}/bin/instthaw"
echo ""

ErrCheck "Failed to thaw target ODB"

#------------------------------------------------------------------------------

echo "STEP 5: Mount the clone"
# Attach new clone
echo "Attach " ${PREFIX_DATE}-copy4sup-${TARGET_NTNX_VG[0]}
ssh ${CVM_ACCT}@${CVM_IP} "${ACLI} vg.attach_to_vm ${PREFIX_DATE}-copy4sup-${TARGET_NTNX_VG[0]} ${myvmname}"

# Clean up LVM metadata
echo "$(date) === pvscan ==="
sudo /usr/sbin/pvscan --cache -v
ErrCheck "Failed to pvscan"

echo "$(date) === Rename VG ==="
sudo /usr/sbin/vgrename ${PRD_LVM_VG[0]} ${SUP_LVM_VG[0]}

echo "$(date) === Rename LV ==="
sudo /usr/sbin/lvrename ${SUP_LVM_VG[0]} ${PRD_LVM_LV[0]} ${SUP_LVM_LV[0]}

echo "$(date) === Activate VG ==="
sudo /usr/sbin/vgchange -a y ${SUP_LVM_VG[0]}
ErrCheck "Failed to Activate VG"

echo "$(date) === Mount Filesystem ==="
sudo /bin/mount /dev/mapper/${SUP_LVM_VG[0]}-${SUP_LVM_LV[0]} ${MP[0]} -v || true
df -h
ret=`/usr/bin/df | grep "${MP[0]}" | wc -l`
if(( ret == 1 )); then
  echo "Backup file system ${MP[0]} is ready."
else
  echo "Backup file system ${MP[0]} did not mount properly, waiting and trying again"
  sleep 30
  sudo /bin/mount /dev/mapper/${SUP_LVM_VG[0]}-${SUP_LVM_LV[0]} ${MP[0]} -v || true
  df -h
  ret=`/usr/bin/df | grep "${MP[0]}" | wc -l`
  ErrCheck "Failed to mount the clone"
fi

# Delete locks, which is required to start database on different system
echo "Delete lock (*.lck) files"
sudo /bin/find ${MP[0]} -name iris.lck -type f -exec rm -v {} \;
