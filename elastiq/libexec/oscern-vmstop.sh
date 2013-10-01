#!/bin/bash

#
# vmstop.sh -- by Dario Berzano <dario.berzano@cern.ch>
#
# Stops a VAF VM given a FQDN on the CERN OpenStack.
#

# Current dir
cd `dirname "$0"`

# Stop a single VM
VmNameCondor="$1"
VmName="${VmNameCondor%%.*}"
if [ "$VmName" == '' ] ; then
  echo 'Virtual Machine FQDN not specified =(' >&2
  exit 1
fi

# OpenStack environment for nova
source oscern-conf.sh || exit 4

# Removes VM from the HTCondor queues
condor_off "$VmNameCondor"

# Request immediate VM shutdown
T=`mktemp`
nova --insecure delete "$VmName" 2>&1 | tee "$T"
RV=${PIPESTATUS[0]}
if [ $RV != 0 ] ; then
  # Shutdown failed: attempt to re-insert VM in queues!
  condor_on "$VmNameCondor"
  rm -f "$T"
  exit $RV
fi

# Return is zero, but might have failed all the same
grep -q '^No server with a name or ID of' "$T"
if [ $? == 0 ] ; then
  condor_on "$VmNameCondor"
  rm -f "$T"
  exit 3
fi

# All looks OK
rm -f "$T"
exit 0
