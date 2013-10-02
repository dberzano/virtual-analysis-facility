#!/bin/bash

#
# vmstart.sh -- by Dario Berzano <dario.berzano@cern.ch>
#
# Starts a VAF VM corresponding to a Slave via the EC2 API in Torino 
#

VmFlavor='m1.large'
VmImage='ami-00000332'
VmKeypair='CernVM-VAF'

# Current dir (resolve symlinks -- needed for reading conf)
Prog=`readlink -e "$0"`
cd `dirname "$Prog"`

# EC2 configuration
source ec2to-conf.sh || exit 4

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

# Launch. With EC2, name cannot be chosen
euca-run-instances \
  -t "$VmFlavor" \
  -k "$VmKeypair" \
  -f "$VmContext" \
  "$VmImage"
R=$?
rm -f $VmContext
if [ $R != 0 ] ; then
  echo 'Cannot launch Virtual Machine =(' >&2
  exit 3
fi
