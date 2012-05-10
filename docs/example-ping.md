Ping example
============

## Setup

To run a simple ping (ICMP Echo Request) demonstration we need to setup the environment first.

We make sure the project is compiled.

    % make

Next we prepare the components to be used in the demo. The order is important if we don't want to see any errors. All the commands should be run from the root directory of the repository (`$HOME/openflow` on Amazon).

### Controller mock

First we start a simple mock of the OpenFlow Controller. It doesn't understand messages it's getting but we can connect to it from the Switch and use it to send messages to modify the flow table entries.

To start the controller we execute the Erlang shell,

    % erl -pa apps/*/ebin deps/*/ebin

Compile the controller,

    (controller)1> c("apps/of_switch/test/of_controller.erl").

Load records needed to send OpenFlow Protocol messages to the Switch,

    (controller)2> rr(of_protocol).

And actually start the Controller on port 6633.

    (controller)3> of_controller:start(6633).

### OpenFlow Switch

When the Controller is running we can start our Erlang OpenFlow Switch implementation.

We edit the `rel/files/sys.config` file, which contains the Switch configuration and check if the Controller (`localhost:6633`) and two ports (`tap0` and `tap1`) are specified and uncommented.

    {of_switch,
     [
      {controllers, [
                     {"localhost", 6633}
                    ]},
      {ports, [
               [{ofs_port_num, 1}, {interface, "tap0"}, {ip, "10.0.0.1"}],
               [{ofs_port_num, 2}, {interface, "tap1"}, {ip, "10.0.0.2"}],
              ]}
     ]},
     ...
    
We build and run the switch (we need `sudo` to create the ports).

    % make rel
    % sudo rel/openflow/bin/openflow console

The switch automatically connects to the controller which accepts the connection.

    =INFO REPORT==== xx-Apr-2012::xx:xx:xx ===
    Accepted connection from #Port<0.xxxx> {{127,0,0,1},xxxxx}

Additionally we can see that `tap0` and `tap1` interfaces were created in the system.

    % ifconfig

Erlang representation of those ports are stored in `ofs_ports` ets table.

    (switch)1> ets:tab2list(ofs_ports).

### Receiving port

On the receiving port (`tap1`) we run `tcpdump` to watch for pong (ICMP Echo Reply).

    % tcpdump -v -i tap1

## Demo

### Part 1: Dropping the packet

Without any input from the Controller all the packets received by the Switch are dropped as the first table has no flow entires to match on.

    (switch)2> ets:lookup(flow_tables, 0).
    [{flow_table,0,[],drop}]

When we send a single ping on `tap0` using `tcpreplay`...

    % tcpreplay -i tap0 pcap.data/ping.pcap

...we're getting nothing on the receiving (`tap1`) port.

### Part 2: Adding a flow, forwarding the packet

We create a `flow_mod` message containing a match field (match on packets received from port 1) and an action (send matched packets to port 2).

    (controller)4> FlowMod = #ofp_message{
                                experimental = true,
                                version = 3,
                                xid = 100,
                                body = #ofp_flow_mod{
                                          cookie = <<0:64>>,
                                          cookie_mask = <<0:64>>,
                                          table_id = 0,
                                          command = add,
                                          idle_timeout = 30000,
                                          hard_timeout = 60000,
                                          priority = 1,
                                          buffer_id = 1,
                                          out_port = 3,
                                          out_group = 5,
                                          flags = [],
                                          match = #ofp_match{
                                                     type = oxm,
                                                     oxm_fields = [#ofp_field{
                                                                      class = openflow_basic,
                                                                      field = in_port,
                                                                      has_mask = false,
                                                                      value = <<1:32>>}]},
                                          instructions = [#ofp_instruction_write_actions{
                                                             actions = [#ofp_action_output{
                                                                           port = 2,
                                                                           max_len = 64}]}]}}.

We send it to the switch.

    (controller)5> of_controller:send(FlowMod).

We can take a look at the flow table `0` now to see it contains one flow entry received from the Controller.

    (switch)3> ets:lookup(flow_tables, 0).
    [{flow_table,0,
                 [{flow_entry,1,
                              {ofp_match,oxm,
                                     [{ofp_field,openflow_basic,in_port,false,
                                                 <<0,0,0,1>>,
                                                 undefined}]},
                              [{ofp_instruction_write_actions,[{ofp_action_output,14,2,64}]}]}],
                 drop}]

Now when we send the same ping packet using `tcpreplay`...

    % tcpreplay -i tap0 pcap.data/ping.pcap

...it will match on the added flow entry and forwarded to port 2. The output of `tcpdump` should look like this:

    xx:xx:xx.xxxxxx IP (tos 0x0, ttl 64, id 39324, offset 0, flags [none], proto ICMP (1), length 84, bad cksum 0 (->72be)!)
    ip-10-152-0-118.ec2.internal > sg1.any.onet.pl: ICMP echo request, id 12814, seq 0, length 64

### Part 3: Removing all flows, dropping the packet again

We create another `flow_mod` message - this time we want to remove all the flow entires from the flow table `0`.

    (controller)6> RemoveFlows = #ofp_message{
                                    experimental = true,
                                    version = 3,
                                    xid = 200,
                                    body = #ofp_flow_mod{
                                              cookie = <<0:64>>,
                                              cookie_mask = <<0:64>>,
                                              table_id = 0,
                                              command = delete,
                                              idle_timeout = 30000,
                                              hard_timeout = 60000,
                                              priority = 1,
                                              buffer_id = 1,
                                              out_port = 3,
                                              out_group = 5,
                                              flags = [],
                                              match = #ofp_match{
                                                         type = oxm,
                                                         oxm_fields = []},
                                              instructions = []}}.

We send it to the Switch.

    (controller)7> of_controller:send(RemoveFlows).

We can check if the flow entry we added earlier is gone from the flow table `0`.

    (switch)4> ets:lookup(flow_tables, 0).
    [{flow_table,0,[],drop}]

We send the ping packet again...

    % tcpreplay -i tap0 pcap.data/ping.pcap

...and we should not get anything in `tcpdump` on port 2.
