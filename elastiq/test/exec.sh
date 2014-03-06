export PyBase='/tmp/testpybase'
export PyFull="${PyBase}/lib/python2.6/site-packages"
export PYTHONPATH="$PyFull"

export PATH="$PyBase/bin:$PATH"

export PS1="PY [\W] \$ > "
exec bash -i
