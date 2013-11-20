#!/usr/bin/env python

# Monitors the HTCondor queue for new jobs and idle nodes, and take proper
# actions.

import time
import logging, logging.handlers
import signal
import sys
import subprocess
import os
import xml.etree.ElementTree as ET
from ConfigParser import SafeConfigParser
import boto
import socket
import random
import base64


cf = {}
cf['elastiq'] = {

  # Main loop
  'sleep_s': 5,
  'check_queue_every_s': 15,
  'check_vms_every_s': 45,
  'estimated_vm_deploy_time_s': 600,

  # Conditions to start new VMs
  'waiting_jobs_threshold': 10,
  'waiting_jobs_time_s': 100,
  'n_jobs_per_vm': 4,

  # Conditions to stop idle VMs
  'idle_for_time_s': 3600,

  # Condor central server (defaults to current one)
  'condor_host': None

}
cf['ec2'] = {

  # Configuration to access EC2 API
  'api_url': 'https://dummy.ec2.server/ec2/',
  'aws_access_key_id': 'my_username',
  'aws_secret_access_key': 'my_password',

  # VM configuration
  'image_id': 'ami-00000000',
  'key_name': '',
  'flavour': '',
  'user_data_b64': ''

}
cf['quota'] = {

  # Min and max VMs
  'min_vms': 0,
  'max_vms': 3

}
cf['debug'] = {

  # Set to !0 to dry run
  'dry_run_shutdown_vms': 0,
  'dry_run_boot_vms': 0

}

ec2h = None
ec2img = None
user_data = None
do_main_loop = True


def type2str(any):
  return type(any).__name__


def conf():

  global cf

  # Set the default for some variables
  cmdo = robust_cmd(['condor_config_val', 'CONDOR_HOST'], max_attempts=1)
  if cmdo and 'output' in cmdo:
    # Try to find IP address from host name
    try:
      cf['elastiq']['condor_host'] = socket.gethostbyname(cmdo['output'].rstrip())
    except Exception:
      # TODO: current IP
      cf['elastiq']['condor_host'] = None

  cf_parser = SafeConfigParser()

  # etc dir at the same level of the bin dir containing this script
  close_etc_path = os.path.realpath( os.path.realpath(os.path.dirname(__file__)) + "/../etc" )

  # The last file has precedence over the first file
  config_files = [
    "/etc/elastiq.conf",
    "%s/elastiq.conf" % close_etc_path,
    os.path.expanduser("~/.elastiq.conf")
  ]
  cf_parser.read(config_files)

  # Print config files
  for f in config_files:
    logging.info("Configuration file: %s" % f)

  for sec_name,sec_content in cf.iteritems():

    for key,val in sec_content.iteritems():

      try:
        new_val = cf_parser.get(sec_name, key)  # --> [sec_name]
        try:
          new_val = float(new_val)
        except ValueError:
          pass
        cf[sec_name][key] = new_val
        logging.info("Configuration: %s.%s = %s (from file)", sec_name, key, str(new_val))
      except Exception, e:
        logging.info("Configuration: %s.%s = %s (default)", sec_name, key, str(val))


def log():
  """Configures logging. Outputs log to the console and, optionally, to a file.
  File name is automatically selected. Returns the file name, or None if it
  cannot write to a file."""

  format="%(asctime)s %(name)s %(levelname)s %(message)s"
  datefmt="%Y-%m-%d %H:%M:%S"
  level=logging.DEBUG

  # Log to console
  logging.basicConfig(level=level, format=format, datefmt=datefmt)

  # Log directory and file
  dir = os.path.realpath( os.path.realpath(os.path.dirname(__file__)) + "/../var/log" )
  filename = "%s/elastiq.log" % dir

  # Try to create log directory and file
  try:
    if not os.path.isdir(dir):
      os.makedirs(dir, 0755)
    log_file = logging.handlers.RotatingFileHandler(filename, mode="a", maxBytes=1000000, backupCount=30)
    log_file.setLevel(level)
    log_file.setFormatter( logging.Formatter(format, datefmt) )
    logging.getLogger("").addHandler(log_file)
    log_file.doRollover()  # rotate immediately
  except Exception, e:
    logging.warning("Cannot log to file %s: %s: %s" % (filename, type(e).__name__, e))
    return None

  # Silence boto errors
  logging.getLogger("boto").setLevel(logging.CRITICAL)

  return filename


