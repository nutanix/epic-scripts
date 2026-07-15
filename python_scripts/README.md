# Epic ODB Environment Refresh Python Script

## Overview

This script handles creating and mounting clones of Epic ODB environments between a source and target system, or a source and backup proxy server

The same script is used for both use cases, with the primary differences being:

* Refresh
  1. Logical Volumes that include the system source env will be automatically renamed to the target env (PRD to SUP for example)
  2. The XFS filesystems are mounted Read/Only, new UUIDs for them are generated and they are then remounted as Read/Write
  3. Iris .lck files are removed from the filesystems so the database is ready to be brought online

* Backup
  1. Logical volumes are not renamed
  2. The XFS filesystems are left mounted as Read/Only

## Prerequisites

* The system running the script must be running Python3 and have the urllib3, requests, and PyYAML libraries installed
* Appropriate credentials for Prism Central API access to Create and Delete Recovery Points and Volume Groups, and attach them to VMs
* Authorized keys configured for users to access the source and target VMs for the mounts with appropriate sudo access configured

## Example Configuration File

```yaml

prism_central:
  ip: "<Prism Central IP>"  # IP Address of Prism Central
  username: "<PC Username>" # Username of PC User
  password: "<PC Password>" # Password of PC User 

job_settings:
  recovery_point_retention_days: 1  # Number of days to retain the Recovery Point
  delete_vg_after_disconnect: True  # Set to True if old Volume Groups should be deleted
  copy_type: "REFRESH"              # "REFRESH" or "BACKUP"
  source_env: "PRD"                 # The source environment for the backup or refresh
  target_env: "SUP"                 # Only needed if copy_type is REFRESH, if backup you can remove

source:
  vm_name: "<Name of Source VM>"    # Source VM Name in Prism Central (Case Sensitive)
  host: "<IP of Source VM>"	        # Source VM IP address
  user: "<SSH Username>"            # SSH user with ssh keys configured for authentication
  freeze_command: "sudo /epic/PRD/bin/instfreeze"    # Command to freeze ODB
  thaw_command: "sudo /epic/PRD/bin/instthaw"        # Command to thaw ODB

target:
  vm_name: "<Name of Target VM>"    # Target VM Name in Prism Central (Case Sensitive)
  host: "<IP of Target VM>"         # Hostname or IP of Target VM
  user: "<SSH Username>"            # SSH user with ssh keys configured for authentication

vgs:                                # Define multipe VGs for mounting
  - ntnx_source_vg: "EPICVG"        # VG Name in Prism Central (Case Sensitive)
    source_lvm_vg: "EpicVG"         # VG Name as seen by LVM within the source
    target_lvm_vg: "EpicSUP"        # VG Name that you want LVM to use on target 
    mounts:
      lv_vol1: "/backup/vol1"       # LV Name for the filesystem on Source, Mountpoint on Target
      lv_vol2: "/backup/vol2"
      lv_vol3: "/backup/vol3"
      
  - ntnx_source_vg: "EPICvg2"
    source_lvm_vg: "EpicVG2"
    target_lvm_vg: "EpicSUP2"
    mounts:
      lv_vol4: "/backup/vol4"
      lv_vol5: "/backup/vol5"
```

## Usage

Multiple configuration files can be created for each different refresh or backup you would like to run.   If you do not provide a file name on the command line, it will default to config.yml.

Executing a backup or refresh as configured in the YAML file

```sh
epic_backup_clone.py -c config.yml
```

Executing a backup or refresh as configured in the YAML file with verbose debug output

```sh
epic_backup_clone.py -c config.yml -v
```

## Sample Output 

Refresh

