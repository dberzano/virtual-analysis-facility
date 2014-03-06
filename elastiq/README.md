elastiq
=======

elastiq is a lightweight Python daemon that allows a cluster of
virtual machines running a batch system to scale up and down
automatically.

----------------------------------------------------------------------

**Scale up.** elastiq monitors the batch system's queue. If too many
jobs are waiting, it requests new virtual machines.

**Scale down.** elastiq monitors cluster's virtual machines. If some
machines are idle for some time, it turns them off.

**EC2.** elastiq communicates with the cloud via the ubiquitous EC2
interface. The [boto](https://github.com/boto/boto) library is used
for that.

**Quotas.** elastiq supports a quota for a minimum and maximum number
of virtual machines. It will always ensure that a minimum number of
virtual machines are running, and it will never run too many virtual
machines.

**Plugins.** elastiq can support several batch systems via plugins. It
already comes with support for
[HTCondor](http://research.cs.wisc.edu/htcondor/).

**IaaS embedded elasticity.** elastiq allows to run an entire IaaS
cluster that scales itself without using tools running outside the
virtual cluster. Run it on the head node of your virtual cluster and
it will scale it on any cloud exposing an EC2 interface.
