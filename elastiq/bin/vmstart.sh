#!/bin/bash

#
# vmstart.sh -- by Dario Berzano <dario.berzano@cern.ch>
#
# Starts a VAF VM corresponding to a Slave on the CERN OpenStack.
#

VmFlavour='m1.medium'
VmImage='ami-00000013'
VmKeypair='CernVM-VAF'

# Current dir
cd `dirname "$0"`

# Source EC2 env
source ec2rc.sh
if [ $? != 0 ] ; then
  echo 'Cannot load EC2 environment' >&2
  exit 1
fi

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

[hostname]

[ucernvm-begin]
cernvm_branch=cernvm-devel.cern.ch
resize_rootfs=true
[ucernvm-end]
_EoF_

# Substitutions
sed -e 's#{{VAF_MASTER_IP}}#'$IpLocal'#g' -i "$VmContext"
cat $VmContext

# Launch
euca-run-instances -t "$VmFlavour" -k "$VmKeypair" -f "$VmContext" "$VmImage"
R=$?
rm -f $VmContext
if [ $R != 0 ] ; then
  echo 'Cannot launch Virtual Machine =(' >&2
  exit 3
fi
