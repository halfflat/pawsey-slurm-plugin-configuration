# Pawsey Slurm Plugins

Pawsey-specific slurm plugins for our deployment are collected here.
At this point we have only the one plugin, a lua cli_filter plugin.

## Deployment and testing

The top-level Makefile is responsible for performing any keyword substitutions
or, in the future, any source compilation for the plugins.

The resultant scripts and shared objects are installed in the `stage`
directory. These can then be copied to the appropriate system locations for
deployment.

Any test suites can be built (if required) and then run with `make check`.
The lua executable used for testing can be set with the `LUA` environment variable.


### Plugins

## cli_filter plugin

The plugin is used to ensure correct memory provisioning for non-gpu partition
allocations, and to ensure fair shared allocations on the gpu partitions.

