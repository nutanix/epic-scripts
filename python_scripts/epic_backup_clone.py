import subprocess
import urllib3
import requests
import uuid
import sys
import time
import logging
import argparse
import yaml
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry
from datetime import datetime, timedelta, timezone

# Setup parameter parsing
parser = argparse.ArgumentParser()
parser.add_argument("-v", "--verbose", action="store_true", help="Verbose debug output")
parser.add_argument("-c", "--config", default="config.yml",help="Path to the YAML configuration file")
args = parser.parse_args()

# Disable SSL warnings for self-signed certificates
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

# Prepare our logger and our parser
logger = logging.getLogger("StatusLogger")

def load_config(config_file):
    # Loads the configuration file, and sets a bunch of our global variables 
    # Appropriately for managing the refresh process

    global PC_IP, USERNAME, PASSWORD, RECOVERY_POINT_RETENTION_DAYS, COPY_TYPE
    global SOURCE_ENV, TARGET_ENV, SOURCE_VM_NAME, SOURCE_HOST, SOURCE_USER
    global FREEZE_COMMAND, THAW_COMMAND, TARGET_VM_NAME, TARGET_HOST, TARGET_USER, VGS
    global LVM_BYPASS, DB_FROZEN, RP_API_URL, VG_API_URL, VM_API_URL, DELETE_VG

    # Load the configuration file
    try:
        with open(config_file, "r") as file:
            config = yaml.safe_load(file)

    except FileNotFoundError:
        print(f"[CRIT] Configuration file '{args.config}' not found. Exiting.")
        sys.exit(1)
    except yaml.YAMLError as e:
        print(f"[CRIT] Error parsing YAML file: {e}")
        sys.exit(1)

    try:
        # PC Info
        PC_IP = config['prism_central']['ip']
        USERNAME = config['prism_central']['username']
        PASSWORD = config['prism_central']['password']

        # Job Configuration Required Parameters
        COPY_TYPE = config['job_settings']['copy_type']
        SOURCE_ENV = config['job_settings']['source_env']

        # Job Configuration Optional parameters with defaults
        RECOVERY_POINT_RETENTION_DAYS = config['job_settings'].get('recovery_point_retention_days',1)
        DELETE_VG = config['job_settings'].get('delete_vg_after_disconnect',True)
        TARGET_ENV = config['job_settings'].get('target_env', None)


        # Source Parameters
        SOURCE_VM_NAME = config['source']['vm_name']
        SOURCE_HOST = config['source']['host']
        SOURCE_USER = config['source']['user']
        FREEZE_COMMAND = config['source']['freeze_command']
        THAW_COMMAND = config['source']['thaw_command']

        # Target Parameters
        TARGET_VM_NAME = config['target']['vm_name']
        TARGET_HOST = config['target']['host']
        TARGET_USER = config['target']['user']

        # VG and LV configurations
        VGS = config['vgs']

        if (not TARGET_ENV) and (COPY_TYPE == "REFRESH"):
            print(f"[CRIT] TARGET_ENV must be defined in config file if COPY_TYPE is REFRESH")
            sys.exit(1)

    except KeyError as e:
        print(f"[CRIT] missing parameter in configuration file: {e}")
        sys.exit(1)

    # LVM bypass configuration string
    LVM_BYPASS = "--config 'devices { global_filter=[\"a|.*|\"] }'"

    # Database State Tracking to make sure we're thawing
    DB_FROZEN = False

    # Our API URLS
    BASE_URL = f"https://{PC_IP}:9440/api"
    RP_API_URL = f"{BASE_URL}/dataprotection/v4.0/config/recovery-points"
    VG_API_URL = f"{BASE_URL}/volumes/v4.0/config/volume-groups"
    VM_API_URL = f"{BASE_URL}/vmm/v4.0"