def exit_main_loop(signal, frame):
  global do_main_loop
  logging.debug("Termination requested")
  do_main_loop = False


def robust_cmd(params, max_attempts=5, suppress_stderr=True):

  shell = isinstance(params, basestring)
  sp = None

  for n_attempts in range(1, max_attempts+1):

    try:
      if n_attempts > 1:
        logging.info("Waiting %ds before retrying..." % n_attempts)
        time.sleep(n_attempts)

      if suppress_stderr:
        with open(os.devnull) as dev_null:
          sp = subprocess.Popen(params, stdout=subprocess.PIPE, stderr=dev_null, shell=shell)
      else:
        sp = subprocess.Popen(params, stdout=subprocess.PIPE, shell=shell)
      sp.wait()
    except OSError:
      logging.error("Command cannot be executed!")
      continue

    if sp.returncode != 0:
      logging.debug("Command failed (returned %d)!" % sp.returncode)
    else:
      logging.info("Process exited OK");
      return {
        'exitcode': 0,
        'output': sp.communicate()[0]
      }

  if sp:
    logging.error("Giving up after %d attempts: last exit code was %d" % (max_attempts, sp.returncode))
    return {
      'exitcode': sp.returncode
    }
  else:
    logging.error("Giving up after %d attempts" % max_attempts)
    return None


def ec2_scale_up(nvms, valid_hostnames=None):
  """Requests a certain number of VMs using the EC2 API. Returns the number of
  VMs launched successfully. Note: max_quota is honored by checking the *total*
  number of running VMs, and not only the ones recognized by HTCondor. This is
  done on purpose to avoid overflowing the cloud (possibly a non-free one) with
  misconfigured VMs that don't join the HTCondor cluster."""

  global ec2img

  # Try to get image if necessary
  if ec2img is None:
    ec2img = ec2_image(cf['ec2']['image_id'])
    if ec2img is None:
      logging.error("Cannot scale up: image id %s not found" % ec2_image(cf['ec2']['image_id']))
      return 0

  n_succ = 0
  n_fail = 0
  logging.info("We need %d more VMs..." % nvms)

  inst = ec2_running_instances(valid_hostnames)
  if inst is None:
    logging.error("No list of instances can be retrieved from EC2")
    return 0

  n_running_vms = len(inst)  # number of *total* VMs running (also the ones *not* owned by HTCondor)
  if cf['quota']['max_vms'] >= 1:
    # We have a "soft" quota: respect it
    n_vms_to_start = int(min(nvms, cf['quota']['max_vms']-n_running_vms))
    if n_vms_to_start <= 0:
      logging.warning("Over quota (%d VMs already running out of %d): cannot launch any more VMs" % \
        (n_running_vms,cf['quota']['max_vms']))
    else:
      logging.warning("Quota enabled: requesting %d (out of desired %d) VMs" % (n_vms_to_start,nvms))
  else:
    n_vms_to_start = int(nvms)

  # Launch VMs
  for i in range(1, n_vms_to_start+1):

    success = False
    if int(cf['debug']['dry_run_boot_vms']) == 0:
      try:
        ec2img.run(
          key_name=cf['ec2']['key_name'],
          user_data=user_data,
          instance_type=cf['ec2']['flavour']
        )
        success = True
      except Exception:
        logging.error("Cannot run instance via EC2: check your \"hard\" quota")

    else:
      logging.info("Not running VM: dry run active")
      success = True

    if success:
      n_succ+=1
      logging.info("VM launched OK. Requested: %d/%d | Success: %d | Failed: %d" % \
        (i, n_vms_to_start, n_succ, n_fail))
    else:
      n_fail+=1
      logging.info("VM launch fail. Requested: %d/%d | Success: %d | Failed: %d" % \
        (i, n_vms_to_start, n_succ, n_fail))

  return n_succ


