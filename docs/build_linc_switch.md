# Build a LINC OpenFlow Switch for < $3,000

## Hardware requirements:
>1. Standard Intel x86-64 CPU with 4GB RAM and four network ports (minimum), capable of running Linux v. 3.1+ kernel.
>2. American Portwell Technology, Inc., model [CAR-4010](http://www.portwell.com/products/ca.asp), available with either four 1GbE RJ45 ports or four SFP ports.

>_Note: LINC can also work on other higher end platforms such as [Tilera](http://www.tilera.com")._

>*Additional accessories needed: USB Keyboard, VGA monitor, Power Cord, and Ethernet cables.*

## Software Requirements:
>1. Download the ISO image (around 460MB) from [http://susestudio.com/a/ENQFFD/fflinc](http://susestudio.com/a/ENQFFD/fflinc)
>2. Burn the ISO image as a bootable CD or use [UNetbootin](http://unetbootin.sourceforge.net/) to install the same on a USB thumb drive.

## Installation:
>1. Connect Ethernet cable from standard Switch port to hardware box's eth0 (management port) so that it can get a IP address via DHCP server running on the network.
>2. Connect the CD or USB (as appropriate) to install the LINC Software on hardware
>3. Connect the power cable to the hardware box and power it on and boot from CD/USB to install the LINC Software

### Post Install setup:
Step 1: Login to the "LINC" box using credentials:
    
    username: root 
    password: linc
Step 2: Set time synchronization:
    
    ntpdate time.nist.gov
Step 3: Set Git configuration:

    git config --global http.sslVerify false
Step 4: Create the necessary ethernet, bridge and tap configuration files:

create\_ifcfg\_eth\_br\_tap is a script file that creates necessary ethernet, bridge and tap configuration files. By default, the script creates 15 network interfaces. To change the number of network interfaces, edit the script modify the value of num_interfaces=15 and then execute the same.

    /usr/local/src/linc/misc_tools/create_ifcfg_eth_br_tap

    Files will be created under: /etc/sysconfig/network
    Look for files starting from ifcfg-*
    
###### Don't change the eth0 interface, as you may lose connectivity to the box.

Step 5: Restart network services

    service network restart

