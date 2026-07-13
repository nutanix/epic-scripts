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
  recovery_point_retention_days: 1
  copy_type: "REFRESH"      # "REFRESH" or "BACKUP"
  source_env: "PRD"       
  target_env: "SUP"         # Only needed if copy_type is REFRESH, if backup you can remove

source:
  vm_name: "<Name of Source VM>"    # Source VM Name in Prism Central (Case Sensitive)
  host: "<IP of Source VM>"	    # Source VM IP address
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
