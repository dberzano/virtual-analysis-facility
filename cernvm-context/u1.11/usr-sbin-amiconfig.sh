#!/bin/sh

AMICONFIG="/usr/sbin/amiconfig"
AMILOCK="/var/lock/subsys/amiconfig"
AMISETUP="/etc/sysconfig/amiconfig"

#LOGGER="echo :: "
#PIPELOGGER="cat"
LOGGER="logger -t amiconfig.sh"
PIPELOGGER="logger -t amiconfig.sh"

# Retrieval of user-data
RetrieveUserData() {

  if [ "x$AMICONFIG_CONTEXT_URL" != "x" ] ; then
    $LOGGER "Won't check for new URLs: found: $AMICONFIG_CONTEXT_URL"
  else
    RetrieveUserDataEC2 || RetrieveUserDataCloudStack
    if [ $? == 1 ] ; then
      $LOGGER "No user-data can be retrieved from any location"
      return 1
    fi
  fi

  # Uncompress if necessary and if the file is local, and restrict perms
  if [ "${AMICONFIG_CONTEXT_URL:0:5}" == 'file:' ] ; then
    USER_DATA="${AMICONFIG_CONTEXT_URL:5}/user-data"
    if [ "$(file -bi $USER_DATA)" == "application/x-gzip" ] ; then
      $LOGGER "user-data is compressed: uncompressing it"
      mv "$USER_DATA" "$USER_DATA".gz
      gunzip "$USER_DATA".gz
      if [ -f "$USER_DATA" ] ; then
        $LOGGER "user-data uncompressed"
      fi
    fi
    chmod 0600 "$USER_DATA"
  fi

  return 0

}

# Trying to contact the EC2 metadata server. Returns 0 on success, 1 on
# failure. If data has been found, it can be found as local file
RetrieveUserDataEC2() {

  # EC2 metadata server versions
  EC2_API_VERSIONS="2007-12-15"
  SERVER="169.254.169.254"

  # Local checks
  for VERSION in $EC2_API_VERSIONS ; do

    LOCAL_USER_DATA="/var/lib/amiconfig/$VERSION/"

    if [ -f $LOCAL_USER_DATA/user-data ] ; then
      # Found user-data locally. Update configuration
      $LOGGER "EC2: user-data found locally, updating configuration: $LOCAL_USER_DATA"
      echo "AMICONFIG_CONTEXT_URL=file:$LOCAL_USER_DATA" > $AMISETUP
      export AMICONFIG_CONTEXT_URL="file:$LOCAL_USER_DATA"
      return 0
    fi

  done

  $LOGGER "EC2: no local user-data found: trying metadata server instead"

  # Remote check. Can we open a TCP connection to the server?
  nc -w 1 $SERVER 80 > /dev/null 2>&1
  if [ $? == 0 ] ; then

    $LOGGER "EC2: metadata server $SERVER seems to respond"

    # Check all possible remote versions
    for VERSION in $EC2_API_VERSIONS ; do

      LOCAL_USER_DATA="/var/lib/amiconfig/$VERSION/"
      REMOTE_USER_DATA="http://$SERVER/$VERSION/"
      DATA=$(wget -t1 -T10 -q -O - $REMOTE_USER_DATA/user-data)
      if [ $? == 0 ] ; then
        $LOGGER "EC2: user-data downloaded from $REMOTE_USER_DATA and written locally"
        mkdir -p "$LOCAL_USER_DATA"
        echo "$DATA" > $LOCAL_USER_DATA/user-data
        echo "AMICONFIG_CONTEXT_URL=file:$LOCAL_USER_DATA" > $AMISETUP
        export AMICONFIG_CONTEXT_URL="file:$LOCAL_USER_DATA"
        return 0
      fi

    done

  fi

  # Error condition
  $LOGGER "EC2: can't find any user-data"
  return 1

}