def ec2_running_instances(hostnames=None):
  """Returns all running instances visible with current EC2 credentials, or
  None on errors. If hostnames is specified, it returns the sole running
  instances whose IP address matches the resolved input hostnames. Returned
  object is a list of boto instances."""

  try:
    res = ec2h.get_all_reservations()
  except Exception, e:
    logging.error("Can't get list of EC2 instances (maybe wrong credentials?)")
    return None

  # Resolve IPs
  if hostnames is not None:
    ips = []
    for h in hostnames:
      try:
        ipv4 = socket.gethostbyname(h)
        ips.append(ipv4)
      except Exception:
        # Don't add host if IP address could not be found
        logging.warning("Ignoring hostname %s: can't reslove IPv4 address" % h)

  # Add only running instances
  inst = []
  for r in res:
    for i in r.instances:
      if i.state == 'running':
        if hostnames is None:
          # Append all
          inst.append(i)
        else:
          found = False
          for ipv4 in ips:
            if i.private_ip_address == ipv4:
              inst.append(i)
              logging.debug("Found IP %s corresponding to instance" % ipv4)
              found = True
              break
          if not found:
            logging.warning("Cannot find instance %s in the list of known IPs" % i.private_ip_address)

  return inst


def ec2_scale_down(hosts, valid_hostnames=None):
  """Asks the Cloud to shutdown hosts corresponding to the given hostnames
  by using the EC2 interface. Returns the number of hosts successfully shut
  down. Note: minimum number of VMs is honored by considering, as number of
  currently running VMs, the sole VMs known by HTCondor. This behavior is
  different than what we do for the maximum quota, where we take into account
  all the running VMs to avoid cloud overflowing."""

  n_succ = 0
  n_fail = 0

  if len(hosts) == 0:
    logging.warning("No hosts to shut down!")
    return 0

  logging.info("Requesting shutdown of %d VMs..." % len(hosts))

  # List EC2 instances with the "valid" hostnames
  inst = ec2_running_instances(valid_hostnames)
  if inst is None or len(inst) == 0:
    logging.warning("No list of instances can be retrieved from EC2")
    return 0

  # Resolve hostnames
  ips = []
  for h in hosts:
    try:
      ips.append( socket.gethostbyname(h) )
    except Exception:
      logging.warning("Cannot find IP for host to shut down %s: skipped" % h)

  # Now filter out only instances to shutdown
  inst_shutdown = []
  for ip in ips:
    for i in inst:
      found = False
      if i.private_ip_address == ip:
        inst_shutdown.append(i)
        found = True
        break
    if not found:
      logging.warning("Cannot find instance for IP to shut down %s: skipped" % ip)

  # Print number of all valid instances
  logging.debug("%d/%d total valid instances to shutdown found" % (len(inst_shutdown),len(inst)))

  # Shuffle the list
  random.shuffle(inst_shutdown)

  # Iterate and shutdown
  vms_to_shutdown = len(inst_shutdown)-cf['quota']['min_vms']  # honor quota!
  if vms_to_shutdown <= 0:
    logging.info("Not shutting down any VM to honor the minimum quota of %d" % cf['quota']['min_vms'])

  else:

    logging.info("Shutting down %d (out of %d) VMs due to minimum quota of %d" % \
      (vms_to_shutdown, len(inst_shutdown), cf['quota']['min_vms']))

    for i in inst_shutdown:

      ipv4 = i.private_ip_address
      success = False
      if int(cf['debug']['dry_run_shutdown_vms']) == 0:
        try:
          i.terminate()
          time.sleep(1)
          i.terminate()  # twice on purpose
          logging.debug("Shutdown via EC2 of %s succeeded" % ipv4)
          success = True
        except Exception, e:
          logging.error("Shutdown via EC2 failed for %s" % ipv4)
      else:
        # Dry run
        logging.debug("Not shutting down %s via EC2: dry run" % ipv4);
        success = True

      # Messages
      if success:
        n_succ+=1
        logging.info("VM shutdown requested OK. Requested: %d/%d | Success: %d | Failed: %d" % \
          (n_succ+n_fail, vms_to_shutdown, n_succ, n_fail))
      else:
        n_fail+=1
        logging.info("VM shutdown request fail. Requested: %d/%d | Success: %d | Failed: %d" % \
          (n_succ+n_fail, vms_to_shutdown, n_succ, n_fail))

      # Check min quota
      if n_succ == vms_to_shutdown:
        #logging.info("Maintainig quota of minimum %d VM(s) running", cf['quota']['min_vms'])
        break

  return n_succ


