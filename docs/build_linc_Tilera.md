#Building LINC on Tilera Platform
This document describes how one can build an OpenFlow Switch on Tilera’s Tile-36GX Platform.

##Requirements
###Hardware

>1. Standard Intel x86-64 CPU with 4GB RAM and four network ports (minimum), capable of running Linux v. 3.1+ kernel. (Ex.  American Portwell Technology, Inc., model CAR-4010)

>2. Tile-36GX PCIe Card which is installed in the slot available on the Portwell CAR-4010 box (Linux host)

###Software

>1. Download FREE LINC ISO image from [http://susestudio.com/a/ENQFFD/fflinc](http://susestudio.com/a/ENQFFD/fflinc) and burn the same on a bootable CD

>2. Tilera Software is also required ($$)

## Setup
Install the Tilera Board and Tilera Software.  The release notes also have pretty clear instructions on how to install the software onto your x86 Linux host.  You will create a Tilera software directory (eg. /opt/tilera/) and that will contain the code for x86 (drivers, cross-compilers, etc) and a copy of the native Tilera file system.

Login to Linux Host  - *“Linux Host Window”*

When you boot the Tilera card, it will be running as a separate Linux system (ex. a 36-way SMP Linux) that will appear as an endpoint device on the x86 (as root-complex) PCIe bus.

```bash
# ls -C1 -F /opt/tilera/
run_eval
TileraMDE-4.1.4.152692/
TileraMDE-4.1.4.152692_tilegx.tar
TileraMDE-4.1.4.152692_tilegx_tile_full.tar.xz
#
```

LINC is written in Erlang.  Hence, download Erlang (R16B) [source](http://www.erlang.org/download.html) and compile Erlang on the Linux host that we will install this card.  First, no changes to the Erlang source is made, but compiled and tested the same to work correctly. 

Erlang OTP Source is installed in – 
```bash
ERLANG_OTP_ROOT=/usr/local/src/erlang/otp_src_R16B
```

Erlang source uses MALLOC_USE_HASH() macro.  This is removed to help control the hash-for-home behavior of the heap by means of the ucache_hash kernel boot-time argument or the LD_CACHE_HASH environment variable.  To find the macro, 
```bash
# cd $ERLANG_OTP_ROOT/erts/emulator/sys/unix 
# grep -n MALLOC_USE_HASH sys.c
412:MALLOC_USE_HASH(1);
```

And comment line 412.  Now the code snippet looks like this:
```C
 411 #include <malloc.h>
 412 //MALLOC_USE_HASH(1);
 413 #define MAP_CACHE_HASH_ENV_VAR "LD_CACHE_HASH"
 414 #endif
```

On the Linux host, setup Tilera Profile - ~/.tilerc
```bash
# more ~/.tilerc 
eval `/opt/tilera/TileraMDE-4.1.4.152692/tilegx/bin/tile-env`
# 
# source ~/.tilerc
# echo $PATH
	/opt/tilera/TileraMDE-4.1.4.152692/tilegx/bin:/sbin:/usr/sbin:/usr/local/sbin:/root/bin:/usr/local/bin:/usr/bin:/bin:/usr/bin/X11:/usr/X11R6/bin:/usr/games:/usr/lib/mit/bin
```
Tile-monitor is a application that helps connect the Linux Host to the Tilera Card via PCIe.   Start the tile-monitor process:
```bash
# tile-monitor --dev gxpci0 –-root 
```

At the Command: prompt, type the following commands.

>>  The tunnel command sets up SSH routing to 10022 port to enable easy work environment.
>>  The mount-same commands will load the following Linux directories into Tilera environment.
```bash
Command: tunnel 10022 22
Command: mount-same /usr/local/src/linc/LINC-Switch
Command: mount-same /usr/local/src/erlang/R16B-tile 
Command: mount-same /usr/local/src/erlang/otp_src_R16B 
```

Open another terminal window and login in via SSH into the Tilera card using the already setup tunnel – *“Tilera Host Window”*
```bash
# ssh –p 10022 root@10.10.10.10
# PATH=/usr/local/src/erlang/R16B-tile/bin:$PATH; export PATH
# ifconfig –a
# ifup xgbe1 [if xgbe1 (10Gb) or gbe1 (1Gb) is not up]
```
Group 'nogroup' is required for epcap:

```bash
# groupadd nogroup
```

sudo has to run in non-interactive mode (notty)

```bash
# visudo
    Then, comment out line 56: "Defaults    requiretty"
```

Enable rest of the xgbe interfaces:
```bash
# ifconfig xgbe2 0.0.0.0 promisc up
# ifconfig xgbe3 0.0.0.0 promisc up
# ifconfig xgbe4 0.0.0.0 promisc up
```

>>NOTE: As Tilera OS uses RAM FS (in this scenario), it erases all changes after disconnection, so one has to repeat aforementioned steps each time you log in to Tilera box/card.

Alternatively, one could tile-monitor untility from the command line using the below script which automates the above manual steps:
```bash
#!/bin/sh

tile-monitor --dev gxpci0 \
  --root \
  --tunnel 10022 22 \
  --mount-same /usr/local/src/linc/tilera/LINC-Switch \
  --mount-same /usr/local/src/erlang/R16B-tile \
  --mount-same /usr/local/src/erlang/otp_src_R16B \
  --upload-same setpath \
  --run -+- ifup gbe1 -+- \
  --run -+- ifconfig -a -+- \
  --run -+- groupadd nogroup -+- \
  --upload tilesudoers /etc/sudoers \
  --run -+- ifconfig xgbe2 0.0.0.0 promisc up -+- \
  --run -+- ifconfig xgbe3 0.0.0.0 promisc up -+- \
  --run -+- ifconfig xgbe4 0.0.0.0 promisc up -+- \
```
There are 2 files associated with the above script.  The contents of the same are:
```bash
# more setpath 
PATH=/usr/local/src/erlang/R16B-tile/bin:$PATH
# 

# more tilesudoers

# Defaults    requiretty
Defaults   !visiblepw
Defaults    always_set_home

Defaults    env_reset
Defaults    env_keep =  "COLORS DISPLAY HOSTNAME HISTSIZE INPUTRC KDEDIR LS_COLORS"
Defaults    env_keep += "MAIL PS1 PS2 QTDIR USERNAME LANG LC_ADDRESS LC_CTYPE"
Defaults    env_keep += "LC_COLLATE LC_IDENTIFICATION LC_MEASUREMENT LC_MESSAGES"
Defaults    env_keep += "LC_MONETARY LC_NAME LC_NUMERIC LC_PAPER LC_TELEPHONE"
Defaults    env_keep += "LC_TIME LC_ALL LANGUAGE LINGUAS _XKB_CHARSET XAUTHORITY"
Defaults    secure_path = /sbin:/bin:/usr/sbin:/usr/bin
root    ALL=(ALL)       ALL


```
Now, compile Erlang. (Note the use of –-prefix which tells configuration to install the final binaries in that directory)
```bash
# LANG=C; export LANG
# ./configure --prefix=/usr/local/src/erlang/R16B --build=x86_64-unknown-linux-gnu
# make clean
# make
# make install
```
Run the built Erlang binary to test:
```Erlang
# /usr/local/src/erlang/R16B/bin/erl
Erlang R16B (erts-5.10.1) [source] [64-bit] [smp:8:8] [async-threads:10] [hipe] [kernel-poll:false]

Eshell V5.10.1  (abort with ^G)
1> 50*25.
1250
2> q().
ok
#
```

Now, we are ready to setup LINC.
```bash
#  mkdir –p /usr/local/src/linc
#  cd /usr/local/src/linc
#  git clone https://github.com/FlowForwarding/LINC-Switch
#  LINC_ROOT=/usr/local/src/linc/LINC-Switch/; cd $LINC_ROOT
#  make compile
   (Modify  and save $LINC_ROOT/rel/files/sys.config – to suit your switch capability needs. OpenFlow 1.3.1 mode is selected.)
#  make rel
```
Now we are ready to run LINC
```bash
# $LINC_ROOT/rel/linc/bin/linc console
```
Open another Terminal window and login to the host that is running the OpenFlow Controller  - *“Controller Window”*.

*_Assumption_*: Ryu Controller is installed in RYU_ROOT directory.  OpenFlow v1.3.1 based Flow Learning Ryu module is available @ $LINC_ROOT/scripts/ryu/l2_switch_v1_3.py.
```bash
# RYU_ROOT=/usr/local/src/ryu; export RYU_ROOT
# cp $LINC_ROOT/scripts/ryu/l2_switch_v1_3.py $RYU_ROOT/
```
Start the OF-Controller
```bash
#  $RYU_ROOT/bin/ryu-manager --verbose l2_switch_v1_3.py 
```


