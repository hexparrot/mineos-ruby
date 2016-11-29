Ruby MineOS
=====

MineOS is a server front-end to ease managing Minecraft administrative tasks.
This iteration using Ruby is much more ambitious than previous models--Node & Python--
by heavily modularizing each of the components to make a much more distributed setup.

The primary components are the MineOS front-end, a central HQ for monitoring and logging,
and worker nodes.  Each are designed to run on separate machines (physical or logical)
such as using docker or installing on bare metal.

Overview
-----

Machine A will have the worker node installed on it, with its only dependencies being ruby + Java.

Machine B will have the central HQ server, which will register Machine A (and any others) and provide
system level stats of Machine A's health and utilization. This will also be the machine many
other lower-level systems will be installed on, such as the Rabbit Messaging Queue and object storage.
These components can be installed elsewhere, but installed local on the HQ for installation ease.

The MineOS front-end will then be either hosted by the HQ or distributed in an archived file format,
since all the communication back and forth will be through websockets(or Restful API) to the HQ.

Development
-----

The final architecture is still undecided, whether this may instead be distributed primarily
with docker-compose or whether there will even be an all-in-one (single machine) configuration.

More information will be posted here as development progresses and technical hurdles emerge and
are addressed.
