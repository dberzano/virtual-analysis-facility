#!/bin/bash

#
# vaf-enter-env.sh -- by Dario Berzano <dario.berzano@cern.ch>
#
# Enters a Bash shell with PoD + Experiment Software environment set.
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
    --remote "$VafPodUser@$VafPodHost:/opt/pod" \
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
