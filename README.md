LINC - OpenFlow software switch
===============================

What is LINC?
=============

LINC is a pure OpenFlow switch written in Erlang. It's implemented in operating system's userspace as an Erlang node. Such approach is not the most efficient one, compared to [Open vSwitch][ovs] implemented in Linux kernel, or pure hardware implementations of traditional switches, but it gives a lot of flexibility and allows quick deployments and tests of new OpenFlow features.

Features
========

 * Full support for [OpenFlow Protocol 1.2][ofp3],
 * Backward compatibility with [OpenFlow Protocol 1.0][ofp1],
 * Modular architecture, easily extensible,
 * Very high test coverage thanks to property based testing.

Planned features
----------------

 * Support for [OF-Config 1.0][ofc1] and/or [OF-Config 1.1][ofc2] management protocols,
 * Support for [OpenFlow Protocol 1.3][ofp4],
 * Backward compatibility with [OpenFlow Protocol 1.1][ofp2],
 * Alternative switching backends (kernel space or hardware).

How to use it?
==============

Erlang
------

To use LINC you need to have an Erlang runtime installed on your machine. Required version is **R15B**.

### Install from sources

To build Erlang from sources first you have to install some required system packages.

On Ubuntu:

    # apt-get install autoconf openssl libssl0.9.8 libssl-dev libncurses5 libncurses5-dev

On other Linux systems you need to install the counterparts of above package.

When your system environment is ready download the sources from [erlang.org][erlang-src]. Unpack, compile and install:

    % ./configure
    % make
    # make install

### Install from binaries

If you're lazy you can also use [Erlang binary packages][erlang-bin] created by [Erlang Solutions][esl].

LINC
----

To build the switch you need to install the following additional libraries and tools.

On Ubuntu:

    # apt-get install libpcap0.8 libpcap-dev uml-utilities libcap2-bin

On other Linux systems you need to install the counterparts of above package.

When your environment is set up you are ready to build and run LINC.

Clone this git repository:

    % git clone <REPO>
    
Compile everything:

    % make

Generate an Erlang release:

    % make rel

Adjust switch configuration by editing the `rel/openflow/release/0.1/sys.config` file which looks like this:

    {of_switch, [
                 {controllers, [
                                {"localhost", 6633},
                                ...
                               ]},
                 {ports, [
                          [{ofs_port_no, 0}, {interface, "eth0"}],
                          [{ofs_port_no, 1}, {interface, "eth1"}],
                          ...
                         ]}
                ]}

At the moment you can change the list of controllers and ports used by the switch.

Start LINC switch in `console` mode:

    % rel/openflow/bin/openflow console

For further instructions on how to use LINC check the "[Ping example](docs/example-ping.md)".

Read more...
============

 * About the [gen_switch behaviour](docs/gen_switch.md) and how to implement a backend.

Support
=======

If you have any technical questions, problems or suggestions regarding LINC please contact <openflow@erlang-solutions.com>.

 [ovs]: http://openvswitch.org
 [ofp1]: https://www.opennetworking.org/images/stories/downloads/openflow/openflow-spec-v1.0.0.pdf
 [ofp2]: https://www.opennetworking.org/images/stories/downloads/openflow/openflow-spec-v1.1.0.pdf
 [ofp3]: https://www.opennetworking.org/images/stories/downloads/openflow/openflow-spec-v1.2.pdf
 [ofp4]: https://www.opennetworking.org/images/stories/downloads/openflow/openflow-spec-v1.3.0.pdf
 [ofc1]: https://www.opennetworking.org/images/stories/downloads/openflow/OF-Config1dot0-final.pdf
 [ofc2]: https://www.opennetworking.org/images/stories/downloads/openflow/OF-Config-1.1.pdf
 [erlang-src]: http://www.erlang.org/download.html
 [erlang-bin]: http://www.erlang-solutions.com/section/132/download-erlang-otp
 [esl]: http://www.erlang-solutions.com