## Some logging formatting
class StatusFormatter(logging.Formatter):
    """Custom formatter that maps log levels to visual status brackets."""
    
    LEVEL_FORMATS = {
        logging.DEBUG:    f"%(asctime)s [DEBUG] %(message)s",
        logging.INFO:     f"%(asctime)s [ OK ] %(message)s",
        logging.WARNING:  f"%(asctime)s [WARN] %(message)s",
        logging.ERROR:    f"%(asctime)s [FAIL] %(message)s",
        logging.CRITICAL: f"%(asctime)s [CRIT] %(message)s"
    }

    def __init__(self):
        super().__init__("%(asctime)s %(message)s", datefmt="%Y-%m-%d %H:%M:%S")

    def format(self, record):
        orig_fmt = self._style._fmt
        self._style._fmt = self.LEVEL_FORMATS.get(record.levelno, "%(asctime)s %(message)s")
        result = super().format(record)
        self._style._fmt = orig_fmt
        return result

## HOST FUNCTIONS
def run_remote_command(host, user, command, check=True):
    """ Executes a remote command via SSH, captures the outputs and logs details"""
    logger.debug(f"Running command on {host}: {command}")

    result = subprocess.run([
        "ssh", "-o", "StrictHostKeyChecking=accept-new", "-o", "PasswordAuthentication=no",
        f"{user}@{host}", command
    ], capture_output=True, text=True)

    logger.debug(f"{host} [  RC  ]: RC={result.returncode}")
    if result.stdout.strip():
        outlines = result.stdout.strip().split("\n")
        for line in outlines:
            logger.debug(f"{host} [STDOUT]: {line}")

    if result.stderr.strip():
        outlines = result.stderr.strip().split("\n")
        for line in outlines:
            logger.debug(f"{host} [STDERR]: {line}")

    if check and result.returncode != 0:
        logger.error(f"Command failed on {host} with exit code {result.returncode}: {result.stderr}")
        raise subprocess.CalledProcessError(result.returncode, command, result.stdout, result.stderr)

    return result

def ensure_mount_points_exist():
    logger.info(f"Ensuring that mount points exist on {TARGET_HOST}")

    for vg in VGS:
        mount_point_list = vg['mounts'].keys()
        for mount in mount_point_list:
            try:
                logger.info(f"Verifying: {vg['mounts'][mount]} for LV {mount}")
                cmd = f"sudo /usr/bin/mkdir -p {vg['mounts'][mount]}" 
                run_remote_command(TARGET_HOST,TARGET_USER,cmd,True)
                logger.info(f"  Mount is Good")
            except subprocess.CalledProcessError as e:
                error_msg = f"Failed to create {vg['mounts'][mount]}: {e}"
                logger.warning(error_msg)
                raise RuntimeError(error_msg)
                

def check_if_mounted(mount_point):
    """ Confirms if a filesystem is mounted or not on teh remote system """
    logger.info(f"Checking if {mount_point} is mounted on {TARGET_HOST}")

    cmd = f"sudo /usr/bin/df {mount_point}"
    try:
       run_remote_command(TARGET_HOST,TARGET_USER,cmd,True)
       logger.info(f"  {mount_point} is mounted")
       return True
    except subprocess.CalledProcessError as e:
       logger.info(f"  {mount_point} is not mounted")
       return False

def check_vg_active(vg_name):
    """ Checks if a VG is in an active or deactivated state """
    """ Returns True if Active, False if Deactivated, and None if it can't find the VG """
    logger.info(f"Check if {vg_name} is active")
    cmd = f'sudo /usr/sbin/lvs --noheadings -o lv_name,lv_attr {vg_name}'
    try: 
        result = run_remote_command(TARGET_HOST,TARGET_USER,cmd,True)
    except subprocess.CalledProcessError as e:
        logger.info(f"   {vg_name} does not appear to exist")
        return None

    lv_data = result.stdout.strip().split('\n')
    vg_active = False

    for line in lv_data:
        lv_name, lv_attr = line.split()
        if len(lv_attr) >= 5 and lv_attr[4] == 'a':
            logger.info(f"  LV {lv_name} appears active in {vg_name}")
            vg_active = True

    return vg_active

## NUTANIX API FUNCTIONS
def setup_session():
    # Sets up our session and handle our rate limiting
    global session     # This just makes it easier to pass around 
    session = requests.session()
    session.auth = (USERNAME,PASSWORD)
    session.verify = False

    # prep for API rate limiting
    retries = Retry(
        total=5,         
        backoff_factor=1,
        status_forcelist=[429, 500, 502, 503, 504],
        allowed_methods=["GET", "POST", "DELETE", "PUT"]
    )

    adapter = HTTPAdapter(max_retries=retries)
    session.mount('https://', adapter)
    session.mount('http://', adapter)