# Trying to retrieve user data from CloudStack
RetrieveUserDataCloudStack() {

  if [ ! -d /var/lib/dhclient ] ; then
    $LOGGER "CloudStack: can't find dhclient leases"
    return 1
  fi

  # Find the leases in every interface
  LEASES=$(ls -1 /var/lib/dhclient/*.leases)

  # Check if we are running a metadata server on the dhcp-identifier
  # specified on every interface
  for LEASE in $LEASES ; do
    SERVER=$(cat $LEASE | grep dhcp-server-identifier)
    if [ ! -z "$SERVER" ]; then
      SERVER=$(echo "$SERVER" | awk '{print $3}' | tr -d ';' | tr -d '\n' | tail -n1 )
      if [ ! -z "$SERVER" ]; then

        # Attempt a connection
        nc -w 1 $SERVER 80 > /dev/null 2>&1
        if [ $? == 0 ] ; then
          $LOGGER "CloudStack: metadata server $SERVER seems to respond"

          # Try to perform an HTTP get request
          LOCAL_USER_DATA="/var/lib/amiconfig/latest/"
          REMOTE_USER_DATA="http://$SERVER/latest/"
          DATA=$(wget -t1 -T10 -q -O - $REMOTE_USER_DATA/user-data)
          if [ $? == 0 ] && [! -z "$DATA" ] ; then
            # Successful, update amiconfig
            $LOGGER "CloudStack: user-data found"
            echo "AMICONFIG_CONTEXT_URL=$REMOTE_USER_DATA" > $AMISETUP
            mkdir -p $LOCAL_USER_DATA
            echo "$DATA" > $LOCAL_USER_DATA/user-data
            return 0
          fi
        else
          $LOGGER "CloudStack: metadata server $SERVER did not respond"
        fi
      fi
    fi
  done

  # Error condition
  $LOGGER "CloudStack: can't find any user-data"
  return 1
}

# Runs the initial shell script contained in user-data
RunUserDataScript() {

  CURL="curl --retry 1 --silent --show-error --fail --connect-timeout 10"

  # Retrieve the instance user-data and run it if it looks like a script
  USER_DATA=$(mktemp /tmp/amiconfig-user-data-XXXXX)
  $LOGGER "Attempting to run script from $AMICONFIG_CONTEXT_URL"

  $CURL -s $AMICONFIG_CONTEXT_URL/user-data | grep -v -e "^ *\$" > $USER_DATA 2>&1
  if [ "$(file -bi $USER_DATA)" = "application/x-gzip" ]; then
    $LOGGER "Uncompressing gzipped user-data"
    mv $USER_DATA $USER_DATA.gz
    gunzip $USER_DATA.gz
  fi

  if [ ! -s "$USER_DATA" ] ; then
    $LOGGER "No user-data available"
    rm -f "$USER_DATA"
    return 1
  fi

  # Check if it looks like a script
  if [ $(head -1 "$USER_DATA" | grep -c -e '^#!') == 0 ] ; then
    $LOGGER "user-data does not seem to contain a script"
    rm -f "$USER_DATA"
    return 0
  fi

  case $1 in
    before)
      sed -n '/#!.*sh.*before/,/^exit/p' $USER_DATA | sed  -e 's/\(#!.*\) \(.*\)/\1/' > "$USER_DATA".sh
      if [ ! -s $"USER_DATA".sh ] ; then
        awk '/#!.*sh/,/^$/ {print}' "$USER_DATA" > "$USER_DATA".sh
        rm -f "$USER_DATA"
      fi
    ;;

    after)
      sed -n '/#!.*sh.*after/,/^exit/p' "$USER_DATA" | sed  -e 's/\(#!.*\) \(.*\)/\1/' > "$USER_DATA".sh
      rm -f "$USER_DATA"
    ;;

    *)
      return 1
    ;;
  esac

  $LOGGER "Running user-data [$1]"
  chmod +x "$USER_DATA".sh
  "$USER_DATA".sh 2>&1 | $PIPELOGGER
  $LOGGER "user-data script exit code: $?"
  rm -f "$USER_DATA".sh

  return 0
}

# Main function
Main() {

  # Assert amiconfig executable
  [ -f $AMICONFIG ] && [ -x $AMICONFIG ] || exit 1

  [ -f $AMISETUP ] && source $AMISETUP
  export AMICONFIG_CONTEXT_URL
  RetrieveUserData

  case $1 in
    user)
      RunUserDataScript before
      $AMICONFIG 2>&1 #| $PIPELOGGER
      RunUserDataScript after
    ;;
    hepix)
      $AMICONFIG -f hepix
    ;;
  esac
}

#
# Entry point
#

Main "$@"
