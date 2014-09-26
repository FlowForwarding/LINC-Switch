# LINC - OpenFlow software switch

## What is LINC?

LINC is a pure OpenFlow software switch written in Erlang. It's implemented in
operating system's userspace as an Erlang node. Such approach is not the most
efficient one, but it gives a lot of flexibility and allows quick development
and testing of new OpenFlow features.

### Features

 * Support for [OpenFlow Protocol 1.2][ofp3], [OpenFlow Protocol 1.3][ofp4],
   and [OpenFlow Protocol 1.4][ofp5],
 * OpenFlow Capable Switch - ability to run multiple logical switches,
 * Support for [OF-Config 1.1.1][ofc11] management protocol,
 * Modular architecture, easily extensible.

## How to use it?

### Erlang

To use LINC you need to have an Erlang runtime installed on your
machine. Required version is **R15B+**.

#### Install from sources

To build Erlang from sources first you have to install some required system
packages.

On Ubuntu:

    # apt-get install gcc wget make autoconf openssl libssl0.9.8 libssl-dev libncurses5 libncurses5-dev

On RedHat/CentOS:

    # yum install gcc wget make autoconf openssl openssl-devel ncurses ncurses-devel

On other Linux systems you need to install the counterparts of aforementioned packages.


When your system environment is ready download the sources from [erlang.org][erlang-src]. Unpack, compile and install:

    % ./configure
    % make
    # make install

#### Install from binaries

If you're lazy you can also use [Erlang binary packages][erlang-bin] created by [Erlang Solutions][esl].

### LINC

To build the switch you need to install the following additional libraries and
tools.

On Ubuntu:

    # apt-get install git-core bridge-utils libpcap0.8 libpcap-dev libcap2-bin uml-utilities

On RedHat/CentOS:

    # yum install git sudo bridge-utils libpcap libpcap-devel libcap tunctl

Note that on RedHat/CentOS 5.x you need a newer version of libpcap:

    # yum erase libpcap libpcap-devel
    # yum install flex byacc
    # wget http://www.tcpdump.org/release/libpcap-1.2.1.tar.gz
    # tar xzf libpcap-1.2.1.tar.gz
    # cd libpcap-1.2.1
    # ./configure
    # make && make install

On other Linux systems you need to install the counterparts of aforementioned packages.

When your environment is set up you are ready to build and run LINC.

Clone this git repository:

    % git clone <REPO>

Compile everything:

    % make

Adjust switch configuration by editing the `rel/linc/releases/0.1/sys.config` file which looks like this:

```erlang
    {linc,
     [
      {of_config, enabled},
      {capable_switch_ports,
       [
        {port, 1, [{interface, "eth0"}]},
        {port, 2, [{interface, "tap0"}]}
       ]},
      {logical_switches,
       [
        {switch, 0,
         [
          {backend, linc_us4},
          {controllers,
           [
            {"Switch0-DefaultController", "localhost", 6633, tcp}
           ]},
          {queues_status, disabled},
          {ports,
           [
            {port, 1, {queues, []}},
            {port, 2, [{queues, []}, {port_no, 10}, {port_name, "Port10"}]}
           ]}
         ]}
       ]}
     ]}.
```

At the moment you can change the list of controllers and ports used by the
switch.

Start LINC switch in `console` mode:

    % rel/linc/bin/linc console

For further instructions on how to use LINC check the
"[Ping example](https://github.com/FlowForwarding/LINC-Switch/tree/master/docs/example-ping.md)".

For detailed explanation on how to setup simple LINC testbed check the
"[Testbed setup](https://github.com/FlowForwarding/LINC-Switch/tree/master/docs/testbed-setup.md)".

## Development environment
To facilitate developing LINC application the appropriate environment was prepared. It consists of the following components:

1. "[Sync](https://github.com/mentels/sync)" - scans all the **beam** files and their corresponding source files and reloads or recompiles them respectively if necessary.
2. "[EDTS](https://github.com/tjarvstrand/edts)" - Emacs mode that among others provides automatic files compilation, finding function declaration etc. For this to work you have to configure your emacs to use EDTS.
3. Makefile targets - start the development Erlang VM.

Assuming that you have Emacs and EDTS installed and properly configured, to start developing LINC you have follow these steps:

1. Clone the repo.
2. Enter the project root dir and issue:
    make dev_prepare
   If you get and error saying "beam.smp executable not found!" follow the guidelines and export the BEAMSMP_PATH variable pointing to your `beam.smp` and run the make target againg.
3. By default only the `procket` module is excluded from scanning by Sync. If you want to prevent additional modules from being scanned modify sync configuration in `rel/files/sys.config` file.
3. Next start the development Erlang VM:
    make dev

Now you can develop the LINC application without restarting the Erlang VM.

## Support

If you have any technical questions, problems or suggestions regarding LINC
please send them to <linc-dev@flowforwarding.org> mailing list or create an
Issue. Thanks.

## Implementation notes

### Flow entry eviction and vacancy

Version 1.4 of the OpenFlow protocol introduced the flow entry
eviction and vacancy event features, which are used to manage limited
space in flow tables.  Since LINC currently doesn't limit the number
of entries in flow tables, it rejects attempts to configure eviction
through table_mod messages, and never sends flow vacancy events.

 [ovs]: http://openvswitch.org
 [ofp1]: https://www.opennetworking.org/images/stories/downloads/specification/openflow-spec-v1.0.0.pdf
 [ofp2]: https://www.opennetworking.org/images/stories/downloads/specification/openflow-spec-v1.1.0.pdf 
 [ofp3]: https://www.opennetworking.org/images/stories/downloads/specification/openflow-spec-v1.2.pdf 
 [ofp4]: https://www.opennetworking.org/images/stories/downloads/specification/openflow-spec-v1.3.0.pdf 
 [ofp5]: https://www.opennetworking.org/images/stories/downloads/sdn-resources/onf-specifications/openflow/openflow-spec-v1.4.0.pdf
 [ofc11]: https://www.opennetworking.org/images/stories/downloads/of-config/of-config-1.1.pdf
 [erlang-src]: http://www.erlang.org/download.html
 [erlang-bin]: http://www.erlang-solutions.com/section/132/download-erlang-otp
 [esl]: http://www.erlang-solutions.com
