LINC - Open Flow software switch
=========================

Rationale
=========

This project delivers an OF switch implemented in operating system's userspace as an   Erlang node.
Such approach is not the most efficient one, compared to [Open vSwitch](http://openvswitch.org/) implemented in Linux kernel,
or pure hardware implementation of traditional switches, but it gives a lot of flexibility and allows
quick deployments and tests of new OF standards.

***

Features
========

* supports OpenFlow 1.0, 1.1 and 1.2 protocols
* will support [OF-Config 1.0](https://www.opennetworking.org/standards/of-config-10) soon
* modular architecture, easily extensible
* very high test coverage thanks to property based testing

***

Installation
============

Erlang
------
You need to have an Erlang runtime installed on your machine. Required version is **R15B01**. Download the sources from [http://www.erlang.org/download.html](http://www.erlang.org/download.html). Then unpack and compile it with:

    ./configure && make && make install

In order to do so, you need to prepare your OS environment first:

To compile erlang from sources on Linux, following packages must be present:

* autoconf
* openssl
* libssl0.9.8
* libssl-dev
* libncurses5
* libncurses5-dev

other OSes might need their counterparts of above packages.

TAP devices
-----------

By default switch can utilize hardware network interfaces present in the OS as well as virtual network devices provided by [TAP](http://en.wikipedia.org/wiki/TUN/TAP) kernel device. Thanks to this, you can emulate switch witch up to 16 network interfaces on your personal computer with just one NIC.

To use TAP devices you must install following packages first:

* on Linux:
  * libpcap0.8
  * libpcap-dev
  * uml-utilities (tunctl tool)

* on MacOSX:
 * [TunTap driver](http://tuntaposx.sourceforge.net/)
 * [MacPorts](http://www.macports.org)
 * libpcap (after installing MacPorts execute `sudo port install libpcap`)

Network sniffers
----------------

If you want to sniff or alter network traffic then following packages must also be present:

 * tcpdump
 * tcpreplay
 * wireshark

LINC
----

When your environment is set up you can do the following:

* clone this git repo
* alter switch configuration by eding file rel/files/sys.config which looks like:

        [{of_switch,
          [{controllers, [{"localhost", 6633}]},
            {ports, [
                     [{ofs_port_no, 1}, {interface, "en0"}],
                     [{ofs_port_no, 2}, {interface, "tap0"}, {ip, "10.0.0.1"}],
                     [{ofs_port_no, 3}, {interface, "tap1"}, {ip, "10.0.0.2"}]
                    ]}
          ]}
        ].

  * if you don't want to connect to a controller, insert empty list in the `controllers` tuple
  * adjust ports configuration according to your system:
     * hardware ports have already assigned IP address, if you want to change it you must do it outside of LINC switch
     * TAP interfaces are created on demand under Linux and disappear when switch disconnects from them. To make them persistent you can use [tunctl](http://linux.die.net/man/8/tunctl) command from uml-utilities package

* build project by running `make rel` in the top directory
* start LINC switch with `rel/openflow/bin/openflow console`
* execute `tv:start().` in LINC shell to explore in-memory flow tables and other switch data
* run sample ping example as described here: [ping example](docs/example-ping.md)

***

Architecture
============

* of_protocol
* gen_switch behaviour
* of_switch

***

Test suites
===========

* How to run
* Quickcheck
* Eunit
