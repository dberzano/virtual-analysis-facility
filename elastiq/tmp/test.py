#!/usr/bin/env python

import boto
import socket

# Open boto connection
ec2h = boto.connect_ec2_endpoint(
  'https://one-master.to.infn.it/ec2api/',
  aws_access_key_id='proof',
  aws_secret_access_key='5baa61e4c9b93f3f0682250b6cf8331b7ee68fd8')

# Loop over all reservations and instances
vm_ips = []  # will contain only running instances with valid private IPs
ec2r = ec2h.get_all_reservations()
for r in ec2r:
  ec2i = r.instances
  for i in ec2i:
    #print "vm:%s type:%s priv_ip:%s pub_ip:%s state:%s" % (i.id, i.instance_type, i.private_ip_address, i.ip_address, i.state)
    if i.private_ip_address is not None and i.state == 'running':
      if i.private_ip_address == '172.16.212.196':
        print "Terminating %s" % i.private_ip_address
        i.terminate()
        i.terminate()  # twice (long story)
      else:
        vm_ips.append( i.private_ip_address )

if len(vm_ips) == 0:
  print "Error! I would expect at least one VM"
  exit(1)

# Try to figure out my IP by simulating a connection to one VM's priv IP
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.connect( (vm_ips[0], 53) )
my_ip = s.getsockname()[0]
s.close()

# Remove current IP from the list
vm_ips.remove(my_ip)

# List what is left
for ip in vm_ips:
  print ip