def get_headers(need_request_id=None):
    """ Sets up our headers """
    headers = {
        "Content-Type": "application/json",
        "Accept": "application/json"
    }
    if need_request_id:
        headers["NTNX-Request-ID"] = str(uuid.uuid4())
    return headers

def _make_request(method, url, payload=None, req_params=None, need_request_id=None):
    """ Nutanix API Request Handler """
    logger.debug(f"NTNX {method} Request: {url}")
    
    # We use the session here instead of requests.get/post directly
    response = session.request(
        method=method,
        url=url,
        headers=get_headers(need_request_id),
        params=req_params,
        json=payload,
        timeout=10
    )
    
    logger.debug(f"Response: {response.status_code}")
    response.raise_for_status()
    
    # Safely handle APIs that return empty bodies
    if response.status_code == 204 or not response.text:
        return {}
        
    return response.json()

def ntnx_get_request(url, req_params=None, need_request_id=None):
    return _make_request("GET", url, req_params=req_params, need_request_id=need_request_id)

def ntnx_post_request(url, payload=None, need_request_id=None):
    return _make_request("POST", url, payload=payload, need_request_id=need_request_id)

def ntnx_delete_request(url, need_request_id=None):
    return _make_request("DELETE", url, need_request_id=need_request_id)

def get_vm_uuid(vm_name):
    params={'$filter': f"name eq '{vm_name}'"}
    response = ntnx_get_request(f"{VM_API_URL}/ahv/config/vms",params)

    if response['data']:
        vm_uuid = response['data'][0]['extId'] 
        logger.debug(f"  VM: {vm_name} UUID: {vm_uuid}")
        return vm_uuid
    else:
        return None

def get_attached_vgs(vm_uuid):
    response = ntnx_get_request(f"{VM_API_URL}/ahv/config/vms/{vm_uuid}/disks")

    if response['data']:
        vg_disk_data = response['data']

    vg_ids = list()
    for disk in vg_disk_data:
        if "volumeGroupExtId" in disk['backingInfo']:
            vg_ids.append(disk['backingInfo']['volumeGroupExtId'])

    return vg_ids

def get_vgid_details(vg_uuid):
    params = { '$filter': "extId eq '" + vg_uuid + "'" }
    response = ntnx_get_request(VG_API_URL,params)

    return response

def get_vg_details(vg_name):
    params = { '$filter': "name eq '" + vg_name + "'" }
    response = ntnx_get_request(VG_API_URL,params)

    return response

def get_rp_details(rp_id):
    response = ntnx_get_request(f"{RP_API_URL}/{rp_id}")

    return response

def create_vg_rp(vg_uuid, rp_name, rp_expiration):
    rp_payload = {
        "name": rp_name,
        "expirationTime": rp_expiration,
        "recoveryPointType": "CRASH_CONSISTENT",
        "volumeGroupRecoveryPoints": [ 
            {
                 "volumeGroupExtId": vg_uuid
            }
        ]
    }

    response = ntnx_post_request( RP_API_URL,rp_payload,True)
    return response

def clone_vg_rp(cluster_ref, rp_id, vg_rp_id, new_vg_name):
    clone_payload = {
        "clusterExtId": cluster_ref,
        "volumeGroupRecoveryPointRestoreOverrides": [
            {
                "volumeGroupRecoveryPointExtId": vg_rp_id,
                "volumeGroupOverrideSpec": {
                    "name": new_vg_name
                }
            }
        ]
    }
    response = ntnx_post_request(f"{RP_API_URL}/{rp_id}/$actions/restore",clone_payload,True)
    return response

def attach_vg_to_vm(vg_id, vm_uuid):
    attach_payload = { "extId": vm_uuid } 
    response = ntnx_post_request(f"{VG_API_URL}/{vg_id}/$actions/attach-vm",attach_payload,True)

    return response

def detach_vg_from_vm(vg_id, vm_uuid):
    detach_payload = { "extId": vm_uuid } 
    response = ntnx_post_request(f"{VG_API_URL}/{vg_id}/$actions/detach-vm",detach_payload,True)

    return response

def delete_ntnxvg(vg_id):
    response = ntnx_delete_request(f"{VG_API_URL}/{vg_id}",True)
    return response

