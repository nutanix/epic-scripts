#!/usr/bin/bash

## Setup
# This script is designed to run on a Centos/Redhat VM
# that is used to mount clones of production VMs. This procedure is
# commonly used by a backup proxy or development system. 
#
# The VM needs to be run in the same AHV cluster as the volume 
# group to be backed up.
#
# To use this script
# 1. Allow the userid running this script paswordless ssh access 
#    to the CVM (configure through Prism) and the VM hosting 
#    the production VG.
# 2. Add freeze and thaw commands for the produciton application .
# 2. Customize configuration parameters (Search for TODO-1).
# 3. Add bacakup command (Search for TODO-3).
#
# Questions: Contact scott.fadden@nutanix.com 
#
# NOTE: Add error checking


######
# Conifugre these parameters to match your environment
# TODO-1
# ODB Server
APP_IP="10.0.0.110"
APP_ACCT="root"

# Nutanix Details
acct="nutanix"
CVIP="10.0.0.152"
backupVM="Centos1"

# Volume Groups to be cloned
vg[0]="app-vg1"
# Linux LVM Volume Group name
lvmvg[0]="prdvg"

# Mount point for volume group
mp[0]="/backup/prd01"

# Number of clones to keep  
num_keep=4

# End Customizations
####################

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
  vmname=`ssh ${acct}@${CVIP} "/usr/local/nutanix/bin/acli vm.list | grep ${1} " 2> /dev/null | awk '{ print $1}'`
  echo $vmname
}
myvmid=$(getmyvmid)
myvmname=$(getmyvmname $myvmid)
echo "This VM name is " $myvmname " vm_uuid "  $myvmid

## Step 1: Check for old clones and remove any over num_keep
# Clone order is based on EPOCH timestamp name prefix

# Unmount cloned file system
umount ${mp[0]}

# Detach existing clones from VM
echo "Detach previous clone"
for i in `ssh ${acct}@${CVIP} "/usr/local/nutanix/bin/acli vg.list | grep 'copy-${vg[0]}' | awk '{ print $1 }'" 2> /dev/null`
do
  cnt=`ssh ${acct}@${CVIP} "/usr/local/nutanix/bin/acli vg.get ${i} | grep 'vm_uuid:.*${myvmid}' | wc -l " 2> /dev/null`
  #echo "Count for " $i " is " $cnt
  if (( cnt > 0 )); then
      ret=`ssh ${acct}@${CVIP} "/usr/local/nutanix/bin/acli vg.detach_from_vm ${i} ${myvmname} " 2> /dev/null`
      echo "Detached clone " ${i} " Ret = " $ret
  fi
done

numclone=`ssh ${acct}@${CVIP} "/usr/local/nutanix/bin/acli vg.list | grep [0-9].*-copy-${vg[0]} | wc -l" 2> /dev/null`

# Delete expired clones
echo "Current Number of Clones " $numclone " for " ${vg[0]}
while(( numclone >= num_keep )); do
  rmvg=`ssh ${acct}@${CVIP} "/usr/local/nutanix/bin/acli vg.list | /usr/bin/grep [0-9].*-copy-${vg[0]} | /usr/bin/sort -n | /usr/bin/head -1 | /usr/bin/sed 's/  /\:/'"  2> /dev/null`
  echo "Removing VG " ${rmvg}
  echo  ${acct}@${CVIP} "/usr/bin/echo yes | /usr/local/nutanix/bin/acli vg.delete ${rmvg}"
  ssh ${acct}@${CVIP} "/usr/bin/echo yes | /usr/local/nutanix/bin/acli vg.delete ${rmvg}"
  numclone=`ssh ${acct}@${CVIP} /usr/local/nutanix/bin/acli vg.list | grep [0-9].*-copy-${vg[0]} | wc -l`
done

## Step 2: Freeze Application
# Replace the following line with application freeze command
# TODO-2
ssh ${APP_ACCT}@${APP_IP} "echo -n 'Pause Application on Server: ' ; /bin/hostname "
echo ""

## Step 3: Clone the VG
pre=`date +%s`
echo "Creating new clone " ${pre}-copy-${vg[0]}
ssh ${acct}@${CVIP} /usr/local/nutanix/bin/acli vg.clone ${pre}-copy-${vg[0]} clone_from_vg=${vg[0]}
   

## Step 4: Thaw Application
# Replace the following line with application thaw command
# TODO-2
ssh ${APP_ACCT}@${APP_IP} "echo -n "Resume the Application on Server: " ; /bin/hostname "
echo ""

## Step 5: Mount the clone

# Attach new clone
echo "Attach " ${pre}-copy-${vg[0]}
ssh ${acct}@${CVIP} "/usr/local/nutanix/bin/acli vg.attach_to_vm ${pre}-copy-${vg[0]} ${backupVM}"

# Clean up LVM metadata
pvscan --cache

# Get device name
dev_path=`/usr/sbin/lvdisplay ${lvmvg[0]} | awk '{ if( $2 == "Path" ) print $3 }'`

# Mount the File System
/usr/bin/mount $dev_path ${mp[0]}
df
ret=`/usr/bin/df | grep "${mp[0]}" | wc -l`
if(( ret == 1 )); then
  echo "Backup file system ${mp[0]} is ready."
else
  echo "Backup file system ${mp[0]} did not mount properly"
fi

## Step 6: Kick off backup
# TODO-3
# Add backup command here
echo "Add vendor specific backup command here"

