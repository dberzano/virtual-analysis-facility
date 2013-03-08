#!/bin/bash

#
# vaf-enter-env.sh -- by Dario Berzano <dario.berzano@cern.ch>
#
# Enters a Bash shell with PoD + Experiment Software environment set.
#
# Both local (client) and remote experiment environment is set through a set of
# scripts. This is the order of execution:
#
# LOCAL ENVIRONMENT
#
#   ~/.vaf/common.before
#   ~/.vaf/local.before
#   ~/.vaf/local.conf
#   <PoD environment from $VafConf_LocalPodLocation/PoD_env.sh>
#   ~/.vaf/common.after
#   ~/.vaf/local.after
#
# PAYLOAD PREPARATION
#   The script is executed (not sourced!) locally (with VAF environment set) and
#   its stdout output will be prepended to the remote environment
#   ~/.vaf/payload.sh
#
# REMOTE ENVIRONMENT
#
#   <output of ~/.vaf/payload.sh>
#   ~/.vaf/common.before
#   ~/.vaf/remote.before
#   ~/.vaf/remote.conf
#   ~/.vaf/common.after
#   ~/.vaf/remote.after
#
# Scripts are executed only if they exist.
#

#
# Variables
#

export Debug=0
export ErrLocalCf=2

#
# Functions
#

# Wrapper to printout function
function _vaf_p() {
  echo -e "\033[1m$1\033[m"
}

# Wrapper to pod-remote with proper environment
function vafctl() {
  local RetVal

  # BUG: --ssh-opt is ignored by current PoD (v3.12)!
  pod-remote \
    --remote "$VafUserHost:$VafConf_RemotePodLocation" \
    --env-local "$VafPodRemoteEnv" \
    "$@"

  return $RetVal
}

# Wrapper to pod-submit executed within pod-remote
function vafreq() {
  local Num="$1"
  let Num+=0
  if [ $Num -le 0 ] ; then
    _vaf_p 'Usage: vafreq <n_workers>'
  else
    # pod-prep-worker is there to ensure that job payloads are up to date
    vafctl --command "pod-prep-worker ; pod-submit -r condor -n $Num"
  fi
}


# Loads (sources) the specified configuration file. Usage:
#   LoadConf [-f] <source_cf>
#
# -f rises an error also when file is not found. Returns 0 on success, nonzero
# on error
function LoadConf() {
  HandleConf "$@" '' load
  return $?
}

# Appends a configuration file to another. Usage:
#   AppendConf [-f] <source_cf> <dest_cf>
#
# -f rises an error also when file is not found. Returns 0 on success, nonzero
# on error
function AppendConf() {
  HandleConf "$@" append
}

# Handles (appends/loads) a configuration file by raising errors if requested
# and printing out debug information. Used by AppendConf and LoadConf
function HandleConf() {

  local MustExist Cf Out Action

  if [ "$1" == '-f' ] ; then
    MustExist=1
    shift
  fi

  local Cf="$1"
  local Out="$2"
  local Action="$3"

  [ "$Debug" == 1 ] && _vaf_p "Looking for configuration file: $Cf"
  if [ -e "$Cf" ] ; then

    case "$Action" in
      load)
        [ "$Debug" == 1 ] && _vaf_p " * Loading"
        source "$Cf" || Err=1
      ;;
      append)
        [ "$Debug" == 1 ] && _vaf_p " * Adding"
        echo -e "\n### $Cf ###\n" >> "$Out"
        cat "$Cf" >> "$Out"
        echo '' >> "$Out"
      ;;
    esac

  else
    [ "$Debug" == 1 ] && _vaf_p " * Not found"
    [ "$MustExist" == 1 ] && Err=1
  fi

  if [ "$Err" == 1 ] ; then
    _vaf_p "Error loading $Cf"
    return 1
  fi

  return 0
}

