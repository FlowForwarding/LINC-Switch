LINC integration with Mininet
=============================

Mininet is a tool facilitating creation of realistic virtual networks. More you can find on Mininet [official website](http://mininet.org/).

Now LINC-Switch is shipped with Mininet and can be ran as a part of its virtual network. The aim of this integration is to provide easy to setup environment for testing different scenarios with LINC-Switch in the leading role. Particularly Mininet allows for creating topologies using python API. It will be very convenient to use python scripts as a mean of exchanging topologies and scenarios. In addition, Mininet has a power CLI that allows quickly run some simple test case.

## Table of Contents ##
1. [Installation](#installation)
2. [Getting started](#getting-started)
  1. [Ping](#ping)
  1. [Other controllers](#other-controllers)
  1. [More advanced topologies](#more-advanced-topologies)
  1. [Using dpctl](#using-dpctl)
  1. [Further reading](#further-reading)

## Installation ##

Mininet has an installation script for Ubuntu and Debian. To install Mininet with LINC-Switch on board clone the [repository](https://github.com/FlowForwarding/mininet), enter mininet directory and run the following commands:  
`util/install.sh -3nfxL`

Optionally you can provide a revision to checkout:  
`LINC_SWITCH_REV="issue129" util/install.sh -3nfxL`

This will install Mininet core, [NOX 1.3 Controller](https://github.com/CPqD/nox13oflib), [OpenFlow 1.3 Software Switch](https://github.com/CPqD/ofsoftswitch13) and required dependencies:
* tunctl (from uml-utilities package),
* brctl (from bridge-utils package),
* erlang,
* git-core.

## Getting started ##

### Ping ###
To warm up with the Mininet just try to run a simple ping example with LINC-Switch connected to the Mininet network and governed by our simple controller. Follow the steps below:

1. Start the Mininet with LINC-Switch, two hosts and the remote controller:  
`sudo bin/mn --controller=remote --switch=linc`
1. In another console attach to the LINC-Switch console to see that it really works:  
`sudo linc <SWITCH_NAME> attach`
Switch name is assigned by Mininet. Usually the first switch is named `s1`.
1. In yet another console run the controller:  
`sudo linc_controller -p 6633 -d -s table_miss`  
The controller will connect to the switch and sends it a flow modification message making the switch send all unmatched packets to the controller.
1. From the mininet CLI send a ping from one host to the other:  
`h1 ping -c 3 h2`  
Optionally you can install Wireshark with [OpenFlow 1.3 dissector](https://github.com/CPqD/ofdissector) and observe OpenFlow protocol messages.

### Other controllers ###
You can use other controllers to experiment with LINC on Mininet. To make LINC connect to a remote controller use below syntax:  
`sudo bin/mn --controller=remote,ip=<CONTROLLER IP>,port=<CONTROLLER PORT> --switch=linc`

For example you can utilize [NOX 1.3 controller](https://github.com/CPqD/nox13oflib) that is shipped with Mininet.
Good starting point is running NOX with switch backend. To achieve this setup run NOX controller (by default NOX is installed in the same directory as Mininet):  
`cd nox13oflib/build/src && sudo ./nox_core -i ptcp:6655 switch`  
Let's assume that this NOX instance is running on `10.0.0.23` machine. Then you have to start Mininet with LINC as follows:  
`sudo bin/mn --controller=remote,ip=10.0.0.23,port=6655 --switch=remote`  
Then perform two first steps from the [ping](#ping) chapter. Now you can try to run ping between the two hosts.

> By default a switch started by Mininet tries to connect to a controller that listens on 127.0.0.1:6633.

### More advanced topologies ###
Mininet allows to create more complex topologies through its python API. You can setup a topology with two directly connected LINC switches plus a host for each switch
`host --- switch --- switch --- host`  
This topology is defined in the Mininet repository in [topo-2sw-2host.py](https://github.com/mininet/mininet/blob/master/custom/topo-2sw-2host.py). To get started follow the  instructions below:

1. Start the Mininet with LINC-Switch and the custom topology:  
`sudo bin/mn --controller=remote --switch=linc --custom custom/topo-2sw-2host.py --topo mytopo`
1. In another console run the controller with a prepared scenario:  
`sudo linc_controller -p 6633 -d -s mininet_mytopo`  
3. Ping the hosts from the Mininet CLI:  
`pingall`  
4. Optionally you can attach to switches' consoles (the commands has to be ran from separate terminals):  
`sudo linc s3 attach`  
`sudo linc s4 attach`

> Note that the `s3` and `s3` names are defined in the file with the topology: `topo-2sw-2host.py`.

### Using dpctl  ###

A dpctl tool provides basic control over an OpenFlow switch that has a passive listening port. LINC-Switch supports this feature. By default Mininet sets this port to `6634`, although it can be set through the command line option: `--listenport=<PORT>`. The tool can be used in two ways from the Mininet CLI:

1. It can be run for each switch in the topology:  
`mininet> dpctl <COMMAND> [<ARG>...]`  
For example:  
`mininet> dpctl get-config`
1. It can be run per switch. Then the dpctl command is invoked like from the switch's shell:
`mininet> <SWITCH_NAME> dpctl [<OPTIONS>] <SWITCH> <COMMAND> [<ARG>...]`  
For example:  
`mininet> s1 dpctl tcp:127.0.0.1:6634 features`

To get description of the dpctl see output of `dpctl --help`.

### Further reading ###
The best starting point to dive into the Mininet further is to follow the [Mininet Walkthrough](http://mininet.org/walkthrough/).
To get more familiar with Mininet Python API you can read [Introduction to Mininet](https://github.com/mininet/mininet/wiki/Introduction-to-Mininet).
