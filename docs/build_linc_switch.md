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
*Note: All operations are executed as user "root"*

Step 1: Login to the "LINC" box using credentials:
    
    username: root 
    password: linc
Step 2: Set time synchronization:
    
    #  ntpdate time.nist.gov
Step 3: Set Git configuration:

    #  git config --global http.sslVerify false
Step 4: Create the necessary ethernet, bridge and tap configuration files:

create\_ifcfg\_eth\_br\_tap is a script file that creates necessary ethernet, bridge and tap configuration files. By default, the script creates 15 network interfaces. To change the number of network interfaces, edit the script modify the value of num_interfaces=15 and then execute the same.

    #  /usr/local/src/linc/misc_tools/create_ifcfg_eth_br_tap

    Files will be created under: /etc/sysconfig/network
    Look for files starting from ifcfg-*
    
###### Don't change the eth0 interface, as you may lose connectivity to the box.

Step 5: Restart network services

    #  service network restart

Step 6: Check created bridges and taps

    #  brctl show
    
    bridge name  bridge id           STP enabled       interfaces
    br1          8000.0090fb3771ef   no                eth1
                                                       tap1
    br10         8000.0090fb411cba   no                eth10
                                                       tap10
    br11         8000.0090fb411cbb   no                eth11
                                                       tap11
    br12         8000.0090fb411cbc   no                eth12
                                                       tap12
    br13         8000.0090fb411cbd   no                eth13
                                                       tap13
    br14         8000.0090fb411cbe   no                eth14
                                                       tap14
    br15         8000.0090fb411cbf   no                eth15
                                                       tap15
    br2          8000.0090fb3771f0   no                eth2
                                                       tap2
    br3          8000.0090fb3771f1   no                eth3
                                                       tap3
    br4          8000.0090fb3771f2   no                eth4
                                                       tap4
    br5          8000.0090fb3771f3   no                eth5
                                                       tap5
    br6          8000.0090fb3771f4   no                eth6
                                                       tap6
    br7          8000.0090fb3771f5   no                eth7
                                                       tap7
    br8          8000.0090fb411cb8   no                eth8
                                                       tap8
    br9          8000.0090fb411cb9   no                eth9
                                                       tap9
### Setup LINC OpenFlow Switch
    #  mkdir -p /usr/local/src/linc
    #  cd /usr/local/src/linc/
    #  git clone https://github.com/FlowForwarding/LINC-Switch
    #  cd LINC-Switch
    #  vi rel/files/sys.config - modify LINC Switch configuration parameters.  See section on modifying sys.config
    #  make compile
    #  make rel
    
### Setup Ryu OpenFlow Controller
    #  cd /usr/local/src/
    #  git clone https://github.com/osrg/ryu
    #  cd ryu
    #  python setup.py install
    
## Running LINC OpenFlow Switch
    #  cd /usr/local/src/linc
    #  rel/linc bin/linc console
    (type with out quotes: "q()." at the prompt to quit console)
    (alternatively, you can also run this as a deamon)
    #  rel/linc/bin/linc
    
## Running Ryu OpenFlow Controller
Start the Ryu Controller in Flow Learning mode for OpenFlow v 1.3.1

    #  cd /usr/local/src/ryu
    #  bin/ryu-manager --verbose /usr/local/src/linc/LINC-Switch/scripts/ryu/l2_switch_v13.py
    (press CNTRL+C to quit)

## Questions?
Subscribe and post questions, suggestions, comments and answers to linc-dev@flowforwarding.org mailing list
    