def wait_on_task(task_url, check_interval=5):
    while True:
        task_data = ntnx_get_request(task_url)

        if task_data['data']['status'] == 'SUCCEEDED':
            return task_data['data']['completionDetails']
        elif task_data['data']['status'] == 'FAILED':
            return None
        else:
            time.sleep(check_interval)


def clone_and_attach_vgs():
    # Clone the production Volume Group and attach it to the Target VM

    # Generate Timestamps and Expiration Dates for the snapshots
    future_date = datetime.now(timezone.utc) + timedelta(days=RECOVERY_POINT_RETENTION_DAYS)
    recovery_point_expiration = future_date.strftime("%Y-%m-%dT%H:%M:%SZ")
    current_timestamp = datetime.now(timezone.utc).strftime("%Y%m%d%H%M%S")

    # Grab our source Volume Group Details from Prism Central
    for vg in VGS:
        logger.info("Retrieving Volume Group details for: " + vg['ntnx_source_vg'])
        vg_data = get_vg_details(vg['ntnx_source_vg'])
        if (vg_data):
            vg['ntnx_source_uuid'] = vg_data['data'][0]['extId']
            vg['ntnx_cluster_ref'] = vg_data['data'][0]['clusterReference']
            vg['url'] = vg_data['data'][0]['links'][0]['href']
            logger.debug(f"UUID: {vg['ntnx_source_uuid']} - Cluster UUID: {vg['ntnx_cluster_ref']}")
        else:
            error_msg = f"Volume Group {vg['ntnx_source_vg']} not found in Prism Central. Exiting."
            logger.critical(error_msg)
            raise RuntimeError(error_msg)


    # Create our Recovery Point Payloads
    for vg in VGS:
        if COPY_TYPE == "REFRESH":
            label_prefix = f"REFRESH-{SOURCE_ENV}-{TARGET_ENV}" 
        else:
            label_prefix = f"BACKUP"

        rp_name = f"{label_prefix}-{vg['ntnx_source_vg']}-RP-{current_timestamp}"

        logger.info(f"Creating Recovery Point for Volume Group: {vg['ntnx_source_vg']}")
        logger.info(f"  RP Name: {rp_name}")

        create_response = create_vg_rp(vg['ntnx_source_uuid'], rp_name, recovery_point_expiration)
        if (create_response):
            logger.info(f"  Task for Recovery Point for Volume Group created")
            vg["rp_task_url"] = create_response['metadata']['links'][0]['href']
        else:
            error_msg = f"  Failed to create Recovery Point for Volume Group: {vg['ntnx_source_vg']}"
            logger.critical(error_msg)
            raise RuntimeError(error_msg)

    # Wait for our RP creation tasks to complete 
    for vg in VGS:
        logger.info(f"Waiting for Recovery Point creation task to complete for Volume Group: {vg['ntnx_source_vg']}")
        rp_task_details = wait_on_task(vg["rp_task_url"])
        if(rp_task_details):
            logger.info(f"  Recovery Point creation for Volume Group Successful")
            vg["rp_id"] = rp_task_details[0]['value']
        else:
            error_msg = f"  Recovery Point creation task failed for Volume Group: {vg['ntnx_source_vg']}"
            logger.critical(error_msg)
            raise RuntimeError(error_msg)

        # Grab the Recovery Point details for the Volume Group
        logger.info("  Collecting details about created Recovery Point")
        rp_response = get_rp_details(vg['rp_id'])
        if (rp_response):
            vg["vg_rp_ext_id"] = rp_response['data']['volumeGroupRecoveryPoints'][0]['extId']
            logger.debug(f"    RP UUID: {vg['vg_rp_ext_id']}")
        else:
            error_msg = f"  Failed to retrieve Recovery Point details for Volume Group: {vg['ntnx_source_vg']}"
            logger.critical(error_msg)
            raise RuntimeError(error_msg)

    # Now we can clone the Recovery Point to a new Volume Group
    for vg in VGS:
        new_vg_name = f"{label_prefix}-{vg['ntnx_source_vg']}-{current_timestamp}"
        vg['clone_vg_name'] = new_vg_name

        logger.info(f"Cloning Recovery Point to new Volume Group for: {vg['ntnx_source_vg']}")
        logger.info(f"  New VG Name will be: {new_vg_name}")

        clone_response = clone_vg_rp(vg['ntnx_cluster_ref'], vg['rp_id'], vg['vg_rp_ext_id'], new_vg_name)
        if (clone_response):
            logger.info(f"  Task creation for cloning for Volume Group Successful")
            vg["vg_task_url"] = clone_response['metadata']['links'][0]['href']
        else:
            error_msg = f"  Failed to initiate clone for Volume Group: {vg['ntnx_source_vg']}"
            logger.critical(error_msg)
            raise RuntimeError(error_msg)

    # Wait for our VG clone creation tasks to complete 
    for vg in VGS:
        logger.info(f"  Waiting for VG clone creation task to complete for Volume Group: {vg['clone_vg_name']}")
        task_details = wait_on_task(vg["vg_task_url"])
        if(task_details):
            logger.info(f"  Task for cloning Volume Group Successful")
            vg["clone_vg_id"] = task_details[0]['value']
        else:
            error_msg = f"  VG clone creation task failed for Volume Group: {vg['ntnx_source_vg']}"
            logger.critical(error_msg)
            raise RuntimeError(error_msg)

        vg["clone_vg_id"] = task_details[0]['value']

    # Get the Proxy VM's UUID, we'll need it later for mounting
    proxy_vm_uuid = get_vm_uuid(TARGET_VM_NAME)

    # Now lets attach our clones to the VM
    for vg in VGS:
        logger.info(f"Attaching new Volume Group {vg['clone_vg_name']} to Proxy VM {TARGET_VM_NAME}")
        new_vg_id = vg["clone_vg_id"]
        attach_response = attach_vg_to_vm(new_vg_id, proxy_vm_uuid)
        if (attach_response):
            logger.info(f"  Successfully attached Volume Group {vg['ntnx_source_vg']} to Proxy VM {TARGET_VM_NAME}")
        else:
            error_msg = f"  Failed to attach Volume Group {vg['ntnx_source_vg']} to Proxy VM {TARGET_VM_NAME}"
            logger.critical(error_msg)
            raise RuntimeError(error_msg)

    logger.info("-----------------------------------------------------")
    logger.info(f"Storage successfully attached to {TARGET_HOST}")
    logger.info("-----------------------------------------------------")

