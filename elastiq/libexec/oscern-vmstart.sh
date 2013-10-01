#!/bin/bash

#
# vmstart.sh -- by Dario Berzano <dario.berzano@cern.ch>
#
# Starts a VAF VM corresponding to a Slave on the CERN OpenStack.
#

VmFlavor='m1.large'
VmImage='ucvm-1.11-hdd'
VmKeypair='CernVM-VAF'

# Current dir
cd `dirname "$0"`

# OpenStack environment for nova
source oscern-conf.sh || exit 4

# Fetch IP address
IpLocal=`/sbin/ifconfig eth0 | grep 'inet addr:'`
if [[ "$IpLocal" =~ inet\ addr:([0-9.]+) ]] ; then
  IpLocal="${BASH_REMATCH[1]}"
else
  echo 'Cannot determine IP address' >&2
  exit 2
fi

# Prepare context
VmContext=`mktemp`
cp user-data-slave.txt "$VmContext" || exit 5

# Substitutions
sed -e 's#{{VAF_MASTER_IP}}#'$IpLocal'#g' -i "$VmContext"

# Form name for new VM using a random string
VmName=vaf-`echo $IpLocal|tr . -`
VmName="$VmName-`od -vAn -N4 -tx4 < /dev/urandom|tr -d ' '`"

# Launch
nova --insecure boot \
  --image "$VmImage" \
  --flavor "$VmFlavor" \
  --key-name "$VmKeypair" \
  --user-data "$VmContext" \
  "$VmName"
R=$?
rm -f $VmContext
if [ $R != 0 ] ; then
  echo 'Cannot launch Virtual Machine =(' >&2
  exit 3
fi
