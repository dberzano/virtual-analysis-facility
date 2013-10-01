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

# Get user-data from the same machine
VmUserDataPath=$(find /var/lib/amiconfig -name user-data -print -quit 2> /dev/null)
if [ "$VmUserDataPath" == 0 ] ; then
  echo 'Cannot find user-data!' >&2
  exit 5
fi

cat $VmUserDataPath

exit 0

# Prepare context
VmContext=`mktemp`
cat > "$VmContext" <<"_EoF_"
#!/bin/sh
. /etc/cernvm/site.conf
export VafConf_NodeType=slave
export VafConf_AuthMethod=alice_ldap
export VafConf_NumPoolAccounts='50'
CVM_ContextUrl='https://dl.dropbox.com/u/19379008/CernVM-VAF/u1.11/context_vaf.sh'
CVM_ContextDest='/tmp/context_vaf.sh'
curl -L $CVM_ContextUrl -o $CVM_ContextDest && source $CVM_ContextDest
rm -f $CVM_ContextDest


exit
[amiconfig]
plugins=cernvm condor hostname

[cernvm]
organisations=None
repositories=
shell=/bin/bash
config_url=http://cernvm.cern.ch/config
edition=Batch

[condor]
condor_secret=yabbayabba
condor_master={{VAF_MASTER_IP}}
condor_group=condor
condor_user=condor
lowport=41000
highport=42000
use_ips=true
uid_domain=*

[hostname]

[ucernvm-begin]
cvmfs_branch=cernvm-devel.cern.ch
resize_rootfs=true
[ucernvm-end]
_EoF_

# Substitutions
sed -e 's#{{VAF_MASTER_IP}}#'$IpLocal'#g' -i "$VmContext"

# Form name for new VM using a random string
VmName=vaf-`echo $IpLocal|tr . -`
VmName="$VmName-`od -vAn -N4 -tx4 < /dev/urandom|tr -d ' '`"

# Launch
#euca-run-instances -t "$VmFlavor" -k "$VmKeypair" -f "$VmContext" "$VmImage"
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
