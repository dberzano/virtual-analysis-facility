#!/bin/bash

#
# cloud-init-force.sh -- by Dario Berzano <dario.berzano@cern.ch>
#
# Executes the cloud-init modules in the order defined for the current
# runlevel.
#

rm -rf /var/lib/cloud/instance*
RL=$(runlevel|awk '{print $2}')
for CloudScript in /etc/rc${RL}.d/*cloud* ; do
  "$CloudScript" start
done
