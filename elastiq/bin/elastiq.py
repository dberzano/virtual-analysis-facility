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
  'sleep_s': 1,
  'waiting_jobs_threshold': 10,
  'waiting_jobs_time_s': 30,
  'n_jobs_per_vm': 4,
}
do_main_loop = True


def exit_main_loop(signal, frame):
  global do_main_loop
  logging.info('Exiting gracefully')
  do_main_loop = False


def robust_cmd(params, max_attempts=20):

  shell = isinstance(params, basestring)
  sp = None

  for n_attempts in range(0, max_attempts):

    try:
      with open(os.devnull) as dev_null:
        sp = subprocess.Popen(params, stdout=subprocess.PIPE, stderr=dev_null, shell=shell)
      sp.wait()
    except OSError:
      logging.error("Command cannot be executed: wait %ds before retrying..." % n_attempts)
      time.sleep(n_attempts)
      continue

    if sp.returncode != 0:
      logging.debug("Command returned %d: wait %ds before retrying..." % (sp.returncode, n_attempts))
      time.sleep(n_attempts)
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
            logging.info("WE ARE ABOVE THRESHOLD --> DO SOMETHING AND RESET!")
            first_time_above_threshold = -1
          else:
            logging.info("STAYING ABOVE THRESHOLD BUT NOT ENOUGH TIME...")
        else:
          logging.info("FIRST TIME SEEN ABOVE THRESHOLD")
          first_time_above_threshold = check_time
      else:
        logging.info("NOT ABOVE THRESHOLD")
        first_time_above_threshold = -1


    # check_time = time.time()
    # if n_waiting_jobs != -1:
    #   if check_time 

    poll_condor_status()

    logging.info("Sleeping %d seconds" % configuration['sleep_s']);
    time.sleep( configuration['sleep_s'] )


#
# Execute main() function when invoked as an executable
#

if __name__ == "__main__":
  main()
