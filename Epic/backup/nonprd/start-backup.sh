#!/bin/bash
# Author: Charles Sharp
# Date: 04-04-2022
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
	echo -e "$1 \n\nPlease check on PROXY_HOST_HERE and veeam." | mailx -s "ODB Backup Error: start-backup.sh" -a /root/scripts/backup/cron.start-backup.log ADMIN_DL_HERE@domain.org
    echo "ERROR: $ERRMSG"
    echo "Exiting with failure"
    exit 1
  fi
}

###############################################################################
# Check SSH connection with Nutanix
###############################################################################

ssh -q nutanix@1.2.3.4-cvm-ip-here exit
ErrCheck "Unable to access Nutanix via SSH."

###############################################################################
# Starts snapshot on remote server and umount and mount on local server
# This is sequential
# Each backup-*.sh will recycle the NFS (stop and start process)
###############################################################################

echo "Start backup-poc.sh"
/root/scripts/backup/nonprd/backup-poc.sh
sleep 60

echo "Start backup-tst.sh"
/root/scripts/backup/nonprd/backup-tst.sh
sleep 60

echo "Start backup-mpe.sh"
/root/scripts/backup/nonprd/backup-mpe.sh
sleep 60

###############################################################################
# Execute CURL to Veeam to start the backup on the NFS shares
# This is sequential
# This is very quick
###############################################################################

echo "Start backup-veeam-*.sh (POC/TST/MPE)"
/root/scripts/backup/nonprd/backup-veeam-poc.sh
sleep 300

/root/scripts/backup/nonprd/backup-veeam-tst.sh
sleep 300

/root/scripts/backup/nonprd/backup-veeam-mpe.sh
sleep 300

