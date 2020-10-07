#!/bin/bash

######
# The scipt is an example of a way to quiesce Spectrum Scale file systems 
# and take a protection domain snapshot for DR. This script is run on a VM 
# with administrative access to Spectrum Scale. 
#
# Before using this script
# 1. Create a protection domain for each volume group that contains 
#    a Spectrum Scale file system.

#################
# Custom Parameters
CVMIP="10.1.1.2"
# List of file systems and their corresponding protection domains
fs=("sasdata1" "sasdata2" )
pd=("sasdata1pd" "sasdata2pd" )

##################
## Register this userid with CVM for ssh access
## Test connectivity
## Parameters: cvm vm_name
reg_with_cvm () {
  echo "-- Start: Register with CVM"
  h_name=`/bin/hostname`
  ssh -o PreferredAuthentications=publickey nutanix@${CVMIP} /bin/true > /dev/null 2>&1
  rc=$?

  if (( rc != 0 )); then
    echo ""
    echo "You need to register this UVM with the CVM. To register"
    echo "you will be prompted for a CVM password twice."
    echo ""

    scp /root/.ssh/id_rsa.pub nutanix@${CVMIP}:/home/nutanix/tmp/new_key.pub
    ssh nutanix@${CVMIP} "/home/nutanix/prism/cli/ncli cluster  add-public-key name=$h_name file-path=/home/nutanix/tmp/new_key.pub"
    sleep 2
    ssh -o PreferredAuthentications=publickey nutanix@${CVMIP} /bin/true
    rc=$?
    if (( rc != 0 )); then
      echo "Error trying to register this VM with the CVM"
      exit
    fi
    echo "CVM registration complete."
  else
    echo "VM is already registerd for ssh access to CVM."
  fi

}

# Make sure the current user has access to the CVM
reg_with_cvm

for n in ${!fs[@]}; do
  # Suspend write operations on the Spectrum Scale File System
  echo Suspend File System: ${fs[n]}
  /usr/lpp/mmfs/bin/mmfsctl ${fs[n]} suspend-write 

  echo Snap Protection Domain: ${pd[n]}
  ssh nutanix@${CVMIP} "/home/nutanix/prism/cli/ncli protection-domain create-one-time-snapshot name=${pd[n]}"

  # Resume write operations on the Spectrum Scale File System
  echo Suspend File System: ${fs[n]}
  /usr/lpp/mmfs/bin/mmfsctl ${fs[n]} resume 

done
