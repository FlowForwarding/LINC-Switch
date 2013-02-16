# LINC - OpenFlow software switch

## What is LINC?

LINC is a pure OpenFlow software switch written in Erlang. It's implemented in
operating system's userspace as an Erlang node. Such approach is not the most
efficient one, but it gives a lot of flexibility and allows quick development
and testing of new OpenFlow features.

### Features

 * Support for [OpenFlow Protocol 1.2][ofp3] and [OpenFlow Protocol 1.3][ofp4],
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

    {linc,
     [
      {of_config, enabled},
      {logical_switches,
       [
        {switch, 0,
         [
          {backend, linc_us4},
          {controllers,
           [
            {"Switch0-DefaultController", "localhost", 6633, tcp}
           ]},
          {ports,
           [
            {1, [{interface, "eth0"}]},
            {2, [{interface, "eth1"}]}
           ]}
        ]}
      ]}
    ]}.

At the moment you can change the list of controllers and ports used by the
switch.

Start LINC switch in `console` mode:

    % rel/linc/bin/linc console

For further instructions on how to use LINC check the
"[Ping example](https://github.com/FlowForwarding/LINC-Switch/tree/master/docs/example-ping.md)".

For detailed explanation on how to setup simple LINC testbed check the
"[Testbed setup](https://github.com/FlowForwarding/LINC-Switch/tree/master/docs/testbed-setup.md)".

## Support

If you have any technical questions, problems or suggestions regarding LINC
please send them to <linc-dev@flowforwarding.org> mailing list or create an
Issue. Thanks.

 [ovs]: http://openvswitch.org
 [ofp1]: https://www.opennetworking.org/images/stories/downloads/specification/openflow-spec-v1.0.0.pdf
 [ofp2]: https://www.opennetworking.org/images/stories/downloads/specification/openflow-spec-v1.1.0.pdf 
 [ofp3]: https://www.opennetworking.org/images/stories/downloads/specification/openflow-spec-v1.2.pdf 
 [ofp4]: https://www.opennetworking.org/images/stories/downloads/specification/openflow-spec-v1.3.0.pdf 
 [ofc11]: https://www.opennetworking.org/images/stories/downloads/of-config/of-config-1.1.pdf
 [erlang-src]: http://www.erlang.org/download.html
 [erlang-bin]: http://www.erlang-solutions.com/section/132/download-erlang-otp
 [esl]: http://www.erlang-solutions.com
