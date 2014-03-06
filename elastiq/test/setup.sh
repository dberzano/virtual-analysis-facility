#!/bin/bash

cd $( dirname "$0" )/..

export PyBase='/tmp/testpybase'
export PyFull="${PyBase}/lib/python2.6/site-packages"
export PYTHONPATH="$PyFull"

rm -rf "$PyBase"
mkdir -p "$PyFull"

rm -rf build/ dist/ Elastiq.egg-info/

exec python setup.py install --prefix="$PyBase"