def poll_condor_queue(): 
  """Polls HTCondor for the number of inserted (i.e., "waiting") jobs.
  Returns the number of inserted jobs on success, or None on failure.
  """

  ret = robust_cmd(['condor_q', '-attributes', 'JobStatus', '-long'], max_attempts=5)
  if ret and 'output' in ret:
    return ret['output'].count("JobStatus = 1")

  return None


def poll_condor_status(current_workers_status):
  """Polls HTCondor for the list of workers with the number of running jobs
  per worker. Returns an array of hosts, each one of them has a parameter that
  indicates the number of running jobs."""

  ret = robust_cmd(['condor_status', '-xml', '-attributes', 'Activity,Machine'], max_attempts=2)
  if ret is None or 'output' not in ret:
    return None

  workers_status = {}

  try:

    xdoc = ET.fromstring(ret['output'])
    for xc in xdoc.findall("./c"):

      xtype = xc.find("./a[@n='MyType']/s")
      if xtype is None or xtype.text != 'Machine': continue

      xhost = xc.find("./a[@n='Machine']/s")
      if xhost is None: continue

      xactivity = xc.find("./a[@n='Activity']/s")
      if xactivity is None: continue

      host = xhost.text
      activity = xactivity.text

      # Here we have host and activity. Activity might be, for instance,
      # 'Idle' or 'Busy'. We only check for 'Idle'

      idle = (activity == 'Idle')

      if host in workers_status:
        # Update current entry ('jobs' key is there always)
        if not idle:
          workers_status[host]['jobs'] = workers_status[host]['jobs'] + 1
      else:
        # Entry not yet present
        workers_status[host] = {}
        if idle:
          workers_status[host]['jobs'] = 0
        else:
          workers_status[host]['jobs'] = 1

  except ET.ParseError, e:
    logging.error("Invalid XML!")
    return None

  # At this point we have the previous state and the current state saved
  # properly somewhere.
  # Browse the new list for all workers with zero jobs, check if they already
  # had zero jobs in the previous call, in case they're not, update the time

  check_time = time.time()

  for host,info in workers_status.iteritems():
    if host in current_workers_status and \
      current_workers_status[host]['jobs'] == info['jobs']:
      workers_status[host]['unchangedsince'] = current_workers_status[host]['unchangedsince']
    else:
      workers_status[host]['unchangedsince'] = check_time

  # Returns the new status
  return workers_status


def ec2_image(image_id):
  """Returns a boto Image object containing the image corresponding to a
  certain image AMI ID, or None if not found or problems occurred."""

  found = False
  img = None
  try:
    for img in ec2h.get_all_images():
      if img.id == cf['ec2']['image_id']:
        found = True
        break
  except Exception:
    logging.error("Cannot make EC2 connection to retrieve image info!")

  if not found:
    return None

  return img


