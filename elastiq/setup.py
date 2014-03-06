from setuptools import setup

if __name__ == '__main__':
  setup(

    # Metadata
    name = 'Elastiq',
    version = '0.9.0',
    author = 'Dario Berzano',
    author_email = 'dario.berzano@cern.ch',
    description = 'Monitor a batch system to scale up/down a virtual cluster',

    # Packages
    packages = [ 'elastiq' ],
    zip_safe = False,
    scripts = [
      'elastiq/bin/elastiq-real.py',
      'elastiq/bin/elastiq',
      'elastiq/bin/elastiq-test-boto.py', ],  # these ones go to <prefix>/bin
    include_package_data = True,
    package_data = {
      '': [ 'etc/*' ]
    },

    # Dependencies
    install_requires = [
      'boto>=2.13.0'
    ]

  )