def detach_and_delete_vgs(delete_vg=False):
    # This function detaches any VGs currently attached to the mount host, and 
    # optionally deletes them, cleaning up and preparing for the refresh mount

    # Get the Proxy VM's UUID, we'll need it later for unmounting
    proxy_vm_uuid = get_vm_uuid(TARGET_VM_NAME)
    attached_vgids = get_attached_vgs(proxy_vm_uuid) 

    # Now lets detach our clones from the VM
    for vg_id in attached_vgids:
        vg_details = get_vgid_details(vg_id)
        vg_name = vg_details['data'][0]['name']
        logger.info(f"Detaching Volume Group {vg_name} from Proxy VM {TARGET_VM_NAME}")
        try:
            detach_vg_from_vm(vg_id,proxy_vm_uuid)
            logger.info(f"  Successfully detached Volume Group {vg_name} from Proxy VM {TARGET_VM_NAME}")
        except requests.exceptions.HTTPError as e:
            logger.warning(f"  Failed to detach Volume Group {vg_name} from Proxy VM {TARGET_VM_NAME}: {e}")

        # Lets delete the VG also
        if delete_vg:
            logger.info(f"  Deleting Volume Group {vg_name}")
            try:
                delete_ntnxvg(vg_id)
                logger.info(f"  Successfully deleted Volume Group {vg_name} from Proxy VM {TARGET_VM_NAME}")
            except requests.exceptions.HTTPError as e:
                logger.warning(f"  Failed to delete Volume Group {vg_name} from Proxy VM {TARGET_VM_NAME}")

    logger.info("-----------------------------------------------------")
    logger.info(f"Storage successfully detached from {TARGET_HOST}")
    logger.info("-----------------------------------------------------")

