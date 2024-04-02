# Introduction #

The scripts in this directory are useful for environments that require fencing actions.

The `ipmi-remote-host` and `fence-remote-host` scripts cannot be run simultaneously. The `ipmi-remote-host` script is for environments that allow direct IPMI access to the BMC of all nodes that mount the ScoutFS filesystem. The `fence-remote-host` script is for environments that have one or more different node access types including IPMI, Powerman, and vSphere.

# `ipmi-remote-host` #

The `ipmi-remote-host` script is the default fencing script for ScoutFS for environments that have all bare-metal nodes with direct IPMI access to all nodes BMC devices.

Documentation for `ipmi-remote-host` script, configuration, and operations is available at [ScoutFS Fencing](https://docs.versity.com/docs/scoutfs-fencing).

# `fence-remote-host` #

The `fence-remote-host` script supports direct IPMI, indirect IPMI using `powerman`, and VM environments with vSphere.

## Usage ##

```
Usage: fence-remote-host [-h|--help] [-C|--config file] [-H|--hosts file] [-d|--debug] [-v|--verbose] [-t|--test] | -i|--ip IP -r|--rid RID
```

## Installation ##

The `fence-remote-host` script is typically installed in the directory `/usr/libexec/scoutfs-fenced/run`.

The script MUST be installed on all ScoutFS quorum nodes.

```bash
mkdir -p /usr/libexec/scoutfs-fenced/run
cp fence-remote-host /usr/libexec/scoutfs-fenced/run/
chmod +x /usr/libexec/scoutfs-fenced/run/fence-remote-host
```

### Testing Configuration ###

The fencing configuration can be tested using the following command:

```bash
/usr/libexec/scoutfs-fenced/run/fence-remote-host --test
```
Example output:

```
PASS - SSH to 10.0.0.100
FAIL - powerman power state for 10.0.0.100 from v1
PASS - powerman power state for 10.0.0.100 from 172.21.1.51
PASS - SSH to 10.0.0.101
FAIL - powerman power state for 10.0.0.101 from v1
PASS - powerman power state for 10.0.0.101 from 172.21.1.51
PASS - SSH to 10.0.0.102
FAIL - powerman power state for 10.0.0.102 from v1
PASS - powerman power state for 10.0.0.102 from 172.21.1.51
```

In the above output the script is testing for passwordless SSH connectivity and checking power state using `powerman`. Note that the `powerman` mode does support multiple Powerman servers for redundancy. For this example the Powerman server `v1` was not responding, but the power state for each node was verified from the Powerman server `172.21.1.51`.

## Passwordless SSH Considerations ##

The `fence-remote-host` script still requires passwordless SSH between all nodes that mount the ScoutFS filesystem but adds the ability to use non-root identities. If using a non-root user, the following parameters can be added to the `/etc/scoutfs/scoutfs-ipmi.conf` configuration file:

```
SSH_USER=user
SSH_IDENTS="-i ~user/.ssh/id_rsa -i ~user/.ssh/id_rsa.pub"
```

These parameters will modify the SSH command used in the script to log in as `user` and use the private and public SSH keys defined in the `SSH_IDENTS` parameter.

## Powerman ##

Powerman can be used in environments that do not allow node-to-node BMC connections. The `powerman`

> [!IMPORTANT]
> Versity does not directly support Powerman. While we can provide guidance and example configurations, we do not debug or provide fixes for Powerman.

### Installation ###

The `powerman` package is part of the EPEL repository. Refer to [EPEL](https://docs.fedoraproject.org/en-US/epel/) to install the EPEL repository on your system.

The `powerman` package can be installed after the EPEL repository is enabled:

```bash
yum install -y powerman
```

> [!IMPORTANT]
> By default the `powerman` command installed by `powerman` package is world executable. We recommend securing access to the `powerman` command by adjusting the permissions to 700 with `chmod 700 /bin/powerman`.

#### Where to Install Powerman ####

The `powerman` package will need to be installed on the designated node(s) that have BMC access to the ScoutAM nodes as well as all ScoutFS quorumn nodes. The ScoutFS quorum nodes will use the `pm` command to issue remote power status and off commands to the Powerman servers.

Multiple Powerman servers are supported to enable redundancy if one Powerman server is unavailable.

### Configuration ###

The configuration file for Powerman is `/etc/powerman/powerman.conf`. Here is an example configuration for Dell systems with iDRAC that support the `ipmipower` command:

```
listen "0.0.0.0:10101"
include "/etc/powerman/ipmipower.dev"
device "ipmi_radia" "ipmipower" "/usr/sbin/ipmipower -D LAN_2_0 --wait-until-on --wait-until-off -u admin -p password -h radia[1-5]-ipmi |&"
node "radia[1-5]"    "ipmi_radia" "radia[1-5]-ipmi"
```

> [!NOTE]
> Any change to the `/etc/powerman/powerman.conf` file requires the `powerman` service to be restarted.

### Starting/Stoping Powerman ###

The `powerman` service can be controlled with the `systemctl` command.

Starting the `powerman` service:

```bash
systemctl start powerman
```

Stopping the `powerman` service:

```bash
systemctl stop powerman
```

### Verifying Powerman ###

Once `powerman` is configured and running on one or more designated Powerman servers, the configuration can be validated by checking the power status of all nodes from a ScoutFS quorum member.

Example querying the power state of all configured nodes:

```bash
powerman -h admin -q
```

Example output:

```
on:      radia[1-5]
off:
unknown:
```

### ScoutFS Fencing Configuration ###

After validating the `powerman` configuration, the host definitions in `/etc/scoutfs/scoutfs-ipmi-hosts.conf` file are as follows:

```
10.0.0.100  powerman    v1,172.21.1.51:radia1
10.0.0.101  powerman    v1,172.21.1.51:radia2
10.0.0.102  powerman    v1,172.21.1.51:radia3
10.0.0.102  powerman    v1,172.21.1.51:radia4
10.0.0.102  powerman    v1,172.21.1.51:radia5
```

The fields for the Powerman configuration are as follows:

```
SCOUTFS_QUORUM_IP    powerman    PM_SRV1[,PM_SRV2]:PM_NODE
```

The first parameter `SCOUTFS_QUORUM_IP` is the IP address that ScoutAM uses for quorum communications. The second parameter is the mode `powerman`. The third parameter includes a comma separated list of Powerman servers followed by a colon (`:`) and the name of the node configured in the Powerman configuration.

The `PM_SRVN` parameter can support host names or IP addresses. The `PM_NODE` parameter must match a `node` parameter in `/etc/powerman/powerman.conf` on the Powerman servers.

## VMWare vSphere ##

The `fence-remote-host` script has been adapated to support fencing virtual machines in a VMWare vSphere environment. When using vSphere mode with fencing, the `fence-remote-host` script must be able to access the following API endpoints on your vSphere server:

[Create Session](https://developer.vmware.com/apis/vsphere-automation/latest/cis/api/session/post/)

[Get Power](https://developer.vmware.com/apis/vsphere-automation/latest/vcenter/api/vcenter/vm/vm/power/get/)

[Stop Power](https://developer.vmware.com/apis/vsphere-automation/latest/vcenter/api/vcenter/vm/vm/poweractionstop/post/)

### vSphere Authentication ###

The authentication information for vSphere is stored in `/etc/scoutfs/scoutfs-ipmi.conf` with the `VSPHERE_USER` and `VSPHERE_PASS` directives:

```bash
VSPHERE_USER=admin
VSPHERE_PASS=password
```

### vSphere Fencing Configuration ###

The host definitions for vSphere VMs are defined in `/etc/scoutfs/scoutfs-ipmi-hosts.conf` as follows:

```
10.0.0.200   vsphere   vsphere-admin:vm50001
10.0.0.201   vsphere   vsphere-admin:vm50002
10.0.0.202   vsphere   vsphere-admin:vm50003
```

The fields for the vSphere configuration are as follows:

```
SCOUTFS_QUORUM_IP  vsphere   VSPHERE_API_HOST:VM_IDENTIFIER
```

The first parameter `SCOUTFS_QUORUM_IP` is the IP address that ScoutAM uses for quorum communications. The second parameter is the mode `vsphere`. The third parameter includes the vSphere API host followed by a colon (`:`) and the VM identifier of type VritualMachine that can be obtained from vSphere.
