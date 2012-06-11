Testbed setup
=============

LINC on Xen
===========

Below we outline steps necessary to deploy simple LINC setup with Xen
virtualization layer. Full setup contains:

 * One hardware machine running Xen 4.1 and Ubuntu 12.04 in dom0
 * Two domU virtual machines running Ubuntu 11.04
 * One hardware ethernet interface which provides Internet connection and DHCP
 * 3 port LINC switch

Xen setup
---------

Install Ubuntu 12.04 64bit on designated hardware machine. Select LVM as a
partitioning mechanism and leave some of the disk space unassigned to be used
later on by domU instances.

Enable VT-x or AMD-V virtualization extensions in BIOS.

Install Xen kernel and userspace tools:

    % sudo apt-get install  xen-hypervisor-4.1-amd64 xen-tools xen-utils-common

Reboot machine and select Xen-4.1-amd64 in GRUB after restart.
Select Ubuntu with Xen 4.1 on second GRUB screen.

Copy docs/conf/xen-tools.conf to /etc/xen-tools/xen-tools.conf
Copy docs/conf/xend-config.sxp to /etc/xen/xend-config.sxp

You are now booted into dom0 instance. Execute following commands to prepare
domU virtual machines:

    % xen-create-image --hostname vm1
    % xen-create-image --hostname vm2

You can verify that your VMs are up by executing:

    % sudo xm list

and connect to each of them with:

    % sudo xm console vm{1..2}

LINC setup is the same as in main README. You want to install LINC alongside
Erlang and all of required dependencies on your dom0.

When LINC is compiled you must create tap interfaces for each VM and network
interface that you want to add to LINC switch.

For example if you want to connect vif1 interface to LINC port 1:

    % tunctl -t tap-linc-port1
    % ifconfig tap-linc-port1 0.0.0.0 promisc up
    % ifconfig vif1 0.0.0.0 promisc up
    % brctl addbr br-linc1
    % brctl addif br-linc1 tap-linc-port1
    % brctl addif br-linc1 vif1.0
    % ifconfig br-linc1 10.0.0.1 promisc up

What was done above is that we created new tap interface which acts as a port
for LINC switch and then bridged it with network interface that we want to
connect to the switch. You can think of a bridge as a virtual ethernet cable
that connects network interface (vif1) with LINC port (tap).

You should repeat this process for each virtual ethernet interface exposed by
VMs or real ethernet interface present on the dom0 machine that you want to
connect to LINC switch.

LINC on Virtualbox
==================

TBD.