def freeze_prod():
    logger.info(f"Connecting to {SOURCE_HOST} to freeze ODB")
    try:
        run_remote_command(SOURCE_HOST,SOURCE_USER,FREEZE_COMMAND,True)
        logger.info("-----------------------------------------------------")
        logger.info("  Database frozen successfully")
        logger.info("-----------------------------------------------------")
        DB_FROZEN = True
    except subprocess.CalledProcessError as e:
        error_msg = f"Failed to execute freeze: {e}"
        logger.critical(error_msg)
        raise RuntimeError(error_msg)

def thaw_prod():
    logger.info(f"Connecting to {SOURCE_HOST} to thaw ODB")
    try:
        run_remote_command(SOURCE_HOST,SOURCE_USER,THAW_COMMAND,True)
        logger.info("------------------------------------")
        logger.info("  Database thawed successfully")
        logger.info("------------------------------------")
        DB_FROZEN = False
    except subprocess.CalledProcessError as e:
        error_msg = f"Failed to execute thaw: {e}"
        logger.critical(error_msg)
        raise RuntimeError(error_msg)

def mount_proxy():
    # Perform all the Linux actions to import the volume groups, perform
    # any renaming, and mount the filesystems.
    ensure_mount_points_exist()

    logger.debug("Collecting lsblk information from proxy before rescans")
    logger.debug("System may have already detected devices")
    run_remote_command(TARGET_HOST,TARGET_USER,"sudo /usr/bin/lsblk")

    logger.info(f"Performing disk rescan operations on {TARGET_HOST}")
    try:
        logger.info("  Executing Linux SCSI hardware rescan") 
        cmd = "sudo sh -c 'for h in /sys/class/scsi_host/host*/scan; do echo \"- - -\" > $h; done'"
        run_remote_command(TARGET_HOST,TARGET_USER,cmd,True)

        logger.info("  Performing full pvscan of all devices for LV")
        cmd = f"sudo /usr/sbin/pvscan --cache {LVM_BYPASS}"
        run_remote_command(TARGET_HOST,TARGET_USER,cmd,True)

        logger.info("  Forcing LVM to scan all devices (bypassing filter)...")
        cmd = f"sudo /usr/sbin/vgscan {LVM_BYPASS}"
        run_remote_command(TARGET_HOST,TARGET_USER,cmd,True)

        logger.debug("Collecting lsblk information from proxy after rescans")
        run_remote_command(TARGET_HOST,TARGET_USER,"sudo /usr/bin/lsblk")

    except subprocess.CalledProcessError as e:
        error_msg = f"  Failed to rescan disks on target host: {e}"
        logger.critical(error_msg)
        raise RuntimeError(error_msg)

    logger.info("Activating LVM Volume Groups and Mounting XFS filesystems")

    for vg in VGS:
        vg_name = vg['source_lvm_vg']

        logger.info(f"Processing VG: {vg_name}")

        # Vary on the Volume Group
        logger.info(f"  Making {vg_name} active")
        cmd = f"sudo /usr/sbin/vgchange -ay {vg_name} {LVM_BYPASS}" 
        run_remote_command(TARGET_HOST,TARGET_USER,cmd,True)

        logger.info(f"  Waiting for udev to populate {vg_name} device mapper nodes")
        time.sleep(5)

        # Validating if anything needs to be renamed
        rename_lv = False
        rename_vg = False

        # Check if we actually need to do a rename on the VG or LVs
        new_vg_name = vg['target_lvm_vg']
        if new_vg_name != vg_name:
            rename_vg = True

        if COPY_TYPE == "REFRESH":
            # Search for ANY LV that would need to be renamed 
            matches = [item for item in vg['mounts'].keys() if SOURCE_ENV in item]
            if matches:
                rename_lv = True

        # The VG has to be varied off if we're going to rename either VGs or LVs
        if rename_lv or rename_vg:
            logger.debug(f"  Gathering pvs that are in the VG")
            cmd = f"sudo /usr/sbin/vgs -o pv_name --noheadings {vg_name}"
            pv_list = run_remote_command(TARGET_HOST,TARGET_USER,cmd,True)

            logger.debug(f"  Varying off Volume Group")
            cmd = f"sudo /usr/sbin/vgchange -an {vg_name} {LVM_BYPASS}"
            run_remote_command(TARGET_HOST,TARGET_USER,cmd,True)

        if rename_vg:
            logger.info(f"  Renaming Volume Group from {vg_name} to {new_vg_name}")

            logger.debug(f" Reimporting and Renaming VG")
            pvs = " ".join(pv_list.stdout.strip().split())
            cmd = f"sudo /usr/sbin/vgimportclone -v -n {new_vg_name} {pvs}"
            run_remote_command(TARGET_HOST,TARGET_USER,cmd,True)

        # Rename our logical volumes
        if rename_lv:
            new_mounts = dict()
            for logical_volume in vg['mounts'].keys():

                if TARGET_ENV:
                    new_lv_name = logical_volume.replace(SOURCE_ENV,TARGET_ENV)

                # SKIP if the LV Name isn't changing
                if new_lv_name != logical_volume:
                    logger.info(f"  Renaming LV {logical_volume}")
                    cmd = f"sudo /usr/sbin/lvrename {new_vg_name} {logical_volume} {new_lv_name}"
                    run_remote_command(TARGET_HOST,TARGET_USER,cmd,True)

                new_mounts[new_lv_name] = vg['mounts'][logical_volume]

            vg['mounts'] = new_mounts

        # Reactivate our VG if we had to vary it off
        if rename_lv or rename_vg:
            logger.info(f"  Reactivating {new_vg_name}")
            cmd = f"sudo /usr/sbin/vgchange -ay {new_vg_name} {LVM_BYPASS}" 
            run_remote_command(TARGET_HOST,TARGET_USER,cmd,True)

            logger.info(f"  Waiting for udev to populate {new_vg_name} device mapper nodes")
            time.sleep(5)

        # Update VG Name variables so the rest of the flow works as expected
        # Note new_vg_name and new_mounts will be the same as the existing if no renaming is needed
        vg["source_lvm_vg"] = new_vg_name
        vg_name = new_vg_name

        for logical_volume in vg['mounts'].keys():
            logger.info(f"Mounting {logical_volume} to {vg['mounts'][logical_volume]}")
            logger.info(f"  Determining LVM path for {logical_volume}")

            # Get the LV Path
            cmd = f"sudo /sbin/lvs --noheadings -o lv_path {vg_name}/{logical_volume}" 
            result = run_remote_command(TARGET_HOST,TARGET_USER,cmd,True)
            lv_path = result.stdout.rstrip()

            # Mount our filesystem
            logger.info(f"  Performing Mount onto {lv_path}")
            cmd = f"sudo /usr/bin/mount -o ro,nouuid {lv_path} {vg['mounts'][logical_volume]}; "

            try:
                run_remote_command(TARGET_HOST,TARGET_USER,cmd,True)

            except subprocess.CalledProcessError as e:
                error_msg = f"  Failed mounting {logical_volume} on {vg['mounts'][logical_volume]}"
                logger.critical(error_msg)
                raise RuntimeError(error_msg)

            if COPY_TYPE == "REFRESH":
                # If we're doing a refresh we need to generate a new UUID and remount read/write
                logger.info(f" Unmounting to updating XFS UUID")

                try:
                    logger.info(f"  Unmounting {vg['mounts'][logical_volume]}")
                    cmd = f"sudo /usr/bin/umount {vg['mounts'][logical_volume]}"
                    result = run_remote_command(TARGET_HOST,TARGET_USER,cmd,True)

                    logger.info(f"  Generating new UUID for {lv_path}")
                    cmd = f"sudo /usr/sbin/xfs_admin -U generate {lv_path}"
                    result = run_remote_command(TARGET_HOST,TARGET_USER,cmd,True)

                    logger.info(f"  Remounting {vg['mounts'][logical_volume]} Read/Write")
                    cmd = f"sudo /usr/bin/mount {lv_path} {vg['mounts'][logical_volume]}; "
                    run_remote_command(TARGET_HOST,TARGET_USER,cmd,True)
            
                except subprocess.CalledProcessError as e:
                    error_msg = f"  Reid and Remount failed for LV: {logical_volume} on {vg['mounts'][logical_volume]}"
                    logger.critical(error_msg)
                    raise RuntimeError(error_msg)

    logger.info("-----------------------------------------------------")
    logger.info("Storage successfully imported and filesystems mounted")
    logger.info("-----------------------------------------------------")