def check_vms(st):
  """Checks status of Virtual Machines currently associated to HTCondor:
  starts new nodes to satisfy minimum quota requirements, and turn off idle
  nodes. Takes a list of worker statuses as input and returns an event
  dictionary scheduling self invocation."""

  logging.info("Checking HTCondor VMs...")
  check_time = time.time()
  new_workers_status = poll_condor_status( st['workers_status'] )

  if new_workers_status is not None:
    #logging.debug(new_workers_status)
    st['workers_status'] = new_workers_status
    new_workers_status = None

    hosts_shutdown = []
    for host,info in st['workers_status'].iteritems():
      if info['jobs'] != 0: continue
      if (check_time-info['unchangedsince']) > cf['elastiq']['idle_for_time_s']:
        logging.info("Host %s is idle for more than %ds: requesting shutdown" % \
          (host,cf['elastiq']['idle_for_time_s']))
        st['workers_status'][host]['unchangedsince'] = check_time  # reset timer
        hosts_shutdown.append(host)

    if len(hosts_shutdown) > 0:
      n_ok = ec2_scale_down(hosts_shutdown, valid_hostnames=st['workers_status'].keys())
      change_vms_allegedly_running(st, -n_ok)

    # Scale up to reach the minimum quota, if any
    min_vms = cf['quota']['min_vms']
    if min_vms >= 1:
      rvms = ec2_running_instances(st['workers_status'].keys())
      if rvms is None:
        logging.warning("Cannot get list of running instances for honoring min quota of %d" % min_vms)
      else:
        n_run = len(rvms)
        n_consider_run = n_run + st['vms_allegedly_running']
        logging.info("VMs: running=%d | allegedly running=%d | considering=%d" % \
          (n_run, st['vms_allegedly_running'], n_consider_run))
        n_vms = min_vms-n_consider_run
        if n_vms > 0:
          logging.info("Below minimum quota (%d VMs): requesting %d more VMs" % \
            (min_vms,n_vms))
          n_ok = ec2_scale_up(n_vms, valid_hostnames=st['workers_status'].keys())
          change_vms_allegedly_running(st, n_ok)

    # OK: schedule when configured
    sched_when = time.time() + cf['elastiq']['check_vms_every_s']

  else:
    # Not OK: reschedule ASAP
    sched_when = 0

  return {
    'action': 'check_vms',
    'when': sched_when
  }


def check_queue(st):
  """Checks HTCondor queue and take actions of starting VMs when
  appropriate. Returns an event dictionary scheduling self invocation."""

  logging.info("Checking HTCondor queue...")
  check_time = time.time()
  n_waiting_jobs = poll_condor_queue()

  if n_waiting_jobs is not None:

    # Correction factor
    corr = st['vms_allegedly_running'] * cf['elastiq']['n_jobs_per_vm']
    logging.info("Jobs: waiting=%d | allegedly running=%d | considering=%d" % \
      (n_waiting_jobs, corr, n_waiting_jobs-corr))
    n_waiting_jobs -= corr

    if n_waiting_jobs > cf['elastiq']['waiting_jobs_threshold']:
      if st['first_seen_above_threshold'] != -1:
        if (check_time-st['first_seen_above_threshold']) > cf['elastiq']['waiting_jobs_time_s']:
          # Above threshold time-wise and jobs-wise: do something
          logging.info("Waiting jobs: %d (above threshold of %d for more than %ds)" % \
            (n_waiting_jobs, cf['elastiq']['waiting_jobs_threshold'], cf['elastiq']['waiting_jobs_time_s']))
          n_ok = ec2_scale_up( round(n_waiting_jobs / float(cf['elastiq']['n_jobs_per_vm'])), valid_hostnames=st['workers_status'].keys() )
          change_vms_allegedly_running(st, n_ok)
          st['first_seen_above_threshold'] = -1
        else:
          # Above threshold but not for enough time
          logging.info("Waiting jobs: %d (still above threshold of %d for less than %ds)" % \
            (n_waiting_jobs, cf['elastiq']['waiting_jobs_threshold'], cf['elastiq']['waiting_jobs_time_s']))
      else:
        # First time seen above threshold
        logging.info("Waiting jobs: %d (first time above threshold of %d)" % \
          (n_waiting_jobs, cf['elastiq']['waiting_jobs_threshold']))
        st['first_seen_above_threshold'] = check_time
    else:
      # Not above threshold: reset
      logging.info("Waiting jobs: %d (below threshold of %d)" % \
        (n_waiting_jobs, cf['elastiq']['waiting_jobs_threshold']))
      st['first_seen_above_threshold'] = -1
  else:
    logging.error("Cannot get the number of waiting jobs this time, sorry")

  return {
    'action': 'check_queue',
    'when': time.time() + cf['elastiq']['check_queue_every_s']
  }


