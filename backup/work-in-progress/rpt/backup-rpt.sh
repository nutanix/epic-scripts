#!/bin/bash
# Author: Charles Sharp
# Date:10-26-2021
# About: Backups
# --> This is the main script that is being used in crontab
# --> on root crontab

###############################################################################
# Script Helpers - Error Checking
# --> If executed, it will stop the script from going further
###############################################################################

ErrCheck() {
  if [[ $? -ne 0 ]]; then
    ERRMSG=$@
    echo "$(date)"
    #echo -e "$1 \n\nPlease check on PROXY_HOST_HERE and veeam." | mailx -s "ODB Backup Error: start-backup.sh" -a /root/scripts/backup/cron.start-backup.log ADMIN_DL_HERE@domain.org
    echo "ERROR: $ERRMSG"
    echo "Exiting with failure"
    exit 1
  fi
}

###############################################################################
# Check SSH connection with Nutanix
###############################################################################

ssh -q nutanix@1.2.3.4-cvmiphere exit
ErrCheck "Unable to access Nutanix via SSH."

###############################################################################
# Starts snapshot on remote server and umount and mount on local server
# This is sequential
# Each backup-*.sh will recycle the NFS (stop and start process)
###############################################################################

#Freeze the Environment
#ssh ${TARGET_ODB_ACCT}@${TARGET_ODB_IP} "echo -n "Freezing ${TARGET_ODB_ENV[0]}: " ; /epic/${TARGET_ODB_ENV[0]}/bin/instfreeze"

echo "Start backup-prd01.sh"
#This script only does freeze NOT thaw
/root/scripts/backup/rpt/backup-rpt01.sh
sleep 60

echo "Start backup-epic.sh"
#This script only does freeze NOT thaw
/root/scripts/backup/rpt/backup-epic.sh
sleep 60

echo "Start backup-jrn.sh"
#This script only does freeze NOT thaw
/root/scripts/backup/rpt/backup-jrn.sh
sleep 60

#Thaw the Environment
#ssh ${TARGET_ODB_ACCT}@${TARGET_ODB_IP} "echo -n "Thaw ${TARGET_ODB_ENV[0]}: " ; /epic/${TARGET_ODB_ENV[0]}/bin/instthaw"

echo "Start backup-epicfiles.sh"
#This script does not freeze or thaw
/root/scripts/backup/rpt/backup-epicfiles.sh
sleep 60

###############################################################################
# Execute CURL to Veeam to start the backup on the NFS shares
# This is sequential
# This is very quick
###############################################################################

echo "Start backup-veeam-prd.sh (prd01/epic/epicfiles/jrn)"
#This will be combine to one script
# Backup everything that is mounted on /mnt/backup-nfs/RHEL-OS-PRD/

# Will be implmeneted later
#/root/scripts/backup/rpt/backup-veeam-rpt.sh
