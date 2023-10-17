#!/usr/bin/bash
# Author: Charles Sharp
# Date: 10-26-2021
# About: Backups

###############################################################################
## Environment Configuration Variables
# Configure these parameters to match the target environment
###############################################################################

# Target ODB VM Details
# - This would be a VM on the same cluster as the AHV_MOUNT_VM
# - This is used to reach into that VM and do the freeze/thaw commands
TARGET_ODB_IP="4.3.2.1-target-odb-here"
TARGET_ODB_ACCT="epicadm"
TARGET_ODB_ENV[0]="prd"
TARGET_ODB_FILEPATH[0]="epicfiles"

# Nutanix AOS Cluster Details
# - Use the IP of any AOS CVM (controller VM) in the target cluster
CVM_ACCT="nutanix"
CVM_IP="1.2.3.4-cvmiphere"

# Utility/Mount VM Details
# - This is the VM in AHV that will mount the disk clones
AHV_MOUNT_VM="MOUNT_VM_HERE3"

# Nutanix Volume Group (VG) name
# - This script assumes there is a single data volume group per backup
# - This VG may contain many individual vdisks and this script assumes that all
#   disk(s) within the Nutanix-side volume group are aggregated into
#   a Linux LVM2 volume group.
TARGET_NTNX_VG[0]="dr-odb-prdfiles"

# Linux LVM Volume Group name
LVM_VG[0]="drfilesvg"

# Mount point for volume group
MP[0]="/mnt/backup-nfs/RHEL-OS-DR/${TARGET_ODB_FILEPATH[0]}"

# Number of clones to keep
# - This is useful to keep a couple of the recent clones on the system, such
#   that if rapid recovery is needed, the snapshot/clone data is already
#   on-disk.
# - The script assumes that backups will be run nightly and that keeping
#   excessive copies is unproductive, given that the delta change rate day
#   over day makes older data less and less useful.
NUM_KEEP=1

###############################################################################
## Script Helpers - Error Checking
###############################################################################

