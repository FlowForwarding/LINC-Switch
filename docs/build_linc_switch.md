# Build a LINC OpenFlow Switch for < $3,000

## Hardware requirements:
>1. Standard Intel x86-64 CPU with 4GB RAM and four network ports (minimum), capable of running Linux v. 3.1+ kernel.
>2. American Portwell Technology, Inc., model [CAR-4010](http://www.portwell.com/products/ca.asp), available with either four 1GbE RJ45 ports or four SFP ports.

>_Note: LINC has been tested to also work on other higher end platforms such as [Tilera](http://www.tilera.com")._

>*Additional accessories needed: USB Keyboard, VGA monitor, Power Cord, and Ethernet cables.*

## Software Requirements:
>1. Download the ISO image (around 460MB) from [http://susestudio.com/a/ENQFFD/fflinc-1_2](http://susestudio.com/a/ENQFFD/fflinc-1_2)
>2. Follow instructions on the download page install the same on a USB thumb drive.

## Installation:
>1. Connect Ethernet cable from standard Switch port to hardware box's eth0 (management port) so that it can get a IP address via DHCP server running on the network.
>2. Connect the CD or USB (as appropriate) to install the LINC Software on hardware
>3. Connect the power cable to the hardware box and power it on and boot from CD/USB to install the LINC Software

### Post Install setup:
*Note: All operations are executed as user "root"*

Step 1: Login to the "LINC" box using credentials:
    
    username: root 
    password: linc

Step 2: Create the necessary ethernet configuration files:

create\_ifcfgeth\_files is a script file that creates necessary ethernet configuration files. By default, the script creates 3 network interfaces. To change the number of network interfaces, edit the script modify the value of num_interfaces=3 and then execute the same.

    #  /usr/local/src/linc/misc_tools/create_ifcfgeth_files

    Files will be created under: /etc/sysconfig/network
    Look for files starting from ifcfg-*
    
###### Don't change the eth0 interface, as you may lose connectivity to the box.

Step 5: Restart network services

    #  service network restart

### Setup LINC OpenFlow Switch
    #  cd /usr/local/src/linc/LINC-Switch
    #  Generate rel/files/sys.config using the command:
    #  scripts/config_gen -s 0 eth1 eth2 eth3 -c tcp:127.0.0.1:6633 -o rel/files/sys.config
    #  make rel
    
### Setup Ryu OpenFlow Controller
    #  cd /usr/local/src/ofcontroller
    #  git clone https://github.com/osrg/ryu
    #  cd ryu
    #  python setup.py install
    
## Running LINC OpenFlow Switch
    #  cd /usr/local/src/linc
    #  rel/linc bin/linc start
    #  To Stop LINC, run 
    #  rel/linc/bin/linc stop
    
## Running Ryu OpenFlow Controller
Start the Ryu Controller in Flow Learning mode for OpenFlow v 1.3

    #  cd /usr/local/src/ofcontroller/ryu
    #  bin/ryu-manager --verbose /usr/local/src/ofswitch/LINC-Switch/scripts/ryu/l2_switch_v13.py
    (press CNTRL+C to quit)

## Running Warp OpenFlow Driver

    #  cd /usr/local/src/ofcontroller/warp
    #  java -jar build/binaries/pre-built/warp.jar

## Questions?
Subscribe and post questions, suggestions, comments and answers to linc-dev@flowforwarding.org mailing list  For questions about warp, use warp-dev@flowforwarding.org
    
