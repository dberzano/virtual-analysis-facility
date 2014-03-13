#!/bin/bash

export PackageSourceDir="$( cd `dirname "$0"`/.. ; pwd )"

cd "$PackageSourceDir"

# export PackageDestDir='/tmp/vaf-package'
# export PackageWorkDir='/tmp/vaf-work-dir'

# Destination directory of the package can be under the source directory
export PackageDestDir="$PackageSourceDir/misc/dist"

# Working directory must not be under source directory
export PackageWorkDir="/tmp/vaf-work-dir"

echo "Source: $PackageSourceDir"
echo "Destination: $PackageDestDir"

rm -rf "$PackageDestDir" "$PackageWorkDir"
mkdir -p "$PackageDestDir" "$PackageWorkDir"

fpm \
  -s dir \
  -t rpm \
  --version '0.9.0' \
  --name vaf-client \
  --package "$PackageDestDir" \
  --workdir "$PackageWorkDir" \
  --vendor "Dario Berzano <dario.berzano@cern.ch>" \
  --maintainer "Dario Berzano <dario.berzano@cern.ch>" \
  --description 'Client for the Virtual Analysis Facility' \
  --url 'https://github.com/dberzano/virtual-analysis-facility' \
  --prefix '/' \
  --exclude '.git' \
  --exclude '.gitignore' \
  --exclude 'README.*' \
  --exclude 'misc' \
  --exclude 'tmp' \
  .

echo '=== List of the packages directory ==='
ls -l "$PackageDestDir"
echo '=== RPM contents and information ==='
rpm -qlip "$PackageDestDir"/*.rpm
