#!/usr/bin/python

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


configuration = {}
configuration['elastiq'] = {

  # Main loop
  'sleep_s': 15,

  # Conditions to start new VMs
  'waiting_jobs_threshold': 10,
  'waiting_jobs_time_s': 100,
  'n_jobs_per_vm': 4,
  'cmd_start': 'vmstart.sh',

  # Conditions to stop idle VMs
  'idle_for_time_s': 3600,
  'cmd_stop': 'vmstop.sh'

}
configuration['ec2'] = {

  # Configuration to access EC2 API
  'api_url': 'https://dummy.ec2.server/ec2/',
  'aws_access_key_id': 'my_username',
  'aws_secret_access_key': 'my_password',

}

do_main_loop = True


def conf():

  global configuration

  cf = SafeConfigParser()

  # etc dir at the same level of the bin dir containing this script
  close_etc_path = os.path.realpath( os.path.realpath(os.path.dirname(__file__)) + "/../etc" )

  # The last file has precedence over the first file
  config_files = [
    "/etc/elastiq.conf",
    "%s/elastiq.conf" % close_etc_path,
    os.path.expanduser("~/.elastiq.conf")
  ]
  cf.read(config_files)

  # Print config files
  for f in config_files:
    logging.info("Configuration file: %s" % f)

  for sec_name,sec_content in configuration.iteritems():

    for key,val in sec_content.iteritems():

      try:
        new_val = cf.get(sec_name, key)  # --> [sec_name]
        try:
          new_val = float(new_val)
        except ValueError:
          pass
        configuration[sec_name][key] = new_val
        logging.info("Configuration: %s.%s = %s (from file)", sec_name, key, str(new_val))
      except Exception, e:
        logging.info("Configuration: %s.%s = %s (default)", sec_name, key, str(val))


def log():
  """Configures logging. Outputs log to the console and, optionally, to a file.
  File name is automatically selected. Returns the file name, or None if it
  cannot write to a file."""

  format="%(asctime)s %(levelname)s %(message)s"
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

  return filename


def exit_main_loop(signal, frame):
  global do_main_loop
  logging.info('Exiting gracefully')
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


def scale_up(nvms):
  """Invokes an external command to launch more Virtual Machines. The number of
  VMs is specified as parameter.
  Returns the number of launched VMs.
  """

  nvms = int(nvms)
  n_succ = 0
  n_fail = 0
  logging.info("Launching %d new VMs..." % nvms)

  for i in range(1, nvms+1):
    #ret = robust_cmd([ 'echo', str(i), configuration['cmd_start'] ], suppress_stderr=False, max_attempts=2)
    ret = robust_cmd([ configuration['elastiq']['cmd_start'] ], max_attempts=1)
    if ret and 'output' in ret:
      n_succ+=1
      logging.info("VM launched OK. Requested: %d/%d | Success: %d | Failed: %d" % (i, nvms, n_succ, n_fail))
    else:
      n_fail+=1
      logging.info("VM launch fail. Requested: %d/%d | Success: %d | Failed: %d" % (i, nvms, n_succ, n_fail))

  return n_succ


def scale_down(hosts):
  """Invokes the shutdown command for each host on the given list. External
  command should take care of everything. Returns the number of hosts that
  were asked to shut down correctly.
  """

  n_succ = 0
  n_fail = 0
  logging.info("Requesting shutdown of %d VMs..." % len(hosts))

  for h in hosts:
    ret = robust_cmd([ configuration['elastiq']['cmd_stop'], h ], max_attempts=3)
    if ret and 'exitcode' in ret and ret['exitcode'] == 0:
      n_succ+=1
      logging.info("VM shutdown requested OK. Requested: %d/%d | Success: %d | Failed: %d" % (n_succ+n_fail, len(hosts), n_succ, n_fail))
    else:
      n_fail+=1
      logging.info("VM shutdown request fail. Requested: %d/%d | Success: %d | Failed: %d" % (n_succ+n_fail, len(hosts), n_succ, n_fail))

  return n_succ


def poll_condor_queue(): 
  """Polls HTCondor for the number of inserted (i.e., "waiting") jobs.
  Returns the number of inserted jobs on success, or -1 on failure.
  """

  ret = robust_cmd(['condor_q', '-attributes', 'JobStatus', '-long'], max_attempts=10)
  if ret and 'output' in ret:
    return ret['output'].count("JobStatus = 1")

  return -1


def poll_condor_status(current_workers_status):
  """Polls HTCondor for the list of workers with the number of running jobs
  per worker. Returns [...]"""

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


def main():

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

  # State variables
  first_time_above_threshold = -1
  workers_status = {}

  # Main loop
  while do_main_loop == True:

    #
    # Check queue and start new VMs
    #

    n_waiting_jobs = poll_condor_queue()
    check_time = time.time()

    if n_waiting_jobs != -1:
      if n_waiting_jobs > configuration['elastiq']['waiting_jobs_threshold']:
        if first_time_above_threshold != -1:
          if (check_time-first_time_above_threshold) > configuration['elastiq']['waiting_jobs_time_s']:
            # Above threshold time-wise and jobs-wise: do something
            logging.info("Waiting jobs: %d (above threshold of %d for more than %ds)" % \
              (n_waiting_jobs, configuration['elastiq']['waiting_jobs_threshold'], configuration['elastiq']['waiting_jobs_time_s']))
            scale_up( round(n_waiting_jobs / float(configuration['elastiq']['n_jobs_per_vm'])) )
            first_time_above_threshold = -1
          else:
            # Above threshold but not for enough time
            logging.info("Waiting jobs: %d (still above threshold of %d for less than %ds)" % \
              (n_waiting_jobs, configuration['elastiq']['waiting_jobs_threshold'], configuration['elastiq']['waiting_jobs_time_s']))
        else:
          # First time seen above threshold
          logging.info("Waiting jobs: %d (first time above threshold of %d)" % \
            (n_waiting_jobs, configuration['elastiq']['waiting_jobs_threshold']))
          first_time_above_threshold = check_time
      else:
        # Not above threshold: reset
        logging.info("Waiting jobs: %d (below threshold of %d)" % \
          (n_waiting_jobs, configuration['elastiq']['waiting_jobs_threshold']))
        first_time_above_threshold = -1
    else:
      logging.error("Cannot get the number of waiting jobs this time, sorry")

    #
    # Check current status and shut down idle VMs
    #

    new_workers_status = poll_condor_status(workers_status)
    if new_workers_status is not None:
      #print new_workers_status
      workers_status = new_workers_status
      new_workers_status = None

      hosts_shutdown = []
      for host,info in workers_status.iteritems():
        if info['jobs'] != 0: continue
        if (check_time-info['unchangedsince']) > configuration['elastiq']['idle_for_time_s']:
          logging.info("Host %s is idle for more than %ds: requesting shutdown" % \
            (host,configuration['elastiq']['idle_for_time_s']))
          workers_status[host]['unchangedsince'] = check_time  # reset timer
          hosts_shutdown.append(host)

      if len(hosts_shutdown) > 0:
        scale_down(hosts_shutdown)

    # End of loop
    logging.info("Sleeping %d seconds" % configuration['elastiq']['sleep_s']);
    time.sleep( configuration['elastiq']['sleep_s'] )


#
# Execute main() function when invoked as an executable
#

if __name__ == "__main__":
  main()
