# Epic ODB Environment Refresh Playbook

## Overview

This playbook creates clones of Epic ODB environments between a source and target system, or a source and backup system.

The process is broken into two components:

* create_epic_snapshot.yml
  1. Connects to source_system and freezes the Epic ODB database
  2. Creates a RecoveryPoint of the identified Nutanix Volume Groups aligned with Linux Volume Groups
  3. Thaws the Epic ODB database

* clone_mount_epic_snapshot.yml
  1. Unmounts associated filesystems on the target
  2. Deactivates and Exports the Linux Volume Group(s) on the target
  3. Disconnects the Nutanix Volume Group(s) from the target
  4. Clones the RecoveryPoint taken previously to a new Nutanix volume group
  5. Attaches the new Nutanix volume group(s) to the target
  6. Imports the Linux volume groups(s) and mounts associated filesystems
  7. Removes any ODB lock files
  8. Cleans up any old Nutanix volume groups
  
## Prerequisites

* Tested with Ansible 2.15.13
* Requires nutanix.ncp plugin v2.2.0 (Available via Ansible Galaxy)
* Installation of the appropriate Nutanix python libraries, based on release of Prism Central
* Ansible must have ssh access to the source and target vms, along with the ability to elevate privileges
* Appropriate credentials for Prism Central API access

## Example Inventory

It is important that the target_host and source_host are identified in the inventory as such, and that their local python interpreters are identified.   You may also need to identify the python interpreter for localhost.   All Nutanix actions will run from the local ansible host via the nutanix.ncp plugin.

```ini
localhost       ansible_connection=local 

[target_host]
192.168.2.64    ansible_python_interpreter='/usr/bin/python3'

[source_host]
192.168.2.65    ansible_python_interpreter='/usr/bin/python3'
```

## Variables

All Variables are required and can be passed via --extra-vars=@variable_file.yml  an example can be found in the configs directory

| Variable Name      | Description                          | Default Value | Required |
|--------------------|--------------------------------------|--------------|----------|
| `source_env` | The source environment name (PRD, SUP, etc.) | none      | Yes   |
| `target_env` | The target environment name (SUP, RPT, etc.) | none      | Yes   |
| `rp_retention_days` | Number of days to retain the Recovery Point of the source system | 1 | Yes |
| `max_age_minutes` | How far back in minutes do we consider a RecoveryPoint valid for this refresh | none | Yes |
| `iris_freeze_cmd` | Command to run on the source virtual machine to freeze iris | none | Yes |
| `iris_thaw_cmd` | COmmand to run on the source virtual machine to thaw iris | none | Yes |
| `vgs` | Definition of Volume Groups and Filesystems to be cloned and mounted (See example) | none | Yes |
| `vgs.ntnx_name` | The name of the Volume Group in Prism Central to be cloned | none | Yes |
| `vgs.source_host_vg_name` | The name of the Volume Group in Linux to be cloned | none | Yes |
| `vgs.target_host_vg_name` | The name of the Volume Group in Linux the cloned version should be named | none | Yes |
| `vgs.lvs` | The logical volumes and filesystems that will be cloned.  Note: any LV or filesystem not listed here will not be mounted, but will be included in the clone if it's included in the volume group. | none | Yes |
| `vgs.lvs.source_lv` | The name of the logical volume in Linux on the source virtual machine | none | Yes |
| `vgs.lvs.target_lv` | The name that the cloned logical volume will be named in Linux on the target virtual machine | none | Yes |
| `vgs.lvs.target_mp` | The mount point that the cloned logical volume will be mounted to on the target virtual machine | none | Yes |
| 'load_balance_target_vg' | Set this to true to enable VGLB for the mounted target volume groups |
| `lvm_locking_option` | This will enable the --nolocking feature for vgimportclone | false | No |
| `cluster_name` | The name of the Nutanix Cluster the clone will be created on | none | Yes |
| `prism_host` | The IP address or hostname of Prism Central | none | Yes |
| `validate_certs` | Whether SSL certs should be validated | true | Yes |
| `prism_username` | Username for Prism Central with appropriate rights to create Recovery Points and Volume Groups and Attach/Detach Volume Groups (This should be in a vault!)| none | Yes |
| `prism_password` | Password for Prism Central user (This should be in a vault!) | none | Yes |

