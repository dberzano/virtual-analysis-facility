#!/bin/bash

#
# context_vaf.sh -- by Dario Berzano <dario.berzano@cern.ch>
#
# Contextualization script for a Virtual Analysis Facility based on uCernVM.
#
# Configuration variables need to be set externally. Variables are:
#
#   VafConf_AuthMethod
#   VafConf_NodeType
#   VafConf_NumPoolAccounts
#

#
# System configuration variables
#

# The log file
export LogFile='/context_vaf.log'

# Directory containing Python amiconfig plugins
export AmiconfigPlugins="/usr/lib/python/site-packages/amiconfig/plugins"

# Use a neutral locale
export LANG=C

# Will be set by an appropriate function
export HostName
export PrivIp
export PubIp

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

# Gets IPs and hostname
function ConfigIpHost() {
  # External service for Public IP
  PubIp=`curl -sL http://api.exip.org/?call=ip`
  local PubIpHost=`getent hosts $PubIp`
  HostName=${PubIpHost##* }
  if [ "$HostName" == '' ] ; then
    HostName=`hostname -f`
    [ "$HostName" == '' ] && HostName="$PubIp"
  fi
  # Private IP, from eth0 interface
  PrivIp=`/sbin/ifconfig eth0 | grep 'inet addr:' | cut -d: -f2 | cut -d' ' -f1`
}

# Shiny new SSSD LDAP configuration for ALICE users. Many thanks to this[1]
# page for the configuration and this[2] one for uid/gid mappings!
#
# Equivalent ldapsearch command:
#
#   ldapsearch -H ldap://aliendb06a.cern.ch:8389 \
#     -b ou=People,o=alice,dc=cern,dc=ch -x 'uid=dberzano'
#
# [1] http://www.couyon.net/1/post/2012/04/enabling-ldap-usergroup-support-and-
#     authentication-in-centos-6.html
# [2] http://mailman.studiosysadmins.com/pipermail/studiosysadmins-discuss/
#     2012-August/018772.html
function ConfigAliceUsers() {

  local SssdConf=/etc/sssd/sssd.conf
  local NscdConf=/etc/nscd.conf

  # Install sssd package
  yum install -y sssd || return 1

  # Create proper "alice" group (can't override GID for the moment)
  groupadd -g 1395 alice > /dev/null 2>&1

  # Enable lots of things: notably, sssd and automatic homedir creation
  authconfig --enablesssd --enablesssdauth \
    --enablelocauthorize --enablemkhomedir --update || return 1

  # Configuration for SSSD
  cat > "$SssdConf" <<_EOF_
[sssd]
config_file_version = 2
services = nss, pam
domains = default

[nss]
filter_users = root,ldap,named,avahi,haldaemon,dbus,radiusd,news,nscd
override_shell = /bin/bash
override_homedir = /home/%u
#override_gid = 99

[pam]

[domain/default]
ldap_tls_reqcert = never
auth_provider = ldap
ldap_schema = rfc2307bis
ldap_search_base = ou=People,o=alice,dc=cern,dc=ch
ldap_group_member = uniquemember
id_provider = ldap
ldap_id_use_start_tls = False
ldap_uri = ldap://aliendb06a.cern.ch:8389/
cache_credentials = True
ldap_tls_cacertdir = /etc/openldap/cacerts
entry_cache_timeout = 600
ldap_network_timeout = 3
ldap_access_filter = (objectclass=posixaccount)
ldap_user_uid_number = CCID
_EOF_

  # Correct permissions: elsewhere sssd won't start
  chmod 0600 "$SssdConf"

  # Tell system to look for users in LDAP as well. Don't use ldap, but sss!
  sed -i /etc/nsswitch.conf -e 's#^passwd:.*$#passwd: files sss#g'

  # Disable nscd cache for passwd and group: sssd has its own
  egrep -v 'enable-cache\s+(group|passwd)\s+no' "$NscdConf" > "$NscdConf".0
  cat "$NscdConf".0 | \
    sed -e 's!\(\s*[a-z-]\+\s\+\(passwd\|group\)\s\+\)!#\1!g' > "$NscdConf"
  rm -f "$NscdConf".0
  echo 'enable-cache passwd no' >> "$NscdConf"
  echo 'enable-cache group no' >> "$NscdConf"

  # Restart the sssd and nscd service
  service sssd restart || return 1
  service nscd restart

  # Clean caches
  service nscd reload

  # Everything OK up to this point
  return 0
}

# Configure the system to use pool accounts
function ConfigPoolAccounts() {
  local I
  groupadd -g 50000 pool
  for ((I=1; I<=VafConf_NumPoolAccounts; I++)) ; do
    adduser `printf pool%03u $I` -s /bin/bash -u $((50000+I)) -g 50000
  done

  # Disable LDAP authentication, stop SSSD
  sed -i /etc/nsswitch.conf -e 's#^passwd:.*$#passwd: files#g'
  service sssd stop || true
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
  #local Url="https://dl.dropbox.com/u/19379008/CernVM-VAF/repo/sshcertauth-${Tag}.tar.gz"
  local Arch=`mktemp`
  local Dest='/var/www/html/auth'
  local AuthorizedKeysDir="/etc/ssh/authorized_keys_globus"
  local HttpsConf="/etc/httpd/conf.d/ssl.conf"
  local MapFile="/etc/sshcertauth-x509-map"
  #local HttpsAuthConf="/etc/httpd/conf.d/ssl-sshcertauth.conf"

  # Install php-ldap package
  yum install -y php-ldap || return 1

  rm -rf "$Dest"
  mkdir -p "$Dest"
  curl -sLo "$Arch" "$Url" && \
    tar -C "$Dest" --strip-components=1 -xzf "$Arch" || return 1
  rm -f "$Arch"

  # Configuration for the sshcertauth username plugin
  cat > "$Dest/conf.php" <<_EOF_
<?php
\$sshPort = 22;
\$sshKeyDir = '$AuthorizedKeysDir';
\$maxValiditySecs = 43200;
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

  # Create authorized keys directory
  mkdir -p "$AuthorizedKeysDir"
  chmod 0755 "$AuthorizedKeysDir"

  # Make chmod resilient: cloud-init tends to change permissons of the
  # AuthorizedKeysDir, so run chmod *after* it to restore *our* perms
  local ChmodLine="chmod 0755 \"$AuthorizedKeysDir\""
  local RcLocal='/etc/rc.d/rc.local'
  cat "$RcLocal" | grep -v "$ChmodLine" > "$RcLocal".0
  echo "$ChmodLine" >> "$RcLocal".0
  mv "$RcLocal".0 "$RcLocal"
  chmod 0755 "$RcLocal"  # make it executable

  # Symlink root SSH key (works even if key has not yet been set)
  ln -nfs /root/.ssh/authorized_keys "$AuthorizedKeysDir"/root

  # Key manipulation program goes in sudoers. It is recontextualization-safe
  cat /etc/sudoers | grep -v keys_keeper.sh > /etc/sudoers.0
  cat /etc/sudoers.0 > /etc/sudoers
  rm -f /etc/sudoers.0
  echo "Defaults!$Dest/keys_keeper.sh !requiretty" >> /etc/sudoers
  echo "apache ALL=(ALL) NOPASSWD: $Dest/keys_keeper.sh" >> /etc/sudoers

  # Generate certificates on the fly. Not the best option: there should be a
  # way of providing a certificate yourself
  mkdir /etc/grid-security
  openssl req -new -newkey rsa:2048 -days 365 -nodes -x509 \
    -subj "/CN=$PrivIp" \
    -keyout /etc/grid-security/hostkey.pem \
    -out /etc/grid-security/hostcert.pem
  chmod 0400 /etc/grid-security/hostkey.pem
  chmod 0444 /etc/grid-security/hostcert.pem

  # New directives are in a separate file
  cat > "$HttpsConf" <<_EOF_
LoadModule ssl_module modules/mod_ssl.so
Listen 443
AddType application/x-x509-ca-cert .crt
AddType application/x-pkcs7-crl .crl
SSLPassPhraseDialog builtin
SSLSessionCache shmcb:/var/cache/mod_ssl/scache(512000)
SSLSessionCacheTimeout 300
SSLMutex default
SSLRandomSeed startup file:/dev/urandom 256
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

# Hotfix for hostname and condor plugins of amiconfig
function ConfigAmiconfigPlugins {
  #local Plugins='hostname condor'
  local Plugins='condor'
  local SrcBase='https://dl.dropbox.com/u/19379008/CernVM-VAF/u1.11/amiconfig-plugins-%s.py'
  local DstBase='/usr/lib/python/site-packages/amiconfig/plugins/%s.py'
  local Src Dest P

  for P in $Plugins ; do
    Src=`printf "$SrcBase" "$P"`
    Dst=`printf "$DstBase" "$P"`
    curl -fsL "$Src" > "$Dst" || return 1
    chmod 0644 "$Dest"
  done

  return 0
}

# Other Condor fixes
function ConfigCondorHotfix() {
  local Dst='/etc/condor/config.d/51hotfixes'
  cat > "$Dst" <<"_EoF_"
UPDATE_COLLECTOR_WITH_TCP = True
COLLECTOR_SOCKET_CACHE_SIZE = 1000
_EoF_
  touch /var/lock/subsys/condor
}

# Bash prompt with IP address
function ConfigBashPrompt() {
  local Dst='/etc/profile.d/ps1.sh'
  cat > "$Dst" <<_EoF_
# Get IP address from eth0
IpLocal=\$(/sbin/ifconfig eth0 | grep 'inet addr:')
if [[ "\$IpLocal" =~ inet\ addr:([0-9.]+) ]] ; then
  IpLocal="\${BASH_REMATCH[1]}"
fi
IpLocal="\$IpLocal($VafConf_NodeType)"

# Prompt
export PS1='\u@'\$IpLocal' [\W] \\$> '
unset SSH_ASKPASS
_EoF_
}

# Mount NFS (only at CERN)
function ConfigNfs() {
  local Server='128.142.242.158'
  local Fstab='/etc/fstab'
  local Mnt='/sw'

  # Check if server exists
  ping -c 1 -w 2 $Server > /dev/null 2>&1 || return 0

  grep -v ":$Mnt" "$Fstab" > "$Fstab".0
  echo "$Server:$Mnt $Mnt nfs nfsvers=3 0 0" >> "$Fstab".0
  mv "$Fstab".0 "$Fstab"
  mkdir -p "$Mnt"
  mount "$Mnt"

  [ -d "$Mnt/vaf" ] && return 0
  return 1
}

# Elastiq on the master
function ConfigElastiq() {
  local Git='https://github.com/dberzano/virtual-analysis-facility.git'
  local GitAuth='https://dberzano@github.com/dberzano/virtual-analysis-facility.git'
  local UnprivUser='condor'
  local UnprivPrefix='/var/lib/condor/vaf'
  local BashVaf='/etc/profile.d/vaf.sh'

  if [ ! -d "$UnprivPrefix" ] ; then

    mkdir -p "$UnprivPrefix"
    git clone "$Git" "$UnprivPrefix" || return 1
    ( cd "$UnprivPrefix" && git checkout boto-ec2 && git remote set-url origin "$GitAuth" ) || return 1
    chown -R $UnprivUser "$UnprivPrefix" || return 1
    cat > "$BashVaf" <<_EoF_
export PATH="${UnprivPrefix}/elastiq/bin:\$PATH"
_EoF_

  fi

  # Prepare configuration file
  local Cfg="${UnprivPrefix}/elastiq/etc/elastiq.conf"
  echo '# Automatically generated by contextualization' > "$Cfg"
  echo '# Do not modify: it will be overwritten' >> "$Cfg"
  echo "# You can override it by creating ~${UnprivUser}/.elastiq.conf" >> "$Cfg"

  # Write configuration file
  local Sections='elastiq ec2 quota'
  local S V EL L
  for S in $Sections ; do
    echo "[$S]" >> "$Cfg"
    S=VafConf_Elastiq_${S}
    L=$(( ${#S}+1 ))
    env | grep ^$S | while read EL ; do
      EL=${EL:$L}
      Key=$( echo "$EL" | cut -d= -f1 )
      Val=$( echo "$EL" | cut -d= -f2 )
      echo "$Key = $Val" >> "$Cfg"
    done
    echo '' >> "$Cfg"
  done

  # Default parts
  cat >> "$Cfg" <<_EoF_
[elastiq]
check_queue_every_s = 60
check_vms_every_s = 600
waiting_jobs_threshold = 10
waiting_jobs_time_s = 100
idle_for_time_s = 1800

_EoF_

  # Some system-wide files in place
  local D
  for D in "${UnprivPrefix}"/elastiq/var "${UnprivPrefix}"/elastiq/var/log ; do
    mkdir -p "$D"
    chown $UnprivUser "$D"
  done

  ln -nfs "${UnprivPrefix}"/elastiq/bin/elastiq /etc/init.d/elastiq || return 1
  ln -nfs "${UnprivPrefix}"/elastiq/etc/elastiq.default.example /etc/sysconfig/elastiq || return 1
  chkconfig --add elastiq || return 1
  chkconfig elastiq on

  # Create user-data for slave
  echo -e -n "[ec2]\nuser_data_b64 = " >> "$Cfg"
  cat "$AMICONFIG_LOCAL_USER_DATA" | \
    sed -e 's|\(\[condor\]\)|\1\ncondor_master='$PrivIp'|g' | \
    base64 -w0 >> "$Cfg"
  echo -e -n "\n\n" >> "$Cfg"

  # (Re)start it
  service elastiq restart
  return $?
}

# Configure yum proxy
function ConfigYumProxy() {
  local Conf='/etc/yum.conf'
  local Url='http://cernvm.cern.ch/config'

  #cp "$Conf" "$Conf".0

  local Proxy=$(curl "$Url" | grep "^CVMFS_HTTP_PROXY")
  Proxy=$(echo "$Proxy" | cut -d= -f2- | cut -d\; -f1 | cut -d\| -f1)
  [ "$Proxy" == '' ] && return 1

  cat "$Conf" | grep -v '^proxy=' | \
    sed -e 's#\(\[main\]\)#\1\nproxy='"$Proxy"'#' > "$Conf".0
  mv "$Conf".0 "$Conf"
}

# Install boto
function ConfigBoto() {(

  #
  # Python 2.7 environment
  #

  # GCC
  source /cvmfs/sft.cern.ch/lcg/external/gcc/4.7.2/x86_64-slc6-gcc47-opt/setup.sh ''  # empty arg needed!

  # Python 2.7
  export PythonPrefix=/cvmfs/sft.cern.ch/lcg/external/Python/2.7.3/x86_64-slc6-gcc47-opt
  export PATH="$PythonPrefix/bin:$PATH"
  export LD_LIBRARY_PATH="$PythonPrefix/lib:$LD_LIBRARY_PATH"

  # Boto
  export PyBotoPrefix='/var/lib/condor/boto'  # <-- will install boto there
  export PATH="$PyBotoPrefix/bin:$PATH"
  export LD_LIBRARY_PATH="$PyBotoPrefix/lib:$LD_LIBRARY_PATH"
  export PYTHONPATH="$PyBotoPrefix/lib/python2.7/site-packages:$PYTHONPATH"

  #
  # Install boto
  #

  mkdir -p "$PyBotoPrefix/lib/python2.7/site-packages"
  cd "$PyBotoPrefix"
  mkdir src
  cd src
  git clone https://github.com/boto/boto.git .
  python setup.py install --prefix $(cd ..;pwd)

  #
  # Merging Grid CA certificates in boto
  #

  cat /cvmfs/atlas.cern.ch/repo/ATLASLocalRootBase/etc/grid-security/certificates/*.pem \
    >> "$PyBotoPrefix"/lib/python2.7/site-packages/boto/cacerts/cacerts.txt

)}

# List of actions to perform
function Actions() {

  local Master

  if [ "$VafConf_NodeType" == 'master' ] ; then
    Master=1
  else
    Master=0
  fi

  Exec 'Getting public IP and FQDN' ConfigIpHost
  Exec 'What is my environment?' -v env

  Exec 'Replacing some amiconfig plugins with temporary fixes' ConfigAmiconfigPlugins
  Exec 'Another temporary fix for Condor' ConfigCondorHotfix
  Exec 'Config yum proxy' ConfigYumProxy
  Exec 'Replacing Bash prompt' ConfigBashPrompt
  Exec 'Mounting shared NFS software area' ConfigNfs

  case "$VafConf_AuthMethod" in
    alice_ldap)
      Exec 'Configuring LDAP for ALICE users' ConfigAliceUsers
    ;;
    pool_users)
      Exec 'Adding pool accounts' ConfigPoolAccounts
    ;;
  esac

  if [ $Master == 1 ] ; then
    Exec 'Configuring sshcertauth' ConfigSshcertauth "$VafConf_AuthMethod"
    Exec 'Installing boto' -v ConfigBoto
    Exec 'Configuring elastiq' -v ConfigElastiq
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
