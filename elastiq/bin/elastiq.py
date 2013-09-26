#!/usr/bin/python

# Monitors the HTCondor queue for new jobs and idle nodes, and take proper
# actions.

import time
import logging
import signal
import sys
import subprocess
import os


configuration = {
  'sleep_s': 15,
  'waiting_jobs_threshold': 10,
  'waiting_jobs_time_s': 100,
  'n_jobs_per_vm': 4,
  'cmd_start': '/var/lib/condor/vaf/elastiq/bin/vmstart.sh'
}
do_main_loop = True


def exit_main_loop(signal, frame):
  global do_main_loop
  logging.info('Exiting gracefully')
  do_main_loop = False


def robust_cmd(params, max_attempts=20, suppress_stderr=True):

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
  logging.info("Launching %d new vm(s)..." % nvms)

  for i in range(1, nvms+1):
    #ret = robust_cmd([ 'echo', str(i), configuration['cmd_start'] ], suppress_stderr=False, max_attempts=2)
    ret = robust_cmd([ configuration['cmd_start'] ], max_attempts=1)
    if ret and 'output' in ret:
      n_succ+=1
      logging.info("VM launched OK. Requested: %d/%d | Success: %d | Failed: %d" % (i, nvms, n_succ, n_fail))
    else:
      n_fail+=1
      logging.error("Launching VM failed. Requested: %d/%d | Success: %d | Failed: %d" % (i, nvms, n_succ, n_fail))

  return n_succ


def poll_condor_queue(): 
  """Polls HTCondor for the number of inserted (i.e., "waiting") jobs.
  Returns the number of inserted jobs on success, or -1 on failure.
  """

  ret = robust_cmd(['condor_q', '-attributes', 'JobStatus', '-long'])
  if ret and 'output' in ret:
    return ret['output'].count("JobStatus = 1")

  return -1


def poll_condor_status():
  pass


def main():

  # Log level
  logging.basicConfig(level=logging.DEBUG)

  # Register signal
  signal.signal(signal.SIGINT, exit_main_loop)

  # State variables
  first_time_above_threshold = -1

  # Main loop
  while do_main_loop == True:

    n_waiting_jobs = poll_condor_queue()
    check_time = time.time()

    if n_waiting_jobs != -1:
      if n_waiting_jobs > configuration['waiting_jobs_threshold']:
        if first_time_above_threshold != -1:
          if (check_time-first_time_above_threshold) > configuration['waiting_jobs_time_s']:
            # Above threshold time-wise and jobs-wise: do something
            logging.info("Waiting jobs: %d (above threshold of %d for more than %ds)" % \
              (n_waiting_jobs, configuration['waiting_jobs_threshold'], configuration['waiting_jobs_time_s']))
            scale_up( round(n_waiting_jobs / float(configuration['n_jobs_per_vm'])) )
            first_time_above_threshold = -1
          else:
            # Above threshold but not for enough time
            logging.info("Waiting jobs: %d (still above threshold of %d for less than %ds)" % \
              (n_waiting_jobs, configuration['waiting_jobs_threshold'], configuration['waiting_jobs_time_s']))
        else:
          # First time seen above threshold
          logging.info("Waiting jobs: %d (first time above threshold of %d)" % \
            (n_waiting_jobs, configuration['waiting_jobs_threshold']))
          first_time_above_threshold = check_time
      else:
        # Not above threshold: reset
        logging.info("Waiting jobs: %d (below threshold of %d)" % \
          (n_waiting_jobs, configuration['waiting_jobs_threshold']))
        first_time_above_threshold = -1
    else:
      logging.error("Cannot get the number of waiting jobs this time, sorry")

    #poll_condor_status()

    logging.info("Sleeping %d seconds" % configuration['sleep_s']);
    time.sleep( configuration['sleep_s'] )


#
# Execute main() function when invoked as an executable
#

if __name__ == "__main__":
  main()