## Sample Variables File

```yaml
# ------------------------------
# Environment to Refresh  
# This will be be a part of the name for VGs and RPs
# ------------------------------
source_env: "PRD"
target_env: "SUP"

# ------------------------------
# Retention for Recovery Points for extra recovery capabilities
# ------------------------------
rp_retention_days: 7

# ------------------------------
# Maximum age for the Recovery Point we use as a source for our VGs
# ------------------------------
max_age_minutes: 120

# ------------------------------
# Commands to Freeze and Thaw the database
# ------------------------------
iris_freeze_cmd: "/epic/{{ source_env }}/bin/instfreeze"
iris_thaw_cmd: "/epic/{{ source_env }}/bin/instthaw"

# ------------------------------
# Volume Group Definitions and FS Mapping
#
#  - ntnx_name: Name of Volume Group in Prism Central
#    source_host_vg_name: Name of Volume Group in Source Host
#    target_host_vg_name: New Name of Volume Group on Target Host
#    lvs:
#        - source_lv: Name of LV in Source Host
#          target_lv: New Name of LV on Target Host
#          target_mp: Mount Point of LV on Target Host
# ------------------------------
vgs:
  - ntnx_name: "EPICVG"
    source_host_vg_name: "EpicVG"
    target_host_vg_name: "EpicSupVG"
    lvs:
        - source_lv: 'test_vol1'
          target_lv: '{{ target_env }}_vol1'
          target_mp: '/{{target_env}}_v1'
        - source_lv: 'test_vol2'
          target_lv: '{{ target_env }}_vol2'
          target_mp: '/{{target_env}}_v2'
        - source_lv: 'test_vol3'
          target_lv: '{{ target_env }}_vol3'
          target_mp: '/{{target_env}}_v3'

  - ntnx_name: "EPICvg2"
    source_host_vg_name: "EpicVG2"
    target_host_vg_name: "EpicSupVG2"
    lvs:
        - source_lv: 'test_vol4'
          target_lv: '{{ target_env }}_vol4'
          target_mp: '/{{target_env}}_v4'
        - source_lv: 'test_vol5'
          target_lv: '{{ target_env }}_vol5'
          target_mp: '/{{target_env}}_v5'

# ------------------------------
# Nutanix Cluster Info
# ------------------------------
cluster_name: "NTNX-CLUSTER1"
prism_host: "mypc.mydomain.com"
validate_certs: true

# ------------------------------
# Nutanix Cluster Credentials
#  THESE SHOULD BE IN A VAULT
# ------------------------------
prism_username: "admin"
prism_password: "myadminpassword"

```

## Usage

Creating the Snapshot of the Epic Environment:

```sh
ansible-playbook -i ./configs/refresh_odb_inv.ini --extra-vars @./configs/refresh_odb_vars.yml create_epic_snapshot.yml
```

Cloning and Mounting the snapshot of the Epic environment:

```sh
ansible-playbook -i ./configs/refresh_odb_inv.ini --extra-vars @./configs/refresh_odb_vars.yml clone_mount_epic_snapshot.yml
```

## Troubleshooting

* In most cases if there is a failure, rerunning the playbook will resolve it for you.
* If the Recovery Point is older than the defined number of minutes, the Volume Group wil not mount on the target host and the playbook will fail.  If this is the case either extend the defined number of minutes for the age of the Recovery Point or rerun the create_epic_snapshot playbook to get a new one

## Objects Created

For each volume group both a Recovery Point and a cloned Volume Group will be created.   They will follow the naming convention:

* Recovery Point -- REFRESH-SOURCE-TARGET-FR-TIMESTAMP
* Volume Group -- REFRESH-SOURCE-TARGET-VGNAME-TIMESTAMP

Neither object is dependent upon the other, so the Recovery Point can be removed without impacting the clone of the Volume Group

## Change Log

| Date       | Author        | Description           |
|------------|---------------|-----------------------|
| 2025-07-25 | Kurt Telep    | Initial documentation |
