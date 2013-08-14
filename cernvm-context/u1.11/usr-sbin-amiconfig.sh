#!/bin/sh

AMICONFIG="/usr/sbin/amiconfig"
AMILOCK="/var/lock/subsys/amiconfig"
AMISETUP="/etc/sysconfig/amiconfig"

if [ "$AMILOGECHO" != '' ] && [ "$AMILOGECHO" != '0' ] ; then
  LOGGER="echo :: "
  PIPELOGGER="cat"
else
  LOGGER="logger -t amiconfig.sh"
  PIPELOGGER="logger -t amiconfig.sh"
fi

# Retrieves user-data and uncompresses it. Returns 0 on success (in such case,
# environment and files are in place), 1 on failure. If user-data is compressed,
# uncompresses it
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

  # At this point, user-data is available locally. Let's uncompress it if needed
  if [ "$(file -bi $AMICONFIG_LOCAL_USER_DATA)" == "application/x-gzip" ] ; then
    $LOGGER "user-data is compressed: uncompressing it"
    cat "$AMICONFIG_LOCAL_USER_DATA" | gunzip > "$AMICONFIG_LOCAL_USER_DATA".0
    if [ -s "$AMICONFIG_LOCAL_USER_DATA".0 ] ; then
      $LOGGER "user-data uncompressed"
      mv "$AMICONFIG_LOCAL_USER_DATA".0 "$AMICONFIG_LOCAL_USER_DATA"
      chmod 0600 "$AMICONFIG_LOCAL_USER_DATA"
    else
      # Failure in uncompressing is non-fatal
      $LOGGER "Failure uncompressing user-data: leaving original user-data there"
    fi
  fi

  return 0

}

# Trying to contact the EC2 metadata server. Returns 0 on success, 1 on
# failure. The user-data is saved locally
RetrieveUserDataEC2() {

  # EC2 metadata server versions
  EC2_API_VERSIONS="2007-12-15"
  SERVER="169.254.169.254"
  DEFAULT_URL="http://$SERVER/$(echo $EC2_API_VERSIONS|awk '{ print 1 }')/"

  # Local checks
  for VERSION in $EC2_API_VERSIONS ; do

    LOCAL_USER_DATA="/var/lib/amiconfig/$VERSION/"

    if [ -f $LOCAL_USER_DATA/user-data ] ; then
      # Found user-data locally. Update configuration

      # We should just rely on the local user data without actually updating the configuration
      $LOGGER "EC2: user-data found locally, won't download again: $LOCAL_USER_DATA"
      export AMICONFIG_LOCAL_USER_DATA="${LOCAL_USER_DATA}user-data"

      if [ -f "$LOCAL_USER_DATA"/meta-data ] ; then
        # It seems that metadata exists there. We should point amiconfig to the
        # local directory in such case
        $LOGGER "EC2: user-data found locally, updating configuration: $LOCAL_USER_DATA"
        echo "AMICONFIG_CONTEXT_URL=file:$LOCAL_USER_DATA" > $AMISETUP
        export AMICONFIG_CONTEXT_URL="file:$LOCAL_USER_DATA"
      else
        # Metadata not found locally. Set the URL currently in file. If not there, warn the user
        [ -e $AMISETUP ] && source $AMISETUP
        export AMICONFIG_CONTEXT_URL
        if [ "$AMICONFIG_CONTEXT_URL" == '' ] ; then
          $LOGGER "EC2: no metadata found locally and no context URL is set: will use the default: $DEFAULT_URL"
          echo "AMICONFIG_CONTEXT_URL=$DEFAULT_URL" > $AMISETUP
          export AMICONFIG_CONTEXT_URL="$DEFAULT_URL"
        fi
      fi

      # Proper permissions
      chmod 0600 "$AMICONFIG_LOCAL_USER_DATA"

      # If we exit here, everything is consistent
      return 0
    fi

  done

  # If we are here, no user-data has been found locally. Look for HTTP metadata
  $LOGGER "EC2: no local user-data found: trying metadata HTTP server $SERVER instead"

  # Remote check. Can we open a TCP connection to the server?
  nc -w 1 $SERVER 80 > /dev/null 2>&1
  if [ $? == 0 ] ; then

    $LOGGER "EC2: metadata server $SERVER seems to respond"

    # Check all possible remote versions
    for VERSION in $EC2_API_VERSIONS ; do

      LOCAL_USER_DATA="/var/lib/amiconfig/$VERSION/"
      REMOTE_USER_DATA="http://$SERVER/$VERSION/"
      DATA=$(wget -t2 -T10 -q -O - $REMOTE_USER_DATA/user-data)
      if [ $? == 0 ] ; then
        $LOGGER "EC2: user-data downloaded from $REMOTE_USER_DATA and written locally"

        # Write file there for script
        mkdir -p "$LOCAL_USER_DATA"
        echo "$DATA" > "$LOCAL_USER_DATA"/user-data
        chmod 0600 "$LOCAL_USER_DATA"/user-data

        # Export local location
        export AMICONFIG_LOCAL_USER_DATA="${LOCAL_USER_DATA}user-data"

        # Pass remote URL there for metadata (used by amiconfig)
        echo "AMICONFIG_CONTEXT_URL=$REMOTE_USER_DATA" > $AMISETUP
        export AMICONFIG_CONTEXT_URL="$REMOTE_USER_DATA"

        # Exit consistently (user-data written, env exported, settings saved)
        return 0
      fi

    done

  fi

  # Error condition (no env exported, no file written)
  $LOGGER "EC2: can't find any user-data"
  return 1

}