def clean_proxy():
    # Handles unmounting any filesystems that we're targeting and makes ure
    # the volume groups are all varied off before disk detachment
    for vg in VGS:
        vg_name = vg['target_lvm_vg']

        # Unmount our filesystems
        logger.info("Unmounting Filesystems")

        for logical_volume in vg['mounts'].keys():
            if check_if_mounted(vg['mounts'][logical_volume]):
                logger.info(f"  Unmounting {vg['mounts'][logical_volume]}")
                unmount_cmd = f"sudo /usr/bin/umount {vg['mounts'][logical_volume]}"

                try:
                    run_remote_command(TARGET_HOST,TARGET_USER,unmount_cmd,True)
                except subprocess.CalledProcessError as e:
                    error_msg = f"  Unmount failed for LV: {logical_volume} on {vg['mounts'][logical_volume]}"
                    logger.warning(error_msg)
            else:
                logger.info(f"  {vg['mounts'][logical_volume]} is not mounted")

        # Vary off the Volume Group
        logger.info(f"  Checking Volume Group: {vg_name}")
        # We only deactivate if the VG exists and is active
        if check_vg_active(vg_name):
            cmd = f"sudo /usr/sbin/vgchange -an {vg_name} {LVM_BYPASS}"
            try:
                logger.info(f"  Deactivating Volume Group: {vg_name}")
                run_remote_command(TARGET_HOST,TARGET_USER,cmd,True)
            except subprocess.CalledProcessError as e:
                error_msg = f"  Deactivating VG failed for VG: {vg_name}"
                logger.critical(error_msg)
                raise RuntimeError(error_msg)
        else:
            logger.info("  Volume Group already deactivated or does not exist")

    logger.info("-----------------------------------------------------")
    logger.info("  Target Cleanup Completed")
    logger.info("-----------------------------------------------------")


