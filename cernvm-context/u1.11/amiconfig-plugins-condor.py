#
# Copyright (c) 2008 rPath Inc.
#

import os
import string
import socket
import pwd, grp
import commands
from random import choice

from subprocess import call

from amiconfig.errors import *
from amiconfig.lib import util
from amiconfig.plugin import AMIPlugin

class AMIConfigPlugin(AMIPlugin):
    name = 'condor'

    def configure(self):
        """
        [condor]
        # master host name
        condor_master = <FQDN>
        # shared secret key
        condor_secret = <string>
        #----------------------#
        # host name
        hostname = <FQDN>
        # collector name
        collector_name = CernVM
        # condor user
        condor_user = condor
        # condor group
        condor_group = condor
        # condor directory
        condor_dir = ~condor/condor
        # condor admin
        condor_admin = root@master
        highport = 9700
        lowport = 9600
        uid_domain = <hostname>
        filesystem_domain = <hostname>
        # allow_write = *.$uid_domain
        # localconfig = <filename>
        # slots = 1
        # slot_user = condor
        # cannonical_user = condor
        extra_vars =
        """

        cfg = self.ud.getSection('condor')

        if 'hostname' in cfg:
            hostname = cfg['hostname']
            util.call(['hostname', hostname])

        output = []

        output.append('# Generated using a patched Condor plugin')

        condor_master = ""
        if 'condor_master' in cfg:
            # We are on a worker
            condor_master = cfg['condor_master']
            output.append('DAEMON_LIST = MASTER, STARTD')
        else:

            #
            # We are on the Condor Master.
            #
            # We now try to figure out whether to use the FQDN or the IP
            # address using some heuristics.
            #

            # Configured hostname
            assigned_hostname = socket.gethostname()

            # IP address used for outbound connections. Using a dummy UDP
            # IPv4 socket to a known IP (not opening any actual connection)
            s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            s.connect( ('8.8.8.8', 53) )
            real_ip = s.getsockname()[0]
            s.close()

            # Hostname obtained through reverse lookup from the IP
            #real_hostname = socket.gethostbyaddr(real_ip)[0]
            real_hostname = socket.getfqdn()

            # If there's a mismatch between "real" and "assigned" hostname, use
            # the IP address
            if assigned_hostname == real_hostname:
                condor_master = assigned_hostname
            else:
                condor_master = real_ip

            condor_domain = real_hostname.partition('.')[2]
            if condor_domain == '':
                condor_domain = '*'

            output.append('DAEMON_LIST = COLLECTOR, MASTER, NEGOTIATOR, SCHEDD')

        output.append("CONDOR_HOST = %s" % (condor_master))
        if 'condor_admin' in cfg:
            output.append("CONDOR_ADMIN = %s" % (cfg['condor_admin']))
        else:
            output.append("CONDOR_ADMIN = root@%s" % (condor_master))
        if 'uid_domain' in cfg:
            output.append("UID_DOMAIN = %s" % (cfg['uid_domain']))
        else:
            output.append("UID_DOMAIN = %s" % condor_domain)

        condor_user = 'condor'
        condor_group = 'condor'

        if 'condor_user' in cfg:
            condor_user = cfg['condor_user']
        if 'condor_group' in cfg:
            condor_group = cfg['condor_group']

        os.system("/usr/sbin/groupadd %s 2>/dev/null" % (condor_group))
        os.system("/usr/sbin/useradd -m -g %s %s > /dev/null 2>&1" % (condor_group, condor_user))
        os.system("/bin/chown -R %s:%s /var/lib/condor /var/log/condor /var/run/condor /var/lock/condor" % (condor_user, condor_group))

        condor_user_id = pwd.getpwnam(condor_user)[2]
        condor_group_id = grp.getgrnam(condor_group)[2]

        output.append("CONDOR_IDS = %s.%s" % (condor_user_id, condor_group_id))
        output.append("QUEUE_SUPER_USERS = root, %s" % (condor_user))

        condor_dir = pwd.getpwnam(condor_user)[5]
        if 'condor_dir' in cfg:
            condor_dir = cfg['condor_dir']
        os.system('mkdir -p ' + condor_dir + '/run/condor' + ' ' \
                              + condor_dir + '/log/condor' + ' ' \
                              + condor_dir + '/lock/condor' + ' ' \
                              + condor_dir + '/lib/condor/spool' + ' ' \
                              + condor_dir + '/lib/condor/execute')
        os.system("chown -R %s:%s %s" % (condor_user, condor_group, condor_dir))
        os.system("chmod 755 %s" % (condor_dir))
        output.append("LOCAL_DIR = %s" % (condor_dir))

        condor_highport = '9700'
        condor_lowport = '9600'
        if 'highport' in cfg:
            condor_highport = cfg['highport']
        if 'lowport' in cfg:
            condor_lowport = cfg['lowport']
        output.append("HIGHPORT = %s" % (condor_highport))
        output.append("LOWPORT = %s" % (condor_lowport))

        if 'collector_name' in cfg:
            output.append("COLLECTOR_NAME = %s" % (cfg['collector_name']))
        if 'allow_write' in cfg:
            output.append("ALLOW_WRITE = %s" % (cfg['allow_write']))

        #if 'localconfig' in cfg:
        #    output.append("CONFIG_CONDOR_LOCALCONFIG=%s" % (cfg['localconfig']))
        #if 'slots' in cfg:
        #    output.append("CONFIG_CONDOR_SLOTS=%s" % (cfg['slots']))
        #if 'slot_user' in cfg:
        #    output.append("CONFIG_CONDOR_SLOT_USER=%s" % (cfg['slot_user']))
        #if 'cannonical_user' in cfg:
        #    output.append("CONFIG_CONDOR_MAP=%s" % (cfg['cannonical_user']))

        if 'extra_vars' in cfg:
            output = output + cfg['extra_vars'].split(',');

        # Write the configuration file
        if len(output):
            f = open('/etc/condor/condor_config.local', 'w')
            f.write('\n'.join(output))
            f.close()

            # Condor secret can be written only after creating the config file
            if 'condor_secret' in cfg:
                os.system("/usr/sbin/condor_store_cred add -c -p %s > /dev/null" % (cfg['condor_secret']))

            # We can start Condor now
            os.system("/sbin/chkconfig condor on")
            os.system("/sbin/service condor restart")
