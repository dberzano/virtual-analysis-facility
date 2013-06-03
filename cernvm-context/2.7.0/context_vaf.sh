#!/bin/bash

#
# amicontext.sh -- by Dario Berzano <dario.berzano@cern.ch>
#
# Contextualization script for a Virtual Analysis Facility based on CernVM 2.
# This script is to be cut & pasted to the script part in the CernVM Online web
# interface.
#
# Configuration variables need to be set externally. They are:
#
#   VafConf_AuthMethod
#   VafConf_NodeType
#   VafConf_NumPoolAccounts
#

#
# System configuration variables
#

# The log file
export LogFile='/amicontext.log'

# Directory containing Python amiconfig plugins
export AmiconfigPlugins="/usr/lib/python2.4/site-packages/amiconfig/plugins"

# File used to control test deployments
export DeployBin='/usr/bin/deploy'

# Use proper locale
export LANG=C

# Will be set by an appropriate function
export HostName
export Ip

# Colors
ColReset="\e[m"
ColRed="\e[31m"
ColGreen="\e[32m"
ColBlue="\e[34m"
ColMagenta="\e[35m"

#
# Functions
#

# Wraps a given command and shows the output only if an error occurs (signalled
# by a nonzero return value). Output is colored
function Exec() {

  local Fatal=0
  local Verbose=0

  # Spaces in arguments are supported with the following syntax ($@ + eval)
  local Args=$(getopt -o fv --long fatal,verbose -- "$@")
  eval set -- "$Args"

  # Parse for verbose and fatal switches
  while true; do
    case "$1" in
      -f) Fatal=1 ;;
      -v) Verbose=1 ;;
      --) break ;;
    esac
    shift
  done
  shift # skip '--'

  local Name="$1"
  local RetVal
  local Log=$(mktemp)

  shift  # From $1 on, we have the full intended command

  # Command is launched and wrapped to avoid undesired output (if not verbose)
  echo -e " ${ColMagenta}*${ColReset} ${Name}..."

  if [ $Verbose == 0 ]; then
    # Swallow output
    "$@" > $Log 2>&1
    RetVal=$?
  else
    # Verbose
    "$@"
    RetVal=$?
  fi

  if [ $RetVal == 0 ]; then
    # Success
    echo -e " ${ColMagenta}*${ColReset} ${Name}: ${ColGreen}ok${ColReset}"
  else
    # Failure
    echo -e " ${ColMagenta}*${ColReset} ${Name}: ${ColRed}fail${ColReset}"

    # Show log only if non-empty
    if [ -s $Log ]; then
      echo "=== Begin of log dump ==="
      cat $Log
      echo "=== End of log dump ==="
    fi

    # Fatal condition
    if [ $Fatal == 1 ]; then
      rm -f $Log
      exit 1
    fi
  fi

  # Cleanup
  rm -f $Log

  # Pass return value to caller
  return $RetVal
}

