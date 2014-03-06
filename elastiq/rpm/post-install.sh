#!/bin/sh
useradd elastiq --shell /sbin/nologin --no-create-home --system --user-group --home-dir /var/lib/elastiq
if [ $? != 9 ] && [ $? != 0 ] ; then
  exit 1
fi
mkdir -p /var/lib/elastiq /var/log/elastiq
chmod u=rwx,g=rwx,o=x /var/lib/elastiq /var/log/elastiq
chown elastiq:elastiq /var/lib/elastiq /var/log/elastiq
ln -nfs /usr/bin/elastiq /etc/init.d/elastiq
chkconfig --add elastiq
exit 0
