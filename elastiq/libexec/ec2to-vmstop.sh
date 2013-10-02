#!/bin/bash

#
# vmstop.sh -- by Dario Berzano <dario.berzano@cern.ch>
#
# Stops a VAF VM given a FQDN using the EC2 API in Torino .
#

# Current dir (resolve symlinks -- needed for reading conf)
Prog=`readlink -e "$0"`
cd `dirname "$Prog"`

# Stop a single VM
VmNameCondor="$1"
VmName="${VmNameCondor%%.*}"
if [ "$VmName" == '' ] ; then
  echo 'Virtual Machine FQDN not specified =(' >&2
  exit 1
fi

# EC2 configuration
source ec2to-conf.sh || exit 4

# Removes VM from the HTCondor queues
#condor_off "$VmNameCondor"

# Gets the IP address from the VM name
HostsLine=$(getent hosts "$VmName")
if [[ "$HostsLine" =~ (([0-9]{1,3}\.){3}([0-9]{1,3})) ]] ; then
  VmIp="${BASH_REMATCH[1]}"
else
  echo 'Cannot determine IP address of VM =(' >&2
  exit 2
fi

# Gets the instance ID from the IP address
InstanceLine=$(euca-describe-instances | grep '^INSTANCE' | grep "$VmIp" | head -n1)
if [[ "$InstanceLine" =~ (i-[0-9]{8}) ]] ; then
  VmInstanceId="${BASH_REMATCH[1]}"
else
  echo 'Cannot determine EC2 instance ID =(' >&2
  exit 3
fi

# Shuts down the VM, twice (works around uCernVM and OpenNebula issues)
euca-terminate-instances $VmInstanceId
sleep 2
euca-terminate-instances $VmInstanceId

# Returns last exit code
exit $?
