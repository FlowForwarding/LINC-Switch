# Packet capture in LINC-Switch #

LINC-Switch uses different dependencies for capturing packets from interfaces.
[epcap](https://github.com/esl/epcap) is used when packets are read from hardware
and [tunctl](https://github.com/msantos/tunctl) when dealing with TUN/TAP
interfaces.

## epcap ##

epcap is an Erlang API to libpcap. To make LINC-Switch capable of dealing with
bursty traffic some customization to libpcap may be required as it can drop
packets.

### Enabling logging  ###

epcap can read statistics from pcap. They show number of received packets
and how much of them is dropped. By default the statistics are printed every
5 seconds. This can be adjusted by setting `stats_interval` option to desired
value (in seconds). To enable logging and printing the statistics every 10
seconds use the following configuration in `$LINC_ROOT/rel/files/sys.config`:

```
>>>>>>> c326766... Stats interval tmp
[
...
    {epcap, [{verbose, true},
             {stats_interval, 10}]},
...
],
```

> **NOTE:** The `stats_interval` option has effect **only** if verbose mode for
epcap is enabled.  
> **NOTE**: Any changes in the configuration file have an effect after
re-generating the release.

In verbose mode epcap prints log messages to:
* `$LINC_ROOT/rel/linc/log/erlang.log.N`, as described in
[run_erl documentation](http://www.erlang.org/doc/man/run_erl.html) under "Notes
concerning the log files" chapter, when ran as daemon:  
`$LINC_ROOT/rel/linc/bin/linc start`,
* the LINC-Switch node console when run in console mode:  
`$LINC_ROOT/rel/linc/bin/linc console`,
* to any file when started in console mode with stderr redirected to the file:
`$LINC_ROOT/rel/linc/bin/linc console 2> tmp.log`.
