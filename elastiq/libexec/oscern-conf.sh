#
# oscern-conf.sh -- by Dario Berzano <dario.berzano@cern.ch>
#
# Credentials (well, without password!) for accessing the CERN OpenStack.
#

export OS_AUTH_URL=https://openstack.cern.ch:5000/v2.0
export OS_TENANT_ID=cf7bc2e1-e45a-43f4-805a-db8701309f9b
export OS_TENANT_NAME='Personal dberzano'
export OS_CACERT=/etc/pki/tls/certs/CERN-bundle.pem  # not supported =(
export OS_USERNAME=dberzano
export OS_PASSWORD=$(cat $HOME/.novapwd)  # watch out for security!