# The main function
function Main() {

  # Parse user@host string
  local ConnStr="$1"
  local Port=${ConnStr##*:}
  local VafUserHost=${ConnStr%:*}
  [ "$Port" == "$VafUserHost" ] && Port=''

  # Set prompt for environment shell
  PS1="pod://$VafUserHost"
  [ "$Port" != '' ] && PS1="$PS1:$Port"
  PS1="$PS1 [\W] > "

  local ConfPrefix="$HOME/.vaf"
  local Cf

  #
  # Local environment
  #

  # Before PoD
  local ConfLocalPre=( 'common.before' 'local.before' 'local.conf' )
  for Cf in ${ConfLocalPre[@]} ; do
    LoadConf "$ConfPrefix/$Cf" || exit $ErrLocalCf
  done

  # Load PoD environment
  LoadConf -f "$VafConf_LocalPodLocation"/PoD_env.sh || exit $ErrLocalCf

  # After PoD
  local ConfLocalPost=( 'common.after' 'local.after' )
  for Cf in ${ConfLocalPre[@]} ; do
    LoadConf "$ConfPrefix/$Cf" || exit $ErrLocalCf
  done

  # Prepare script for remote environment, including payload
  local VafPodRemoteEnv="/tmp/vaf_pod_remote_env_u$UID"
  echo -n '' > "$VafPodRemoteEnv"

  # Executing payload preparation script (must be executable)
  local Payload="$ConfPrefix/payload"
  [ "$Debug" == 1 ] && _vaf_p "Looking for payload executable: $Payload"
  if [ -x "$Payload" ] ; then
    echo -e "### payload ###\n" >> "$VafPodRemoteEnv"
    "$Payload" >> "$VafPodRemoteEnv"
  fi

  # Append other configuration scripts (will be sourced remotely and not
  # interpreted locally)
  local ConfRemote=(
    'common.before'
    'remote.before'
    'remote.conf'
    'common.after'
    'remote.after'
  )
  for Cf in ${ConfRemote[@]} ; do
    AppendConf "$ConfPrefix/$Cf" "$VafPodRemoteEnv"
  done

  # Enter shell
  _vaf_p "Entering VAF environment: $VafUserHost"
  _vaf_p 'Remember: you are still in a shell on your local computer!'
  export VafPodRemoteEnv VafUserHost
  export -f vafctl vafreq _vaf_p
  exec env PS1="$PS1" bash --norc -i

}

Main "$@"

exit 0

#
# Debug only
#

# List of configuration files: first one found will be considered
declare -a VafConf
VafConfList=(
  "$PWD/vaf-env.cf"
  "$HOME/.vaf-env.cf"
)

# Wrapper to printout function
function vaf_pe() {
  echo -e "\033[1m$1\033[m"
}

# Wrapper to pod-remote with proper environment
function vaf_pod_remote() {
  local RetVal
  local VafTmpEnv=`mktemp -t vaf-pod`
  echo "$VafRemoteEnv" > "$VafTmpEnv"

  # --ssh-opt are ignored by current PoD (v3.12)!
  pod-remote \
    --remote "$VafPodUser@$VafPodHost:$Vaf_PodLocation" \
    --env-local "$VafTmpEnv" \
    "$@"
  RetVal=$?

  rm -f "$VafTmpEnv"
  return $RetVal
}

# Wrapper to ease submission of nodes through pod-remote and pod-submit
function vaf_pod_submit() {
  local Num="$1"
  let Num+=0
  if [ $Num -le 0 ] ; then
    vaf_pe 'Usage: vaf-pod-submit <n_workers>'
  else
    # pod-prep-worker is to ensure that job payloads are up to date
    vaf_pod_remote --command "pod-prep-worker ; pod-submit -r condor -n $Num"
  fi
}

# Read first configuration file found
VafConfFound=0
for VafConf in ${VafConfList[@]} ; do
  if [ -e "$VafConf" ] ; then
    source "$VafConf"  # do not check for retval!
    VafConfFound=1
    break
  fi
done

if [ $VafConfFound == 0 ] ; then
  vaf_pe 'Cannot find configuration file. Paths tried:'
  for VafConf in ${VafConfList[@]} ; do
    vaf_pe " * $VafConf"
  done
  exit 2
fi

# Load PoD environment
source "$VafPodPath"/PoD_env.sh
if [ $? != 0 ] ; then
  vaf_pe 'Error setting PoD environment!'
  exit 3
fi

# Execute commands to set up local environment
eval "$VafLocalEnv"

# Proper substitutions in remote environment
VafRemoteEnv=$(
echo "$VafRemoteEnv" | perl -n /dev/fd/3 3<<"PerlScript"
  $/ = '';
  while (<>) {
    while ($_ =~ /@([A-Za-z0-9_]+)@/) {
      open(PIPE, "/bin/echo -n \"\$$1\"|");
      $pipe = <PIPE>;
      close(PIPE);
      if (length($pipe) == 0) {
        $pipe = "\@$1: not found\@";
      }
      $_ = "${^PREMATCH}${pipe}${^POSTMATCH}";
    }
    print "$_";
  }
PerlScript
)

#
# Entry point
#

VafConnStr="$1"
VafPort=${VafConnStr##*:}
VafUserHost=${VafConnStr%:*}
if [ "$VafPort" == "$VafUserHost" ] ; then
  VafPort=''
fi

# Prompt
PS1="$VafUserHost"
[ "$VafPort" != '' ] && PS1="$PS1:$VafPort"
PS1="$PS1 [\W] >"

# Enters shell
export -f vaf_pod_remote vaf_pod_submit vaf_pe
export VafRemoteEnv VafPodHost VafPodUser
exec env PS1="$PS1" bash --norc -i
