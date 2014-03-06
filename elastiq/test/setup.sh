#!/bin/bash

cd $( dirname "$0" )
cd ..

export PyBase='/tmp/testpybase'
export PyFull="${PyBase}/lib/python2.6/site-packages"
export PYTHONPATH="$PyFull"

rm -rf "$PyBase"
mkdir -p "$PyFull"

rm -rf build/ dist/ Elastiq.egg-info/
if [ "$1" == '' ] ; then
  python setup.py install --prefix="$PyBase"
elif [ "$1" == 'rpm' ] ; then
  python setup.py bdist_rpm --post-install=rpm/post-install.sh --post-uninstall=rpm/post-uninstall.sh
else
  python setup.py "$@"
fi
