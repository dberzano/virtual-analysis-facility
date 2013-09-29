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
export OS_AUTH_URL=https://openstack.cern.ch:5000/v2.0
export OS_TENANT_ID=cf7bc2e1-e45a-43f4-805a-db8701309f9b
export OS_TENANT_NAME='Personal dberzano'
export OS_CACERT=/etc/pki/tls/certs/CERN-bundle.pem  # not supported =(
export OS_USERNAME=dberzano
export OS_PASSWORD=$(cat $HOME/.novapwd)  # watch out for security!

# Removes VM from the HTCondor queues
condor_off "$VmNameCondor" || exit 2

# Request immediate VM shutdown
T=`mktemp`
nova --insecure delete "$VmName" 2>&1 | tee "$T"
RV=${PIPESTATUS[0]}
if [ $RV != 0 ] ; then
  rm -f "$T"
  exit $RV
fi

# Return is zero, but might have failed all the same
grep -q '^No server with a name or ID of' "$T"
if [ $? == 0 ] ; then
  rm -f "$T"
  exit 3
fi

# All looks OK
rm -f "$T"
exit 0