# Trying to retrieve user data from CloudStack. The user-data is saved locally.
# Returns 0 on success, 1 on failure
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
          DATA=$(wget -t2 -T10 -q -O - $REMOTE_USER_DATA/user-data)
          if [ $? == 0 ] && [! -z "$DATA" ] ; then

            # Successful, update amiconfig
            $LOGGER "CloudStack: user-data found"

            # File is dumped there for running the script
            mkdir -p "$LOCAL_USER_DATA"
            echo "$DATA" > $LOCAL_USER_DATA/user-data
            chmod 0600 "$LOCAL_USER_DATA"/user-data

            # Export local location
            export AMICONFIG_LOCAL_USER_DATA="${LOCAL_USER_DATA}user-data"

            # Pass remote URL there for metadata (used by amiconfig)
            echo "AMICONFIG_CONTEXT_URL=$REMOTE_USER_DATA" > $AMISETUP
            export AMICONFIG_CONTEXT_URL="$REMOTE_USER_DATA"

            # Exit consistently (user-data ok, env exported, settings saved)
            return 0
          fi
        else
          $LOGGER "CloudStack: metadata server $SERVER did not respond"
        fi
      fi
    fi
  done

  # Error condition (no file written, no env exported)
  $LOGGER "CloudStack: can't find any user-data"
  return 1
}

# Runs the initial shell script contained in user-data, if found. Returns 0 on
# success, 1 on failure. Return value of script is printed in log
RunUserDataScript() {

  # No download invloved here. Use local version
  $LOGGER "Using local copy of $AMICONFIG_CONTEXT_URL: found in $AMICONFIG_LOCAL_USER_DATA"

  TMP_USER_DATA=$(mktemp /tmp/amiconfig-user-data-XXXXX)

  # Strip white lines
  grep -v -e "^ *\$" "$AMICONFIG_LOCAL_USER_DATA" > $TMP_USER_DATA 2>&1

  # Empty file?
  if [ ! -s "$TMP_USER_DATA" ] ; then
    $LOGGER "No user-data available"
    rm -f "$TMP_USER_DATA"
    return 1
  fi

  # Check if it looks like a script
  if [ $(head -1 "$TMP_USER_DATA" | grep -c -e '^#!') == 0 ] ; then
    $LOGGER "user-data does not seem to contain a script, exiting gracefully"
    rm -f "$TMP_USER_DATA"
    return 0
  fi

  case $1 in
    before)
      sed -n '/#!.*sh.*before/,/^exit/p' $TMP_USER_DATA | sed  -e 's/\(#!.*\) \(.*\)/\1/' > "$USER_DATA".sh
      if [ ! -s $"USER_DATA".sh ] ; then
        awk '/#!.*sh/,/^$/ {print}' "$TMP_USER_DATA" > "$TMP_USER_DATA".sh
        rm -f "$TMP_USER_DATA"
      fi
    ;;

    after)
      sed -n '/#!.*sh.*after/,/^exit/p' "$TMP_USER_DATA" | sed  -e 's/\(#!.*\) \(.*\)/\1/' > "$TMP_USER_DATA".sh
      rm -f "$TMP_USER_DATA"
    ;;

    *)
      # Unknown option
      return 1
    ;;
  esac

  $LOGGER "Running user-data [$1]"
  chmod +x "$TMP_USER_DATA".sh
  "$TMP_USER_DATA".sh 2>&1 | $PIPELOGGER
  $LOGGER "user-data script exit code: $?"
  rm -f "$TMP_USER_DATA".sh

  return 0
}

# The main function
Main() {

  # Assert amiconfig executable
  [ -f $AMICONFIG ] && [ -x $AMICONFIG ] || exit 1

  # Ugly workaround: install netcat if not there
  which conary > /dev/null 2>&1
  if [ $? == 0 ] ; then
    which nc > /dev/null 2>&1 || conary install nc > /dev/null 2>&1
  fi

  # Retrieve user-data. After calling this function, in case of success, we
  # have a consistent environment:
  #  - user-data, uncompressed, locally available at AMICONFIG_LOCAL_USER_DATA
  #  - remote path exported in AMICONFIG_CONTEXT_URL and saved in $AMISETUP
  #    (this is used by amiconfig, expecially to retrieve meta-data)
  RetrieveUserData
  if [ $? != 0 ] ; then
    $LOGGER "Can't retrieve any user data: aborting!"
    exit 1
  fi

  # Some debug
  $LOGGER "After retrieving user-data:"
  $LOGGER " * AMICONFIG_CONTEXT_URL=$AMICONFIG_CONTEXT_URL"
  $LOGGER " * AMICONFIG_LOCAL_USER_DATA=$AMICONFIG_LOCAL_USER_DATA"

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
