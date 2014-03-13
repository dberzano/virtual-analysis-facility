#!/bin/bash

export PackageSourceDir="$( cd `dirname "$0"`/.. ; pwd )"

cd "$PackageSourceDir"

# export PackageDestDir='/tmp/vaf-package'
# export PackageWorkDir='/tmp/vaf-work-dir'

# Destination directory of the package can be under the source directory
export PackageDestDir="$PackageSourceDir/misc/dist"

# Working directory must not be under source directory
export PackageWorkDir="/tmp/vaf-work-dir"

# Will be vendor and maintainer
export Author='Dario Berzano <dario.berzano@cern.ch>'

echo "> Source: $PackageSourceDir"
echo "> Destination: $PackageDestDir"

rm -rf "$PackageWorkDir"
mkdir -p "$PackageDestDir" "$PackageWorkDir"

fpm \
  -s dir \
  -t rpm \
  --force \
  --version "$(cat VERSION)" \
  --name vaf-client \
  --package "$PackageDestDir" \
  --workdir "$PackageWorkDir" \
  --vendor "$Author" \
  --maintainer "$Author" \
  --description 'Client for the Virtual Analysis Facility' \
  --url 'https://github.com/dberzano/virtual-analysis-facility' \
  --config-files 'etc' \
  --prefix '/' \
  --exclude '.git' \
  --exclude '.gitignore' \
  --exclude 'VERSION' \
  --exclude 'README.*' \
  --exclude 'misc' \
  --exclude 'tmp' \
  . || exit 1

# Cleanup
rm -rf "$PackageWorkDir"

# Package
Rpm=$( ls -1rt "$PackageDestDir"/*.rpm | tail -n1 )

echo '=== List of the packages directory ==='
ls -l "$PackageDestDir"

echo '=== RPM information ==='
rpm -qip "$Rpm"

echo '=== RPM contents ==='
rpm -qlp "$Rpm"

echo '=== RPM config files ==='
rpm -qcp "$Rpm"
