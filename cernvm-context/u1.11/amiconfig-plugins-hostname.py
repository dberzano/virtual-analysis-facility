#
# Copyright (c) 2008 rPath Inc.
#

from amiconfig.errors import *
from amiconfig.lib import util
from amiconfig.plugin import AMIPlugin

import socket

class AMIConfigPlugin(AMIPlugin):
    name = 'hostname'

    def configure(self):
        cfg = self.ud.getSection('hostname')
        if 'hostname' in cfg:
            hostname = cfg['hostname']
        else:
            try:
                hostname = self.id.getLocalHostname()
            except EC2DataRetrievalError:
                return

        #
        # Special section to configure other embarrassing stuff
        #

        # Domain name
        domain = hostname.partition('.')[2]

        # Set hostname
        util.call(['hostname', hostname])

        if domain == 'cern.ch':

            #
            # We are at CERN: we need a very special workaround =(
            #
            # Without this workaround, 'hostname -f' might return 'unknown host'
            # for a while before the hostname gets really registered.
            #
            # DON'T TRY THIS AT HOME (it sucks badly)
            #

            # Get the IP(v4) with a trick
            s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            s.connect( ('8.8.8.8', 53) )
            real_ip = s.getsockname()[0]
            s.close()

            # Domain servers
            dns = [ '137.138.17.5', '137.138.16.5' ]

            # Change resolv.conf
            with open('/etc/resolv.conf', 'w') as f_resolv:
                f_resolv.write("search %s\n" % domain)
                f_resolv.write("nameserver 127.0.0.1\n")

            # Prepare conf for dnsmasq
            with open('/etc/dnsmasq.conf', 'w') as f_dns:
                f_dns.write("localise-queries\n")
                f_dns.write("no-resolv\n")
                for d in dns:
                    f_dns.write("server=%s\n" % d)

            # Hosts (append)
            with open('/etc/hosts', 'a') as f_hosts:
                f_hosts.write("\n%s %s\n" % (real_ip, hostname))

            # Prevent resolv.conf from being changed ever again
            with open('/etc/sysconfig/network-scripts/ifcfg-eth0', 'a') as f_eth0:
                f_eth0.write("\nPEERDNS=no\n")

            # Restart network and start dnsmasq
            os.system("/sbin/service dnsmasq start")
            os.system("/sbin/service network restart")