```console
2026-07-13 13:21:25 [ OK ] ------------------------------------
2026-07-13 13:21:25 [ OK ]  Starting REFRESH
2026-07-13 13:21:25 [ OK ] ------------------------------------
2026-07-13 13:21:25 [ OK ] Unmounting Filesystems
2026-07-13 13:21:25 [ OK ] Checking if /backup/vol1 is mounted on 192.168.2.85
2026-07-13 13:21:25 [ OK ]   /backup/vol1 is mounted
2026-07-13 13:21:25 [ OK ]   Unmounting /backup/vol1
2026-07-13 13:21:26 [ OK ] Checking if /backup/vol2 is mounted on 192.168.2.85
2026-07-13 13:21:26 [ OK ]   /backup/vol2 is mounted
2026-07-13 13:21:26 [ OK ]   Unmounting /backup/vol2
2026-07-13 13:21:27 [ OK ] Checking if /backup/vol3 is mounted on 192.168.2.85
2026-07-13 13:21:27 [ OK ]   /backup/vol3 is mounted
2026-07-13 13:21:27 [ OK ]   Unmounting /backup/vol3
2026-07-13 13:21:28 [ OK ]   Checking Volume Group: EpicSUP
2026-07-13 13:21:28 [ OK ] Check if EpicSUP is active
2026-07-13 13:21:29 [ OK ]   LV test_vol1 appears active in EpicSUP
2026-07-13 13:21:29 [ OK ]   LV test_vol2 appears active in EpicSUP
2026-07-13 13:21:29 [ OK ]   LV test_vol3 appears active in EpicSUP
2026-07-13 13:21:29 [ OK ]   Deactivating Volume Group: EpicSUP
2026-07-13 13:21:29 [ OK ] Unmounting Filesystems
2026-07-13 13:21:29 [ OK ] Checking if /backup/vol4 is mounted on 192.168.2.85
2026-07-13 13:21:30 [ OK ]   /backup/vol4 is mounted
2026-07-13 13:21:30 [ OK ]   Unmounting /backup/vol4
2026-07-13 13:21:30 [ OK ] Checking if /backup/vol5 is mounted on 192.168.2.85
2026-07-13 13:21:31 [ OK ]   /backup/vol5 is mounted
2026-07-13 13:21:31 [ OK ]   Unmounting /backup/vol5
2026-07-13 13:21:31 [ OK ]   Checking Volume Group: EpicSUP2
2026-07-13 13:21:31 [ OK ] Check if EpicSUP2 is active
2026-07-13 13:21:32 [ OK ]   LV test_vol4 appears active in EpicSUP2
2026-07-13 13:21:32 [ OK ]   LV test_vol5 appears active in EpicSUP2
2026-07-13 13:21:32 [ OK ]   Deactivating Volume Group: EpicSUP2
2026-07-13 13:21:32 [ OK ] -----------------------------------------------------
2026-07-13 13:21:32 [ OK ]   Target Cleanup Completed
2026-07-13 13:21:32 [ OK ] -----------------------------------------------------
2026-07-13 13:21:33 [ OK ] Detaching Volume Group REFRESH-VG-SUP-EPICVG-20260713163643 from Proxy VM EpicTarget_RHEL10
2026-07-13 13:21:33 [ OK ]   Successfully detached Volume Group REFRESH-VG-SUP-EPICVG-20260713163643 from Proxy VM EpicTarget_RHEL10
2026-07-13 13:21:33 [ OK ]   Deleting Volume Group REFRESH-VG-SUP-EPICVG-20260713163643
2026-07-13 13:21:33 [ OK ] Detaching Volume Group REFRESH-VG-SUP-EPICvg2-20260713163643 from Proxy VM EpicTarget_RHEL10
2026-07-13 13:21:33 [ OK ]   Successfully detached Volume Group REFRESH-VG-SUP-EPICvg2-20260713163643 from Proxy VM EpicTarget_RHEL10
2026-07-13 13:21:33 [ OK ]   Deleting Volume Group REFRESH-VG-SUP-EPICvg2-20260713163643
2026-07-13 13:21:34 [ OK ] -----------------------------------------------------
2026-07-13 13:21:34 [ OK ] Storage successfully detached from 192.168.2.85
2026-07-13 13:21:34 [ OK ] -----------------------------------------------------
2026-07-13 13:21:34 [ OK ] Connecting to 192.168.2.65 to freeze ODB
2026-07-13 13:21:34 [ OK ] -----------------------------------------------------
2026-07-13 13:21:34 [ OK ]   Database frozen successfully
2026-07-13 13:21:34 [ OK ] -----------------------------------------------------
2026-07-13 13:21:34 [ OK ] Retrieving Volume Group details for: EPICVG
2026-07-13 13:21:34 [ OK ] Retrieving Volume Group details for: EPICvg2
2026-07-13 13:21:34 [ OK ] Creating Recovery Point for Volume Group: EPICVG
2026-07-13 13:21:34 [ OK ]   RP Name: REFRESH-VG-SUP-EPICVG-RP-20260713172134
2026-07-13 13:21:34 [ OK ]   Task for Recovery Point for Volume Group created
2026-07-13 13:21:34 [ OK ] Creating Recovery Point for Volume Group: EPICvg2
2026-07-13 13:21:34 [ OK ]   RP Name: REFRESH-VG-SUP-EPICvg2-RP-20260713172134
2026-07-13 13:21:35 [ OK ]   Task for Recovery Point for Volume Group created
2026-07-13 13:21:35 [ OK ] Waiting for Recovery Point creation task to complete for Volume Group: EPICVG
2026-07-13 13:21:40 [ OK ]   Recovery Point creation for Volume Group Successful
2026-07-13 13:21:40 [ OK ]   Collecting details about created Recovery Point
2026-07-13 13:21:40 [ OK ] Waiting for Recovery Point creation task to complete for Volume Group: EPICvg2
2026-07-13 13:21:40 [ OK ]   Recovery Point creation for Volume Group Successful
2026-07-13 13:21:40 [ OK ]   Collecting details about created Recovery Point
2026-07-13 13:21:40 [ OK ] Cloning Recovery Point to new Volume Group for: EPICVG
2026-07-13 13:21:40 [ OK ]   New VG Name will be: REFRESH-VG-SUP-EPICVG-20260713172134
2026-07-13 13:21:40 [ OK ]   Task creation for cloning for Volume Group Successful
2026-07-13 13:21:40 [ OK ] Cloning Recovery Point to new Volume Group for: EPICvg2
2026-07-13 13:21:40 [ OK ]   New VG Name will be: REFRESH-VG-SUP-EPICvg2-20260713172134
2026-07-13 13:21:41 [ OK ]   Task creation for cloning for Volume Group Successful
2026-07-13 13:21:41 [ OK ]   Waiting for VG clone creation task to complete for Volume Group: REFRESH-VG-SUP-EPICVG-20260713172134
2026-07-13 13:21:46 [ OK ]   Task for cloning Volume Group Successful
2026-07-13 13:21:46 [ OK ]   Waiting for VG clone creation task to complete for Volume Group: REFRESH-VG-SUP-EPICvg2-20260713172134
2026-07-13 13:21:46 [ OK ]   Task for cloning Volume Group Successful
2026-07-13 13:21:46 [ OK ] Attaching new Volume Group REFRESH-VG-SUP-EPICVG-20260713172134 to Proxy VM EpicTarget_RHEL10
2026-07-13 13:21:46 [ OK ]   Successfully attached Volume Group EPICVG to Proxy VM EpicTarget_RHEL10
2026-07-13 13:21:46 [ OK ] Attaching new Volume Group REFRESH-VG-SUP-EPICvg2-20260713172134 to Proxy VM EpicTarget_RHEL10
2026-07-13 13:21:46 [ OK ]   Successfully attached Volume Group EPICvg2 to Proxy VM EpicTarget_RHEL10
2026-07-13 13:21:46 [ OK ] -----------------------------------------------------
2026-07-13 13:21:46 [ OK ] Storage successfully attached to 192.168.2.85
2026-07-13 13:21:46 [ OK ] -----------------------------------------------------
2026-07-13 13:21:46 [ OK ] Connecting to 192.168.2.65 to thaw ODB
2026-07-13 13:21:47 [ OK ] ------------------------------------
2026-07-13 13:21:47 [ OK ]   Database thawed successfully
2026-07-13 13:21:47 [ OK ] ------------------------------------
2026-07-13 13:21:47 [ OK ] Ensuring that mount points exist on 192.168.2.85
2026-07-13 13:21:47 [ OK ] Verifying: /backup/vol1 for LV test_vol1
2026-07-13 13:21:48 [ OK ]   Mount is Good
2026-07-13 13:21:48 [ OK ] Verifying: /backup/vol2 for LV test_vol2
2026-07-13 13:21:48 [ OK ]   Mount is Good
2026-07-13 13:21:48 [ OK ] Verifying: /backup/vol3 for LV test_vol3
2026-07-13 13:21:49 [ OK ]   Mount is Good
2026-07-13 13:21:49 [ OK ] Verifying: /backup/vol4 for LV test_vol4
2026-07-13 13:21:50 [ OK ]   Mount is Good
2026-07-13 13:21:50 [ OK ] Verifying: /backup/vol5 for LV test_vol5
2026-07-13 13:21:50 [ OK ]   Mount is Good
2026-07-13 13:21:51 [ OK ] Performing disk rescan operations on 192.168.2.85
2026-07-13 13:21:51 [ OK ]   Executing Linux SCSI hardware rescan
2026-07-13 13:21:53 [ OK ]   Performing full pvscan of all devices for LV
2026-07-13 13:21:54 [ OK ]   Forcing LVM to scan all devices (bypassing filter)...
2026-07-13 13:21:55 [ OK ] Activating LVM Volume Groups and Mounting XFS filesystems
2026-07-13 13:21:55 [ OK ] Processing VG: EpicVG
2026-07-13 13:21:55 [ OK ]   Making EpicVG active
2026-07-13 13:21:55 [ OK ]   Waiting for udev to populate EpicVG device mapper nodes
2026-07-13 13:22:02 [ OK ]   Renaming Volume Group from EpicVG to EpicSUP
2026-07-13 13:22:02 [ OK ]   Reactivating EpicSUP
2026-07-13 13:22:03 [ OK ]   Waiting for udev to populate EpicSUP device mapper nodes
2026-07-13 13:22:08 [ OK ] Mounting test_vol1 to /backup/vol1
2026-07-13 13:22:08 [ OK ]   Determining LVM path for test_vol1
2026-07-13 13:22:09 [ OK ]   Performing Mount onto   /dev/EpicSUP/test_vol1
2026-07-13 13:22:09 [ OK ]  Unmounting to updating XFS UUID
2026-07-13 13:22:09 [ OK ]   Unmounting /backup/vol1
2026-07-13 13:22:10 [ OK ]   Generating new UUID for   /dev/EpicSUP/test_vol1
2026-07-13 13:22:11 [ OK ]   Remounting /backup/vol1 Read/Write
2026-07-13 13:22:11 [ OK ] Mounting test_vol2 to /backup/vol2
2026-07-13 13:22:11 [ OK ]   Determining LVM path for test_vol2
2026-07-13 13:22:12 [ OK ]   Performing Mount onto   /dev/EpicSUP/test_vol2
2026-07-13 13:22:13 [ OK ]  Unmounting to updating XFS UUID
2026-07-13 13:22:13 [ OK ]   Unmounting /backup/vol2
2026-07-13 13:22:13 [ OK ]   Generating new UUID for   /dev/EpicSUP/test_vol2
2026-07-13 13:22:14 [ OK ]   Remounting /backup/vol2 Read/Write
2026-07-13 13:22:15 [ OK ] Mounting test_vol3 to /backup/vol3
2026-07-13 13:22:15 [ OK ]   Determining LVM path for test_vol3
2026-07-13 13:22:16 [ OK ]   Performing Mount onto   /dev/EpicSUP/test_vol3
2026-07-13 13:22:16 [ OK ]  Unmounting to updating XFS UUID
2026-07-13 13:22:16 [ OK ]   Unmounting /backup/vol3
2026-07-13 13:22:17 [ OK ]   Generating new UUID for   /dev/EpicSUP/test_vol3
2026-07-13 13:22:18 [ OK ]   Remounting /backup/vol3 Read/Write
2026-07-13 13:22:19 [ OK ] Processing VG: EpicVG2
2026-07-13 13:22:19 [ OK ]   Making EpicVG2 active
2026-07-13 13:22:19 [ OK ]   Waiting for udev to populate EpicVG2 device mapper nodes
2026-07-13 13:22:25 [ OK ]   Renaming Volume Group from EpicVG2 to EpicSUP2
2026-07-13 13:22:26 [ OK ]   Reactivating EpicSUP2
2026-07-13 13:22:27 [ OK ]   Waiting for udev to populate EpicSUP2 device mapper nodes
2026-07-13 13:22:32 [ OK ] Mounting test_vol4 to /backup/vol4
2026-07-13 13:22:32 [ OK ]   Determining LVM path for test_vol4
2026-07-13 13:22:32 [ OK ]   Performing Mount onto   /dev/EpicSUP2/test_vol4
2026-07-13 13:22:33 [ OK ]  Unmounting to updating XFS UUID
2026-07-13 13:22:33 [ OK ]   Unmounting /backup/vol4
2026-07-13 13:22:33 [ OK ]   Generating new UUID for   /dev/EpicSUP2/test_vol4
2026-07-13 13:22:34 [ OK ]   Remounting /backup/vol4 Read/Write
2026-07-13 13:22:35 [ OK ] Mounting test_vol5 to /backup/vol5
2026-07-13 13:22:35 [ OK ]   Determining LVM path for test_vol5
2026-07-13 13:22:36 [ OK ]   Performing Mount onto   /dev/EpicSUP2/test_vol5
2026-07-13 13:22:37 [ OK ]  Unmounting to updating XFS UUID
2026-07-13 13:22:37 [ OK ]   Unmounting /backup/vol5
2026-07-13 13:22:37 [ OK ]   Generating new UUID for   /dev/EpicSUP2/test_vol5
2026-07-13 13:22:38 [ OK ]   Remounting /backup/vol5 Read/Write
2026-07-13 13:22:39 [ OK ] -----------------------------------------------------
2026-07-13 13:22:39 [ OK ] Storage successfully imported and filesystems mounted
2026-07-13 13:22:39 [ OK ] -----------------------------------------------------
2026-07-13 13:22:39 [ OK ] Removing Iris Lock Files in /backup/vol1
2026-07-13 13:22:39 [ OK ] Removing Iris Lock Files in /backup/vol2
2026-07-13 13:22:40 [ OK ] Removing Iris Lock Files in /backup/vol3
2026-07-13 13:22:40 [ OK ] Removing Iris Lock Files in /backup/vol4
2026-07-13 13:22:41 [ OK ] Removing Iris Lock Files in /backup/vol5
2026-07-13 13:22:41 [ OK ] ------------------------------------
2026-07-13 13:22:41 [ OK ]   Lock File Cleanup Complete
2026-07-13 13:22:41 [ OK ] ------------------------------------
```