def test_connectivity():
    try:
        # Lets get a list of VMs
        logger.info(f"Testing Connectivity to PC at {PC_IP}")
        ntnx_get_request(f"{VM_API_URL}/ahv/config/vms")
        logger.info(f"Testing Connectivity to {SOURCE_HOST} as {SOURCE_USER}")
        run_remote_command(SOURCE_HOST,SOURCE_USER,"date",True)
        logger.info(f"Testing Connectivity to {TARGET_HOST} as {TARGET_USER}")
        run_remote_command(TARGET_HOST,TARGET_USER,"date",True)
    except Exception as e:
        logger.critical(f"Connectivity Testing Failed: {e}")
        logger.critical("Permission denied error may be due to incorrectly configured SSH keys or incorrect username")
        sys.exit(1)


def setup_logging():
    # Setup our output logging
    logger.setLevel(logging.DEBUG)
    if logger.hasHandlers():
        logger.handlers.clear()
    
    console_handler = logging.StreamHandler(sys.stdout)
    if args.verbose:
        console_handler.setLevel(logging.DEBUG)
    else:
        console_handler.setLevel(logging.INFO)

    console_handler.setFormatter(StatusFormatter())
    logger.addHandler(console_handler)

def clear_lock_files():
    # Clear out all the Iris lock files that remain after the clone
    for vg in VGS:
        for lv_name in vg['mounts'].keys():
            mp_name = vg['mounts'][lv_name]
            logger.info(f"Removing Iris Lock Files in {mp_name}")
            cmd = f"sudo /usr/bin/rm -rf {vg['mounts'][lv_name]}/iris.lck"
            run_remote_command(TARGET_HOST,TARGET_USER,cmd,False)
    logger.info("------------------------------------")
    logger.info("  Lock File Cleanup Complete")
    logger.info("------------------------------------")

if __name__ == "__main__":

    load_config(args.config)
    setup_session()
    setup_logging()

    logger.info("------------------------------------")
    logger.info(f" Starting {COPY_TYPE}")
    logger.info("------------------------------------")

    test_connectivity()

    clean_proxy()
    detach_and_delete_vgs(DELETE_VG)

    # This wraps the freeze and clone operations in an exception catching block
    # so we will always thaw if we're frozen and something happens during the clone
    # process
    try:

        freeze_prod()
        clone_and_attach_vgs()

    finally:
    # Guarantee the production database gets thawed
        thaw_prod()

    mount_proxy()

    if COPY_TYPE == "REFRESH":
        clear_lock_files()