ErrCheck() {
  if [[ $? -ne 0 ]]; then
    ERRMSG=$@
    echo "$(date)"
    #echo -e "$1 \n\nPlease check on $(AHV_MOUNT_VM) and veeam." | mailx -s "ODB Backup Error: backup-prd01.sh" -a /root/scripts/backup/cron.start-backup.log ADMIN_DL_HERE@domain.org
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

###############################################################################
## Backup - Stage - echo variables
###############################################################################

echo "$(date) === VM = ${myvmname} and vm_uuid = ${myvmid} ==="

###############################################################################
## Backup - Stage - stop - nfs-server - not using NFS at the mount
###############################################################################

echo "$(date) === Stop nfs-server ==="
/usr/bin/systemctl stop nfs-server
#ErrCheck "Failed to stop user process"
sleep 10

###############################################################################
## Backup - Stage - umount
###############################################################################
echo "$(date) === umount file User Process ==="

# Unmount cloned file system
/usr/bin/umount ${MP[0]}


###############################################################################
## Backup - Stage - Deactive the VG
###############################################################################
echo "$(date) === Deactive the VG ==="
/usr/sbin/vgchange -a n ${LVM_VG[0]}
#ErrCheck "Failed to deactive the VG"


###############################################################################
## Backup - Stage - Export
###############################################################################
echo "$(date) === Export  the VG ==="
/usr/sbin/vgexport ${LVM_VG[0]}
#ErrCheck "Failed to export the VG"

###############################################################################
## Backup - Stage - Check for old clones and remove any over NUM_KEEP
###############################################################################

## Step 1: Check for old clones and remove any over NUM_KEEP
# Clone order is based on EPOCH timestamp name prefix

# Detach existing clones from VM
echo "Detach previous clone"
for i in `ssh ${CVM_ACCT}@${CVM_IP} "${ACLI} vg.list | grep 'copy-${TARGET_NTNX_VG[0]}' | awk '{ print $1 }'" 2> /dev/null`
do
  cnt=`ssh ${CVM_ACCT}@${CVM_IP} "${ACLI} vg.get ${i} | grep 'vm_uuid:.*${myvmid}' | wc -l " 2> /dev/null`
  #echo "Count for " $i " is " $cnt
  if (( cnt > 0 )); then
      ret=`ssh ${CVM_ACCT}@${CVM_IP} "${ACLI} vg.detach_from_vm ${i} ${myvmname} " 2> /dev/null`
      echo "Detached clone " ${i} " Ret = " $ret
  fi
done

numclone=`ssh ${CVM_ACCT}@${CVM_IP} "${ACLI} vg.list | grep [0-9].*-copy-${TARGET_NTNX_VG[0]} | wc -l" 2> /dev/null`

# Delete expired clones
echo "Current Number of Clones " $numclone " for " ${TARGET_NTNX_VG[0]}
while(( numclone >= NUM_KEEP )); do
  rmvg=`ssh ${CVM_ACCT}@${CVM_IP} "${ACLI} vg.list | /usr/bin/grep [0-9].*-copy-${TARGET_NTNX_VG[0]} | /usr/bin/sort -n | /usr/bin/head -1 | /usr/bin/sed 's/\s.*$//'"  2> /dev/null`
  echo "Removing VG " ${rmvg}
  echo  ${CVM_ACCT}@${CVM_IP} "/usr/bin/echo yes | ${ACLI} vg.delete ${rmvg}"
  ssh ${CVM_ACCT}@${CVM_IP} "/usr/bin/echo yes | ${ACLI} vg.delete ${rmvg}"
  numclone=`ssh ${CVM_ACCT}@${CVM_IP} ${ACLI} vg.list | grep [0-9].*-copy-${TARGET_NTNX_VG[0]} | wc -l`
done

ErrCheck "Failed to remove old clones"

###############################################################################
## Backup - Stage - Clone the VG
###############################################################################
## Step 3: Clone the VG
echo "Creating new clone " ${PREFIX_DATE}-copy-${TARGET_NTNX_VG[0]}
ssh ${CVM_ACCT}@${CVM_IP} ${ACLI} vg.clone ${PREFIX_DATE}-copy-${TARGET_NTNX_VG[0]} clone_from_vg=${TARGET_NTNX_VG[0]}

ErrCheck "Failed to clone the VG"

###############################################################################
## Backup - Stage - Attached new clone
###############################################################################
# Attach new clone
echo "Attach " ${PREFIX_DATE}-copy-${TARGET_NTNX_VG[0]}
ssh ${CVM_ACCT}@${CVM_IP} "${ACLI} vg.attach_to_vm ${PREFIX_DATE}-copy-${TARGET_NTNX_VG[0]} ${AHV_MOUNT_VM}"

###############################################################################
## Backup - Stage - pvscan
###############################################################################
echo "$(date) === pvscan ==="

# Clean up LVM metadata
/usr/sbin/pvscan --cache -v
ErrCheck "Failed to pvscan"

###############################################################################
## Backup - Stage - Active VG
###############################################################################
echo "$(date) === Active VG ==="
/usr/sbin/vgchange -a y ${LVM_VG[0]}
ErrCheck "Failed to Active VG"

###############################################################################
## Backup - Stage - Mount the clone
###############################################################################
## Step 5: Mount the clone
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
fi

ErrCheck "Failed to mount the clone"
###############################################################################
## Backup - Stage - Changing permissions
###############################################################################

echo "set permissions to 777"
chmod -R 777 ${MP[0]}
ErrCheck "Failed to change permissions"

###############################################################################
## Backup - Stage - Start - nfs-server
###############################################################################

echo "$(date) === Start nfs-server ==="
/usr/bin/systemctl start nfs-server
ErrCheck "Failed to start nfs-server"
sleep 10

