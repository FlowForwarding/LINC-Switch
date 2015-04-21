**Table of Contents**

- [Quick Start](#quick-start)
- [LINC-Switch Erlang apps](#linc-switch-erlang-apps)
- [LINC-Switch main dependencies](#linc-switch-main-dependencies)
- [LINC-Switch tests](#linc-switch-tests)
- [LINC-Switch supervision tree](#linc-switch-supervision-tree)
- [Backends](#backends)
    - [LINC-OE: OpenFlow 1.3 with OE](#linc-oe-openflow-13-with-oe)
- [LINC-Switch packet processing pipeline](#linc-switch-packet-processing-pipeline)
- [LINC-Switch OpenFlow messages processing](#linc-switch-openflow-messages-processing)
        

## Quick Start ##

* [The architecture overview](https://github.com/FlowForwarding/LINC-Switch/blob/master/docs/LINC_Switch_Quick_Start_Guide.pdf)

* [LINC poster with architecture overview](https://github.com/FlowForwarding/incubation/blob/master/papers_presos/FlowForwarding-LINC-poster-final.pdf)

* [Optical Extension description](https://github.com/FlowForwarding/LINC-Switch/blob/master/docs/optical_extension.md)

* [Dealing with packets explanation](https://github.com/FlowForwarding/LINC-Switch/blob/master/docs/packet_capture.md)

* [Configuration (sys.config file) explained](https://github.com/FlowForwarding/LINC-Switch/blob/master/rel/files/sys.config.orig)

* [LINC-Environment to quickly get started and undetstand how the LINC integrates with the OS](https://github.com/FlowForwarding/LINC-Environment)

## LINC-Switch Erlang apps ##

In the LINC-Switch repository there are 5 [applications](https://github.com/FlowForwarding/LINC-Switch/tree/master/apps):

1. linc

    1. it is always started and provides the root supervisor for the whole application

    2. passes messages between a controller and backends 

    3. implements interface for OF-Config

    4. prepares configuration for the backends

2. Backend applications for specific OpenFlow versions. 

    5. `linc_us3` - backend for OpenFlow 1.2 (wire protocol 0x03)

    6. `linc_us4` - backend for OpenFlow 1.3 (wire protocol 0x04)

    7. ``linc_us4`_oe` - backend for OpenFlow 1.3 with Optical Extensions (wire protocol 0x04)

    8. `linc_us5` - backend for OpenFlow 1.4 (wire protocol 0x05)

## LINC-Switch main dependencies ##

1. [of_protocol](https://github.com/FlowForwarding/of_protocol.git)
an Erlang library for encoding/decoding OpenFlow messages as well
as OpenFlow client

2. [epcap](https://github.com/esl/epcap.git) an Erlang application for
reading packets for eth interfaces

3. [tunctl](https://github.com/msantos/tunctl.git) an Erlang
application for managing TUN/TAP interfaces

4. [procket](https://github.com/msantos/procket) an Erlang library for
socket creation and manipulation

5. [pkt](https://github.com/esl/pkt) an Erlang network protocol library.

## LINC-Switch tests ##

Each backend as well as the linc application have its unit tests.
They can be run using make targets. Each backend target runs tests for
the linc application too:

`make test` (for the newest backend: `linc_us5`)

`make test_us4`

`make test_us4_oe`

`make test_us3` (not all are passing)

## LINC-Switch supervision tree ##

TODO

## Backends ##

### LINC-OE: OpenFlow 1.3 with OE ###

`OE` stands for Optical Extension. It is used for simulating multiple
optical switches [(ROADMs)][ROADM] that are emulated by a number of
Logical Switches running within one LINC-Switch node.
Each Logical Switch is started by `linc_capable_sup` module.
It is also the top supervisor of the whole LINC-Switch application.

##### Emulated optical ports #####

All the other backends read/write packets to either ethernet ports or
TUN/TAP ones via appropriate libraries mentioned in the
[dependencies](#linc-switch-main-dependencies) section. The `linc_us4_oe`
backend introduces emulated optical port. It is entirely
implemented in LINC in the `linc_us4_oe_optical_native` module.

The `linc_us4_oe_optical_native` is a gen_fsm, and it provides a custom
protocol between a pair of optical ports belonging to different
Logical Switches so that they can communicate
their state (link_up, link_down, port_up, port_down). `linc_oe` provides
an API for getting pids of emulated optical ports based on `SwitchId` and `PortNo`
(`PorNo` is unique per Logical Switch).

In a LINC-Switch that emulates the optical network, one can distinguish
two port's types: **T-Port** or **W-Port**. T-Port connects a packet
network to the switch and converts data to optical signals. Signals
are transmitted with a specified wavelength. In LINC, the medium conversion
is emulated by adding additional header to the packet representation.
Such a header contains information on wavelength of a signal called *lambda*.
A T-Port in LINC adds or removes this header. The W-Port connects two
optical ports.

![LINC-Switch emulated optical ports](img/optical-ports.png)

The messages carrying emulated optical signals
are sent directly to the processes representing OpenFlow ports.
These are implemented via `linc_us4_oe_port` module. Note,
that this module represents the OpenFlow port regardless of the underlying
*physical port* (eth, TUN/TAP, optical). Each OpenFlow port process is
a gen_server. It receives packets in `handle_info/2` and sends
them by `send/2`. The messages that emulate optical signals have the
following format:

```erlang
OpticalDataMessage :: {optical_data, Pid, Packet}
Pid :: pid() %% pid of the peer simulated optical port (linc_us4_oe_native_optical)
Packet :: [#och_sigid{} | pkt:packet()]
```
The 3rd and 4th byte of `#och_sig_id.channel_number` field stands for
`lambda`.

##### OpenFlow Extensions #####

LINC-OE requires custom OpenFlow messages. One example
of such a message is a port description request message containing
all the ports in a Logical Switch (eth, optical…). This request is
implemented as an experimenter one and is handled in the
`linc_us4_oe_port:ofp_experimenter_request/1`.
Important thing to note is that the name of the function have to match
the name of the record representing the message in the of_protocol (see
`ofp_v4_encode:encode_body/1` in of_protocol).
The functions in the `linc_us4_oe` are called from the
`linc_logic` module that ties the backend and the OpenFlow client.

To emulate optical signal we add additional header to the packet
representation that carries data of the emulated signal.
The header is represented by the `#och_sigid{}` record:

```erlang
-record(och_sigid, {
          grid_type = <<0:8>> :: binary(),
          channel_spacing = <<0:8>> :: binary(),
          channel_number = <<0:16>> :: binary(),
          spectral_width = <<0:16>> :: binary()
         }).
```

The lambda value that is used for marking optical channels is in the
`channel_number` field. The rest of the fields are ignored in the
current implementation.


###### Set Field Action for Lambda ######

When converting a packet to optical signal a *lambda* value needs to be
assigned to it. For that use *ofp_field* of type *och_sigid*
whose values corresponds to the *och_sigid* record. However in the LINC-OE
context only the *channel_number (lambda)* field is meaningful.
The *och_sigid* field, wrapped
into an experimenter action with Infoblox Experimenter ID can
be used in a Flow Entry that forwards packets from W-Port to T-Port
or between W-Ports (when the *lambda* value has to be changed). The snippet
below shows how to construct *ofp_field* for *och_sigid*. 

```erlang
   Field = #ofp_field{class = openflow_basic,
                      has_mask = false,
                      name = och_sigid,
                      value = <<0:16, (_Lambda = 20):16, 0:16>>},
    SetField = #ofp_action_set_field{field = Field},
    Action1 = #ofp_action_experimenter{experimenter = ?INFOBLOX_EXPERIMENTER,
                                       data = SetField}
```

The *Set Field Action* is actually run in the `linc_us4_oe_packet:set_field/2`,
which adds *och_sigid* header to the packet representation according
to the *ofp_field*. 

###### Matching on Lambda  ######

On a W-Port one can match on the *lambda* value of emulated optical
signal. To match on it, we use the same *ofp_field* as with Set Field
Action with one difference: the class is **INFOBLOX** (Infoblox Vendor Id)
instead of **OPENFLOW_BASIC**. The snippet below shows that:

``` erlang
MatchField = #ofp_field{class = infoblox,
                        has_mask = false,
                        name = och_sigid,
                        value = <<0:16, (_Lambda = 10):16, 0:16>>}
```

###### Optical Port Status ######

The switch uses the experimenter message for sending asynchronous port
status messages for optical transport ports.  The messages are sent
using the same rules as the port status messages.
The body of the message is a *ofp_port_status*  wrapped into an
experimenter message:

```erlang
   P = #ofp_port_v6{port_no     = 1,
                    hw_addr     = <<8,0,39,255,136,50>>,
                    name        = <<"Port1">>,
                    config      = [],
                    state       = [live],
                    properties  = []},
   Body = #ofp_port_status{
             reason = add,
             desc = P},
   Msg = #ofp_message{version = 4,
                      type = experimenter,
                      xid = 12345,
                      body = #ofp_experimenter{
                                experimenter = ?INFOBLOX_EXPERIMENTER,
                                exp_type     = port_status,
                                data         = Body}},
```


###### Optial Port Description ######

Controllers request the optical transport port descriptions using
experimenter multipart request with **INFOBLOX_EXPERIMENTER** experimenter id
and *exp_type* set to *port_desc*.

```erlang
#ofp_experimenter_request{experimenter = ?INFOBLOX_EXPERIMENTER,
                          exp_type = port_desc,
                          data = <<>>}.
```

The switch responds with an experimenter multipart reply
with the list of extended port descriptions.  The response includes
all the ports on the switch - T-Ports and W-Ports.
The switch’s response to a regular port description request
(not the experimenter one) does not include the optical transport ports.
Below is the experimenter multipart response with port descriptions.

```erlang
 V = [#ofp_port_optical_transport_layer_entry{
            layer_class = port,
            signal_type = otsn,
            adaptation  = ots_oms},
         #ofp_port_optical_transport_layer_entry{
            layer_class = och,
            signal_type = fix_grid,
            adaptation  = oduk_oduij}],
    F = [#ofp_port_optical_transport_application_code{
            feature_type    = opt_interface_class,
            oic_type        = proprietary,
            app_code        = <<"arbitrary">>},
         #ofp_port_optical_transport_layer_stack{
            feature_type    = layer_stack,
            value           = V}],
    Pr = [#ofp_port_desc_prop_optical_transport {
            type                = optical_transport,
            port_signal_type    = otsn,
            reserved            = 0,
            features            = F}],
    Data = [#ofp_port_v6{
               port_no     = 1,
               hw_addr     = <<8,0,39,255,136,50>>,
               name        = <<"Port1">>,
               config      = [],
               state       = [live],
               properties  = Pr,
               is_optical = false}],
    Msg = #ofp_message{
             version = 4,
             type = multipart_reply,
             xid = 1,
             body = #ofp_experimenter_reply{
                       experimenter    = ?INFOBLOX_EXPERIMENTER,
                       exp_type        = port_desc,
                       data            = Data}},
```

## LINC-Switch packet processing pipeline ##

1. Receiving packets

    1. packets are received as Erlang messages and handled in
    `linc_us4_port:handle_info/2`. Depending on the underlying port
    backend (TUN/TAP, eth, optical) the messages have different formats;

    2. based on the port configuration and state (`ofp_port_{config,state}`)
    a packet can be dropped;

    3. if the packet is not dropped it is transformed into the Erlang
    term for easier processing (`linc_us4_packet:binary_to_record/3`);

    4. next the packet is passed to the routing module (by default
    routing takes places in the same process in which the packet had
    been received in the `linc_us4_port` but it is also possible to
    spawn a process for each packet - however it can cause problems)

2. Routing packets

    5. is handled in `linc_us4_routing` module and starts from flow
    table no 0

    6. a packet is matched against flow entries from appropriate flow
    table; flow entries are kept in the ETS tables - the `linc_us4_flow`
    provides an interface for managing flow entries (and flow tables)

    7. if a flow entry matches a packet its instructions are applied
    to the packet (via `linc_us4_instructions:apply/2`)

        1. as a result, actions from *Apply-Actions* instruction *(Action List)*
p        or from an *Action Set* can be applied to the packet
        (`linc_us4_actions:apply_set/1` or `linc_us4_actions:apply_list/2`)

        2. also actions from a group’s bucket can be applied
        (`linc_us4_groups` module)

        3. as a result of applying actions, packet can be sent to
        another OpenFlow Port or to a controller

3. Sending packets

    8. packets are sent out the switch via `linc_us4_port:send/2` to:

        4. another OpenFlow port (handled in `linc_us4_port:handle_cast/2`)

        5. flooded to all ports

        6. a controller (packet_in message)

    9. a packet that is to be sent out through an OpenFlow port can be
    sent through a queue via `linc_us4_queue:send/4`

        7. before the packet is sent it is encapsulated by `pkt:encapsulate/1`

        8. before the packet is sent the port is checked whether its
        configuration allows for sending packets

The diagram below illustrates packet processing pipeline:

![LINC-Switch packet processing pipeline](img/packet-processing-pipeline.png)

## LINC-Switch OpenFlow messages processing ##

1. Passing OpenFlow messages to a backend

    1. OpenFlow messages are received and decoded in a process running
    `ofp_client` module (`of_protocol` dependency)

    2. decoded OF messages are sent to the process running the `linc_logic`
    module that passes them to the appropriate backend in the `handle_info/2`

    3. if the backed returns a reply (or replies) they are sent back to
    the `ofp_client` process via `ofp_channel:send/3`;
    the client encodes them and sends to the controller

2. Handling OpenFlow messages by a backend

    4. the backend module is kept in the state of the `linc_logic`
    process and for each OpenFlow messages received from the OF client
    `BackendModule:handle_message/2` is called

    5. the backend module has functions dedicated for each type of an
    OF message which names match the record names of the messages

[ROADM]: http://en.wikipedia.org/wiki/Reconfigurable_optical_add-drop_multiplexer