# Set current host and IP as seen from the outside
function GetPublicIpHost() {
  Ip=`curl -sL http://api.exip.org/?call=ip`
  local IpHost=`getent hosts $Ip`
  HostName=${IpHost##* }
  if [ "$HostName" == '' ] ; then
    HostName=`hostname -f`
    [ "$HostName" == '' ] && HostName="$Ip"
  fi
}

# LDAP configuration for ALICE users
function ConfigAliceUsers() {

  # Configure system to map users to ALICE LDAP users database
  cat > /etc/ldap.conf <<_EOF_
suffix "ou=People,o=alice,dc=cern,dc=ch"
uri ldap://aliendb06a.cern.ch:8389/
timelimit 30
bind_timelimit 30
pam_filter objectclass=posixAccount
pam_login_attribute uid
pam_member_attribute memberuid
pam_password exop
nss_base_passwd ou=People,o=alice,dc=cern,dc=ch

nss_override_attribute_value loginShell /bin/bash
nss_override_attribute_value userPassword x
nss_override_attribute_value gidNumber 100

nss_map_attribute uidNumber CCID
nss_reconnect_tries 4           # number of times to double the sleep time
nss_reconnect_sleeptime 1       # initial sleep value
nss_reconnect_maxsleeptime 16   # max sleep value to cap at
nss_reconnect_maxconntries 2    # how many tries before sleeping
_EOF_

  # Tell system to look for users in LDAP as well
  sed -i /etc/nsswitch.conf -e 's#^passwd:.*$#passwd: files ldap#g'

  # Home directories created at login
  mkdir -p /alice/cern.ch/user
  authconfig --enablemkhomedir --update

  # Purge cache of name service caching daemon
  service nscd reload
}

# Configure the system to use pool accounts
function ConfigPoolAccounts() {
  local I
  groupadd -g 50000 pool
  for ((I=1; I<=VafConf_NumPoolAccounts; I++)) ; do
    adduser `printf pool%03u $I` -s /bin/bash -u $((50000+I)) -g 50000
  done
  # Disable LDAP authentication
  sed -i /etc/nsswitch.conf -e 's#^passwd:.*$#passwd: files#g'
}

# Configures CernVM-FS for ALICE: currently no official ALICE repository exists
# so we should use a temporary one. Please note that the rest of CernVM-FS
# configuration is handled in a separate CernVM-Online plugin
function ConfigAliceCvmfs() {
  # Special cmvfs repository (temporary)
  cat > /etc/cvmfs/config.d/alice.cern.ch.local <<_EOF_
CVMFS_SERVER_URL=http://cernvm-devwebfs.cern.ch/cvmfs/alice.cern.ch
_EOF_
}

# Installs Conary common packages
function ConfigInstallConaryCommon() {
  conary erase vim-minimal
  conary install vim-enhanced vim-common
  true
}

# Installs Conary packages needed on master only
function ConfigInstallConaryMaster() {
  conary install httpd mod_ssl php php-ldap
  true
}

# Configures and installs sshcertauth from here[1]. The only parameter decides
# the authentication method (currently: alice_ldap or pool_users)
#
# [1] https://github.com/dberzano/sshcertauth
function ConfigSshcertauth() {

  #local Tag='v0.8.5'
  local AuthPlugin="$1"
  local Tag='master'
  local Url="https://github.com/dberzano/sshcertauth/archive/${Tag}.tar.gz"
  local Arch=`mktemp`
  local Dest='/var/www/html/auth'
  local AuthorizedKeysDir="/etc/ssh/authorized_keys_globus"
  local HttpsConf="/etc/httpd/conf.d/ssl.conf"
  local MapFile="/etc/sshcertauth-x509-map"
  #local HttpsAuthConf="/etc/httpd/conf.d/ssl-sshcertauth.conf"

  rm -rf "$Dest"
  mkdir -p "$Dest"
  curl -sLo "$Arch" "$Url" && \
    tar -C "$Dest" --strip-components=1 -xzf "$Arch"
  rm -f "$Arch"

  # Configuration for the sshcertauth username plugin
  cat > "$Dest/conf.php" <<_EOF_
<?php
\$sshPort = 22;
\$sshKeyDir = '$AuthorizedKeysDir';
\$maxValiditySecs = 3600;
\$pluginUser = '$AuthPlugin';
\$opensslBin = 'openssl';
\$suggestedCmd = 'vaf-enter <USER>@<HOST>';
\$mapFile = '$MapFile';
\$mapValiditySecs = 172800;
\$mapIdLow = 1;
\$mapIdHi = $VafConf_NumPoolAccounts;
\$mapUserFormat = 'pool%03u';
?>
_EOF_

  # Enable key expiration
  echo '*/5 * * * * root /var/www/html/auth/keys_keeper.sh expiry' > \
    /etc/cron.d/sshcertauth

  # Creates mapfile with proper permissions
  touch "$MapFile"
  chown apache "$MapFile"
  chmod 0600 "$MapFile"

  # Modify search path for authorized keys in ssh configuration
  local Sed="s|^.*PubkeyAuthentication.*\$|PubkeyAuthentication yes|g"
  Sed="${Sed} ; s|^.*AuthorizedKeysFile.*\$"
  Sed="${Sed}|AuthorizedKeysFile $AuthorizedKeysDir/%u|g"
  sed -i /etc/ssh/sshd_config -e "$Sed"
  service sshd reload

  # Symlink root SSH key (works even if key has not been set yet)
  #ln -nfs /root/.ssh/authorized_keys "$AuthorizedKeysDir"/root
  mkdir -p "$AuthorizedKeysDir"
  ln -nfs /root/.ssh/authorized_keys "$AuthorizedKeysDir"/root

  # Key manipulation program goes in sudoers. It is recontextualization-safe
  cat /etc/sudoers | grep -v keys_keeper.sh > /etc/sudoers.0
  cat /etc/sudoers.0 > /etc/sudoers
  rm -f /etc/sudoers.0
  echo "Defaults!$Dest/keys_keeper.sh !requiretty" >> /etc/sudoers
  echo "apache ALL=(ALL) NOPASSWD: $Dest/keys_keeper.sh" >> /etc/sudoers

  # Generate certificates on the fly [TODO]
  mkdir /etc/grid-security
  openssl req -new -newkey rsa:2048 -days 365 -nodes -x509 \
    -subj "/CN=$HostName" \
    -keyout /etc/grid-security/hostkey.pem \
    -out /etc/grid-security/hostcert.pem
  chmod 0400 /etc/grid-security/hostkey.pem
  chmod 0444 /etc/grid-security/hostcert.pem

  # New directives are in a separate file
  cat > "$HttpsConf" <<_EOF_
LoadModule ssl_module modules/mod_ssl.so
Listen 443
AddType application/x-x509-ca-cert .crt
AddType application/x-pkcs7-crl    .crl
SSLPassPhraseDialog  builtin
SSLSessionCache         shmcb:/var/cache/mod_ssl/scache(512000)
SSLSessionCacheTimeout  300
SSLMutex default
SSLRandomSeed startup file:/dev/urandom  256
SSLRandomSeed connect builtin
SSLCryptoDevice builtin
<VirtualHost _default_:443>
ErrorLog logs/ssl_error_log
TransferLog logs/ssl_access_log
LogLevel warn
SSLEngine on
SSLProtocol all -SSLv2
SSLCipherSuite ALL:!ADH:!EXPORT:!SSLv2:RC4+RSA:+HIGH:+MEDIUM:+LOW
<Files ~ "\.(cgi|shtml|phtml|php3?)$">
    SSLOptions +StdEnvVars
</Files>
<Directory "/var/www/cgi-bin">
    SSLOptions +StdEnvVars
</Directory>
SetEnvIf User-Agent ".*MSIE.*" \
         nokeepalive ssl-unclean-shutdown \
         downgrade-1.0 force-response-1.0
CustomLog logs/ssl_request_log \
          "%t %h %{SSL_PROTOCOL}x %{SSL_CIPHER}x \"%r\" %b"
### Customized for sshcertauth ###
SSLCertificateFile /etc/grid-security/hostcert.pem
SSLCertificateKeyFile /etc/grid-security/hostkey.pem
#SSLCACertificatePath /cvmfs/alice.cern.ch/x86_64-2.6-gnu-4.1.2/Packages/AliEn/v2-19/api/share/certificates
SSLCACertificatePath /cvmfs/atlas.cern.ch/repo/ATLASLocalRootBase/etc/grid-security/certificates
SSLVerifyDepth 10
<Directory /var/www/html/auth>
  SSLVerifyClient require
  SSLOptions +StdEnvVars +ExportCertData
  AllowOverride all
</Directory>
</VirtualHost>
_EOF_

  # Restart service
  service httpd restart

}

# List of actions to perform
function Actions() {

  local Master

  if [ "$VafConf_NodeType" == 'master' ] ; then
    Master=1
  else
    Master=0
  fi

  Exec 'Getting public IP and FQDN' GetPublicIpHost
  Exec 'What is my environment?' -v env

  case "$VafConf_AuthMethod" in
    alice_ldap)
      Exec 'Configuring LDAP for ALICE users' ConfigAliceUsers
    ;;
    pool_users)
      Exec 'Adding pool accounts' ConfigPoolAccounts
    ;;
  esac

  Exec 'Configuring CernVM-FS for ALICE software' ConfigAliceCvmfs
  Exec 'Installing Conary common packages' ConfigInstallConaryCommon

  if [ $Master == 1 ] ; then
    Exec 'Installing Conary packages for master' ConfigInstallConaryMaster
    Exec 'Configuring sshcertauth' ConfigSshcertauth "$VafConf_AuthMethod"
  fi
}

# The main function
function Main() {
  Actions 2>&1 | tee "$LogFile"
}

#
# Entry point
#

Main "$@"
