# Introduction #

The scripts in this directory are useful for environments that require fencing actions.

# `ipmi-remote-host` #

The `ipmi-remote-host` script is the default fencing script for ScoutFS for
environments that have all baremetal nodes with direct IPMI access to all nodes
BMC devices.

# `fence-remote-host` #

The `fence-remote-host` script supports direct IPMI, indirect IPMI using
`powerman`, and VM environments with vSphere.
