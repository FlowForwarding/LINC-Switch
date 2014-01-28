# Packet capture in LINC-Switch #

LINC-Switch uses different dependencies for capturing packets from interfaces.
[epcap](https://github.com/esl/epcap) is used when packets are read from hardware
and [tunctl](https://github.com/msantos/tunctl) when dealing with TUN/TAP
interfaces.

1. [epcap](#epcap)
  1. [Enabling logging](#enabling-logging)
  1. [Performance tuning](#performance-tuning)

## epcap ##

epcap is an Erlang API to pcap. To make LINC-Switch capable of dealing with
bursty traffic some customization to pcap may be required as the capture library
can drop packets.

### Enabling logging  ###

epcap can read statistics from pcap. They show number of received packets
and how much of them is dropped. By default the statistics are printed every
5 seconds. This can be adjusted by setting `stats_interval` option to desired
value (in seconds). To enable logging and printing the statistics every 10
seconds use the following configuration in `$LINC_ROOT/rel/files/sys.config`:

```
[
...
    {epcap, [{verbose, true},
             {stats_interval, 10}]},
...
].
```

> **NOTE:** The `stats_interval` option has effect **only** if verbose mode for
epcap is enabled.  
> **NOTE**: Any changes in the configuration file have an effect after
re-generating the release.


In verbose mode epcap prints log messages to:
* `$LINC_ROOT/rel/linc/log/erlang.log.N`, as described in
[run_erl documentation](http://www.erlang.org/doc/man/run_erl.html) under "Notes
concerning the log files" chapter, when ran as daemon:  
`$LINC_ROOT/rel/linc/bin/linc start`

* the LINC-Switch node's console when run in a console mode:  
`$LINC_ROOT/rel/linc/bin/linc console`

* to any file when started in console mode with stderr redirected to the file:
`$LINC_ROOT/rel/linc/bin/linc console 2> tmp.log`.

### Performance tuning ###

#### Adjusting pcap buffer size ####

The first step to improve performance in terms of packet capture is to increase
internal pcap buffer size. To get more information on the buffer look at the
[link](http://www.tcpdump.org/manpages/pcap.3pcap.html) and read the description
of `buffer_size` option.

To manipulate the buffer size adjust an option in
`$LINC_ROOT/rel/files/sys.config`:
```erlang
[
...
    {epcap, [...
             {buffer_size, 73400320}
            ]},
...
],
```
The value is in bytes. To confirm that pcap accepted the value enable epcap
logging, as described in the previous chapter, and look for the following entry
in the logs:
> [epcap]: pcap buffer size set to 73400320 bytes"

#### Building the newest pcap library ####

In our tests "cutting-edge" version of pcap was dropping about 15% less packets
than the stable release. Thus building pcap from sources can result
in performance gain. Here's an instruction on how to build the library on
[OpenSuse LINC appliance](http://susestudio.com/a/ENQFFD/fflinc-1_2):

1. Install required dependencies:  
`$> zypper install flex byacc bison`

1. Clone the repository:  
`$> git clone https://github.com/the-tcpdump-group/libpcap.git`

1. Enter the directory, configure and build:  

        $> cd libpcap
        $> ./configure
        $> make && make install

1. Create necessary links and cache to the most recent shared libraries
in the system:  
`$> ldconfig`

1. Make sure that the library is installed. There should be an entry pointing to
`/usr/local/<SOME_PATH>`:  
`$> ldconfig -p | grep pcap`

1. Make sure that the compiled epcap program uses the library identified in
the previous step (NOTE: LINC-Switch has to be compiled first):  

        $> cd /usr/local/src/ofswitch/LINC-Switch/deps/epcap  
        $> ldd priv/epcap | grep pcap

#### Tested settings ####

The tests were performed on a
[dedicated SDN hardware](http://www.portwell.com/openflow/). The LINC-Switch was
configured so that traffic was simply passed between two ports. With buffer size
of 70*1024*1024 bytes (70 MB) and the "cutting-edge" version of pcap no packets
were dropped when the traffic was flowing at the speed of 100 Mbits/s.
