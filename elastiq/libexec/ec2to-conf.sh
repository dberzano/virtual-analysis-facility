#
# ec2to-conf.sh -- by Dario Berzano <dario.berzano@cern.ch>
#
# Credentials for accessing the EC2 cloud in Torino.
#

export EC2_URL=https://one-master.to.infn.it/ec2api/
export EC2_ACCESS_KEY='proof'
export EC2_SECRET_KEY=$( echo -n "password" | sha1sum | awk '{print $1}' )