Backup

```console
2026-07-13 13:49:43 [ OK ] ------------------------------------
2026-07-13 13:49:43 [ OK ]  Starting BACKUP
2026-07-13 13:49:43 [ OK ] ------------------------------------
2026-07-13 13:49:43 [ OK ] Unmounting Filesystems
2026-07-13 13:49:43 [ OK ] Checking if /backup/vol1 is mounted on 192.168.2.85
2026-07-13 13:49:43 [ OK ]   /backup/vol1 is mounted
2026-07-13 13:49:43 [ OK ]   Unmounting /backup/vol1
2026-07-13 13:49:44 [ OK ] Checking if /backup/vol2 is mounted on 192.168.2.85
2026-07-13 13:49:44 [ OK ]   /backup/vol2 is mounted
2026-07-13 13:49:44 [ OK ]   Unmounting /backup/vol2
2026-07-13 13:49:45 [ OK ] Checking if /backup/vol3 is mounted on 192.168.2.85
2026-07-13 13:49:46 [ OK ]   /backup/vol3 is mounted
2026-07-13 13:49:46 [ OK ]   Unmounting /backup/vol3
2026-07-13 13:49:46 [ OK ]   Checking Volume Group: EpicBKP
2026-07-13 13:49:46 [ OK ] Check if EpicBKP is active
2026-07-13 13:49:47 [ OK ]   LV test_vol1 appears active in EpicBKP
2026-07-13 13:49:47 [ OK ]   LV test_vol2 appears active in EpicBKP
2026-07-13 13:49:47 [ OK ]   LV test_vol3 appears active in EpicBKP
2026-07-13 13:49:47 [ OK ]   Deactivating Volume Group: EpicBKP
2026-07-13 13:49:47 [ OK ] Unmounting Filesystems
2026-07-13 13:49:47 [ OK ] Checking if /backup/vol4 is mounted on 192.168.2.85
2026-07-13 13:49:48 [ OK ]   /backup/vol4 is mounted
2026-07-13 13:49:48 [ OK ]   Unmounting /backup/vol4
2026-07-13 13:49:48 [ OK ] Checking if /backup/vol5 is mounted on 192.168.2.85
2026-07-13 13:49:49 [ OK ]   /backup/vol5 is mounted
2026-07-13 13:49:49 [ OK ]   Unmounting /backup/vol5
2026-07-13 13:49:49 [ OK ]   Checking Volume Group: EpicBKP2
2026-07-13 13:49:49 [ OK ] Check if EpicBKP2 is active
2026-07-13 13:49:50 [ OK ]   LV test_vol4 appears active in EpicBKP2
2026-07-13 13:49:50 [ OK ]   LV test_vol5 appears active in EpicBKP2
2026-07-13 13:49:50 [ OK ]   Deactivating Volume Group: EpicBKP2
2026-07-13 13:49:50 [ OK ] -----------------------------------------------------
2026-07-13 13:49:50 [ OK ]   Target Cleanup Completed
2026-07-13 13:49:50 [ OK ] -----------------------------------------------------
2026-07-13 13:49:51 [ OK ] Detaching Volume Group BACKUP-EPICVG-20260713174546 from Proxy VM EpicTarget_RHEL10
2026-07-13 13:49:51 [ OK ]   Successfully detached Volume Group BACKUP-EPICVG-20260713174546 from Proxy VM EpicTarget_RHEL10
2026-07-13 13:49:51 [ OK ]   Deleting Volume Group BACKUP-EPICVG-20260713174546
2026-07-13 13:49:51 [ OK ]   Successfully deleted Volume Group BACKUP-EPICVG-20260713174546 from Proxy VM EpicTarget_RHEL10
2026-07-13 13:49:51 [ OK ] Detaching Volume Group BACKUP-EPICvg2-20260713174546 from Proxy VM EpicTarget_RHEL10
2026-07-13 13:49:51 [ OK ]   Successfully detached Volume Group BACKUP-EPICvg2-20260713174546 from Proxy VM EpicTarget_RHEL10
2026-07-13 13:49:51 [ OK ]   Deleting Volume Group BACKUP-EPICvg2-20260713174546
2026-07-13 13:49:52 [ OK ]   Successfully deleted Volume Group BACKUP-EPICvg2-20260713174546 from Proxy VM EpicTarget_RHEL10
2026-07-13 13:49:52 [ OK ] -----------------------------------------------------
2026-07-13 13:49:52 [ OK ] Storage successfully detached from 192.168.2.85
2026-07-13 13:49:52 [ OK ] -----------------------------------------------------
2026-07-13 13:49:52 [ OK ] Connecting to 192.168.2.65 to freeze ODB
2026-07-13 13:49:52 [ OK ] -----------------------------------------------------
2026-07-13 13:49:52 [ OK ]   Database frozen successfully
2026-07-13 13:49:52 [ OK ] -----------------------------------------------------
2026-07-13 13:49:52 [ OK ] Retrieving Volume Group details for: EPICVG
2026-07-13 13:49:52 [ OK ] Retrieving Volume Group details for: EPICvg2
2026-07-13 13:49:52 [ OK ] Creating Recovery Point for Volume Group: EPICVG
2026-07-13 13:49:52 [ OK ]   RP Name: BACKUP-EPICVG-RP-20260713174952
2026-07-13 13:49:52 [ OK ]   Task for Recovery Point for Volume Group created
2026-07-13 13:49:52 [ OK ] Creating Recovery Point for Volume Group: EPICvg2
2026-07-13 13:49:52 [ OK ]   RP Name: BACKUP-EPICvg2-RP-20260713174952
2026-07-13 13:49:53 [ OK ]   Task for Recovery Point for Volume Group created
2026-07-13 13:49:53 [ OK ] Waiting for Recovery Point creation task to complete for Volume Group: EPICVG
2026-07-13 13:49:58 [ OK ]   Recovery Point creation for Volume Group Successful
2026-07-13 13:49:58 [ OK ]   Collecting details about created Recovery Point
2026-07-13 13:49:58 [ OK ] Waiting for Recovery Point creation task to complete for Volume Group: EPICvg2
2026-07-13 13:49:58 [ OK ]   Recovery Point creation for Volume Group Successful
2026-07-13 13:49:58 [ OK ]   Collecting details about created Recovery Point
2026-07-13 13:49:58 [ OK ] Cloning Recovery Point to new Volume Group for: EPICVG
2026-07-13 13:49:58 [ OK ]   New VG Name will be: BACKUP-EPICVG-20260713174952
2026-07-13 13:49:58 [ OK ]   Task creation for cloning for Volume Group Successful
2026-07-13 13:49:58 [ OK ] Cloning Recovery Point to new Volume Group for: EPICvg2
2026-07-13 13:49:58 [ OK ]   New VG Name will be: BACKUP-EPICvg2-20260713174952
2026-07-13 13:49:59 [ OK ]   Task creation for cloning for Volume Group Successful
2026-07-13 13:49:59 [ OK ]   Waiting for VG clone creation task to complete for Volume Group: BACKUP-EPICVG-20260713174952
2026-07-13 13:50:04 [ OK ]   Task for cloning Volume Group Successful
2026-07-13 13:50:04 [ OK ]   Waiting for VG clone creation task to complete for Volume Group: BACKUP-EPICvg2-20260713174952
2026-07-13 13:50:04 [ OK ]   Task for cloning Volume Group Successful
2026-07-13 13:50:04 [ OK ] Attaching new Volume Group BACKUP-EPICVG-20260713174952 to Proxy VM EpicTarget_RHEL10
2026-07-13 13:50:04 [ OK ]   Successfully attached Volume Group EPICVG to Proxy VM EpicTarget_RHEL10
2026-07-13 13:50:04 [ OK ] Attaching new Volume Group BACKUP-EPICvg2-20260713174952 to Proxy VM EpicTarget_RHEL10
2026-07-13 13:50:04 [ OK ]   Successfully attached Volume Group EPICvg2 to Proxy VM EpicTarget_RHEL10
2026-07-13 13:50:04 [ OK ] -----------------------------------------------------
2026-07-13 13:50:04 [ OK ] Storage successfully attached to 192.168.2.85
2026-07-13 13:50:04 [ OK ] -----------------------------------------------------
2026-07-13 13:50:04 [ OK ] Connecting to 192.168.2.65 to thaw ODB
2026-07-13 13:50:05 [ OK ] ------------------------------------
2026-07-13 13:50:05 [ OK ]   Database thawed successfully
2026-07-13 13:50:05 [ OK ] ------------------------------------
2026-07-13 13:50:05 [ OK ] Ensuring that mount points exist on 192.168.2.85
2026-07-13 13:50:05 [ OK ] Verifying: /backup/vol1 for LV test_vol1
2026-07-13 13:50:06 [ OK ]   Mount is Good
2026-07-13 13:50:06 [ OK ] Verifying: /backup/vol2 for LV test_vol2
2026-07-13 13:50:06 [ OK ]   Mount is Good
2026-07-13 13:50:06 [ OK ] Verifying: /backup/vol3 for LV test_vol3
2026-07-13 13:50:07 [ OK ]   Mount is Good
2026-07-13 13:50:07 [ OK ] Verifying: /backup/vol4 for LV test_vol4
2026-07-13 13:50:08 [ OK ]   Mount is Good
2026-07-13 13:50:08 [ OK ] Verifying: /backup/vol5 for LV test_vol5
2026-07-13 13:50:08 [ OK ]   Mount is Good
2026-07-13 13:50:09 [ OK ] Performing disk rescan operations on 192.168.2.85
2026-07-13 13:50:09 [ OK ]   Executing Linux SCSI hardware rescan
2026-07-13 13:50:11 [ OK ]   Performing full pvscan of all devices for LV
2026-07-13 13:50:12 [ OK ]   Forcing LVM to scan all devices (bypassing filter)...
2026-07-13 13:50:13 [ OK ] Activating LVM Volume Groups and Mounting XFS filesystems
2026-07-13 13:50:13 [ OK ] Processing VG: EpicVG
2026-07-13 13:50:13 [ OK ]   Making EpicVG active
2026-07-13 13:50:14 [ OK ]   Waiting for udev to populate EpicVG device mapper nodes
2026-07-13 13:50:20 [ OK ]   Renaming Volume Group from EpicVG to EpicBKP
2026-07-13 13:50:21 [ OK ]   Reactivating EpicBKP
2026-07-13 13:50:22 [ OK ]   Waiting for udev to populate EpicBKP device mapper nodes
2026-07-13 13:50:27 [ OK ] Mounting test_vol1 to /backup/vol1
2026-07-13 13:50:27 [ OK ]   Determining LVM path for test_vol1
2026-07-13 13:50:27 [ OK ]   Performing Mount onto   /dev/EpicBKP/test_vol1
2026-07-13 13:50:29 [ OK ] Mounting test_vol2 to /backup/vol2
2026-07-13 13:50:29 [ OK ]   Determining LVM path for test_vol2
2026-07-13 13:50:30 [ OK ]   Performing Mount onto   /dev/EpicBKP/test_vol2
2026-07-13 13:50:31 [ OK ] Mounting test_vol3 to /backup/vol3
2026-07-13 13:50:31 [ OK ]   Determining LVM path for test_vol3
2026-07-13 13:50:32 [ OK ]   Performing Mount onto   /dev/EpicBKP/test_vol3
2026-07-13 13:50:33 [ OK ] Processing VG: EpicVG2
2026-07-13 13:50:33 [ OK ]   Making EpicVG2 active
2026-07-13 13:50:33 [ OK ]   Waiting for udev to populate EpicVG2 device mapper nodes
2026-07-13 13:50:40 [ OK ]   Renaming Volume Group from EpicVG2 to EpicBKP2
2026-07-13 13:50:41 [ OK ]   Reactivating EpicBKP2
2026-07-13 13:50:41 [ OK ]   Waiting for udev to populate EpicBKP2 device mapper nodes
2026-07-13 13:50:46 [ OK ] Mounting test_vol4 to /backup/vol4
2026-07-13 13:50:46 [ OK ]   Determining LVM path for test_vol4
2026-07-13 13:50:47 [ OK ]   Performing Mount onto   /dev/EpicBKP2/test_vol4
2026-07-13 13:50:49 [ OK ] Mounting test_vol5 to /backup/vol5
2026-07-13 13:50:49 [ OK ]   Determining LVM path for test_vol5
2026-07-13 13:50:49 [ OK ]   Performing Mount onto   /dev/EpicBKP2/test_vol5
2026-07-13 13:50:51 [ OK ] -----------------------------------------------------
2026-07-13 13:50:51 [ OK ] Storage successfully imported and filesystems mounted
2026-07-13 13:50:51 [ OK ] -----------------------------------------------------
```

## Troubleshooting

* In most cases if there is a failure, rerunning the playbook will resolve it for you.
* If there is a failure during mounting of the filesystems verify that there are no LVM errors and the disks are visible.
* In RHEL9 and RHEL10 the use of a devices file can cause issues with disk discovery after refresh.  If this is case, you should modify the /etc/lvm.conf file and add use_devicesfile=0 to avoid issues in the future.

## Objects Created

For each volume group both a Recovery Point and a cloned Volume Group will be created.   They will follow the naming convention:

* Refresh
  * Recovery Point -- REFRESH-RP-SOURCE_ENV-TARGET_ENV-VGNAME-TIMESTAMP
  * Volume Group -- REFRESH-SOURCE_ENV-TARGET_ENV-VGNAME-TIMESTAMP
* Backup
  * Recovery Point -- BACKUP-RP-VGNAME-TIMESTAMP
  * Volume Group -- BACKUP-VGNAME-TIMESTAMP

Neither object is dependent upon the other, so the Recovery Point can be removed without impacting the clone of the Volume Group

## Change Log

| Date       | Author        | Description           |
|------------|---------------|-----------------------|
| 2026-07-13 | Kurt Telep    | Initial documentation |
