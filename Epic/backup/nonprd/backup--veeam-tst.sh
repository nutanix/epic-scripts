#!/usr/bin/bash
# Author: Charles Sharp
# Date: 08-26-2021
# About: Backups

###############################################################################
## Script Helpers - Error Checking
###############################################################################

ErrCheck() {
  if [[ $? -ne 0 ]]; then
    ERRMSG=$@
    echo "$(date)"
	echo -e "$1 \n\nPlease check on PROXY_HOST_HERE and veeam." | mailx -s "ODB Backup Error: backup-veeam-tst.sh" -a /root/scripts/backup/cron.start-backup.log ADMIN_DL_HERE@domain.org
    echo "ERROR: $ERRMSG"
    echo "Exiting with failure"
    exit 1
  fi
}

###############################################################################
## Backup - Stage - Start Veeam Backup
###############################################################################
## Step 6: Kick off 3rd party out-of-system backup
echo "Kick off backup for " ${PREFIX_DATE}-copy-${TARGET_ODB_ENV[0]}
echo "$(date) === Start Veeam Backup Stage ==="


#######################################
# Login Variables
#######################################
veeamUsername="veeamservice" # If using domain based account, enter UPN (e.g. user@domain.com)
veeamPassword=''
veeamAuth=$(echo -ne "$veeamUsername:$veeamPassword" | base64);
veeamRestServer="veeam-mgmt-em-server.domain.org" #IP Address or FQDN of Enterprise Manager server
veeamRestPort="9398"

#######################################
# JobId Variables
#######################################
#POC
veeamJobId="uuid-of-job-here"
echo "veeamJobId = ${veeamJobId}"


#######################################
# Endpoint URL for login action - Variables
#######################################

veeamSessionId=$(curl -X POST "https://$veeamRestServer:$veeamRestPort/api/sessionMngr/?v=latest" -H "Authorization:Basic $veeamAuth" -H "Content-Length: 0" -H "Accept: application/json" --insecure 2>&1 -k --silent| awk 'NR==1{sub(/^\xef\xbb\xbf/,"")}1' | jq --raw-output ".SessionId")
veeamXRestSvcSessionId=$(echo -ne "$veeamSessionId" | base64);


#######################################
# Query Job
#######################################

echo "$(date) === Query Job ==="
veeamEMJobUrl="https://$veeamRestServer:$veeamRestPort/api/nas/jobs/$veeamJobId?format=Entity"
veeamEMJobDetailUrl=$(curl -X GET "$veeamEMJobUrl" -H "Accept:application/json" -H "X-RestSvcSessionId: $veeamXRestSvcSessionId" -H "Cookie: X-RestSvcSessionId=$veeamXRestSvcSessionId" -H "Content-Length: 0" --insecure 2>&1 -k --silent | awk 'NR==1{sub(/^\xef\xbb\xbf/,"")}1')


#######################################
# Start Job
#######################################

echo "$(date) === Start Job ==="
veeamEMStartUrl="https://$veeamRestServer:$veeamRestPort/api/nas/jobs/$veeamJobId/start"
veeamEMResultUrl=$(curl -X POST "$veeamEMStartUrl" -H "Accept:application/json" -H "X-RestSvcSessionId: $veeamXRestSvcSessionId" -H "Cookie: X-RestSvcSessionId=$veeamXRestSvcSessionId" -H "Content-Length: 0" --insecure 2>&1 -k --silent | awk 'NR==1{sub(/^\xef\xbb\xbf/,"")}1')


#######################################
# Capture & Display Results
#######################################

echo "$(date) === Capture and Display Results ==="

veeamJobName=$(echo "$veeamEMJobDetailUrl" | jq --raw-output ".Name")
veeamTaskId=$(echo "$veeamEMResultUrl" | jq --raw-output ".TaskId")
veeamState=$(echo "$veeamEMResultUrl" | jq --raw-output ".State")
veeamOperation=$(echo "$veeamEMResultUrl" | jq --raw-output ".Operation")

ErrCheck "Failed to Start veeam backup."

#######################################
# Debug
#######################################
#echo $veeamEMJobDetailUrl
#echo $veeamJobName
#------------------------------------------------------------------------------

