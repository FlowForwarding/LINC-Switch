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

    % sudo apt-get install xen-tools xen-utils-common xen-hypervisor-4.1-amd64

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

LINC on Virtualbox
==================