def change_vms_allegedly_running(st, delta):
  """Changes the number of VMs allegedly running by adding a delta."""
  st['vms_allegedly_running'] += delta
  if st['vms_allegedly_running'] < 0:
    st['vms_allegedly_running'] = 0
  logging.info("Number of allegedly running VMs changed to %d" % st['vms_allegedly_running'])

  # When incrementing, we should set an event to decrement of the same quantity
  if delta > 0:
    st['event_queue'].append({
      'action': 'change_vms_allegedly_running',
      'when': time.time() + cf['elastiq']['estimated_vm_deploy_time_s'],
      'params': [ -delta ]
    })


def main():

  global ec2h, ec2img, user_data

  # Configure logging
  lf = log()
  if lf is None:
    logging.warning("Cannot log to file, only console will be used!")
  else:
    logging.info("Logging to file %s and to console - log files are rotated" % lf)

  # Register signal
  signal.signal(signal.SIGINT, exit_main_loop)

  # Read configuration
  conf()

  # Initialize the EC2 handler
  ec2h = boto.connect_ec2_endpoint(
    cf['ec2']['api_url'],
    aws_access_key_id=cf['ec2']['aws_access_key_id'],
    aws_secret_access_key=cf['ec2']['aws_secret_access_key'])

  # Initialize EC2 image
  ec2img = ec2_image(cf['ec2']['image_id'])
  if ec2img is None:
    logging.error("Cannot find EC2 image \"%s\"", cf['ec2']['image_id'])
  else:
    logging.debug("EC2 image \"%s\" found" % cf['ec2']['image_id'])

  # Un-base64 user-data
  try:
    user_data = base64.b64decode(cf['ec2']['user_data_b64'])
  except TypeError:
    logging.error("Invalid base64 data for user-data!")
    user_data = ''

  # State variables
  internal_state = {
    'first_seen_above_threshold': -1,
    'workers_status': {},
    'vms_allegedly_running': 0,
    'event_queue': [
      {'action': 'check_vms',   'when': 0},
      {'action': 'check_queue', 'when': 0}
    ]
  }

  # Event-based main loop
  while do_main_loop == True:

    check_time = time.time()
    count = 0
    tot = len(internal_state['event_queue'])
    for evt in internal_state['event_queue'][:]:

      # Extra params?
      if 'params' in evt:
        p = evt['params']
      else:
        p = []

      # Debug message
      count+=1
      logging.debug("Event %d/%d in queue: action=%s when=%d (%d) params=%s" % \
        (count, tot, evt['action'], evt['when'], check_time-evt['when'], p))

      if evt['when'] <= check_time:
        r = None
        internal_state['event_queue'].remove(evt)

        # Action
        if evt['action'] == 'check_vms':
          r = check_vms(internal_state, *p)
        elif evt['action'] == 'check_queue':
          r = check_queue(internal_state, *p)
        elif evt['action'] == 'change_vms_allegedly_running':
          r = change_vms_allegedly_running(internal_state, *p)

        if r is not None:
          internal_state['event_queue'].append(r)

    logging.debug("Sleeping %d seconds" % cf['elastiq']['sleep_s']);
    time.sleep( cf['elastiq']['sleep_s'] )

  logging.info("Exiting gracefully!")


#
# Execute main() function when invoked as an executable
#

if __name__ == "__main__":
  main()
