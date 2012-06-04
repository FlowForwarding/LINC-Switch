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

For example if you want to add eth0 interface to LINC, you must create tap
interface with tunctl and bridge with brctl. Next you add both tap and eth to
created bridge and use tap interface in LINC port config.

If you want to add vif created by Xen to connect domU VM to LINC, create tap
interface with tunctl and bridge with brctl. Next add both vif and tap to
created bridge and use tap interface in LINC port config.

LINC on Virtualbox
==================

TBD.
