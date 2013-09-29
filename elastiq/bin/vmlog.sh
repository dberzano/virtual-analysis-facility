#!/bin/bash
cd `dirname "$0"`
export LANG=C
source os_creds.sh || exit 4
while true ; do
  ( date ; nova --insecure list ) | tee -a vmlog.txt
  sleep 60
done
