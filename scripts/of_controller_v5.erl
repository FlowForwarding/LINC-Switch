%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2012, Erlang Solutions Ltd.
%%% @doc OpenFlow 1.2 Controller.
%%% @end
%%%-----------------------------------------------------------------------------
-module(of_controller_v5).

-compile([{parse_transform, lager_transform}]).

%% API
-export([start/0,
         start/1,
         start_scenario/1,
         start_scenario/2,
         stop/1,
         get_connections/1,
         send/3,
         send/4,
         barrier/2]).

%% Message generators
-export([hello/0,
         flow_mod_issue68/0,
         flow_mod_issue79/0,
         set_config_issue87/0,
         flow_mod_issue90/0,
         flow_mod_table_miss/0,
         flow_mod_delete_all_flows/0,
         get_config_request/0,
         echo_request/0,
         echo_request/1,
         barrier_request/0,
         queue_get_config_request/0,
         features_request/0,
         remove_all_flows/0,
         group_mod/0,
         port_mod/0,
         port_desc_request/0,
         set_config/0,
         role_request/0,
         desc_request/0,
         flow_stats_request/0,
         aggregate_stats_request/0,
         table_stats_request/0,
         port_stats_request/0,
         queue_stats_request/0,
         group_stats_request/0,
         group_desc_request/0,
         group_features_request/0,
         meter_mod_add_meter/0,
         meter_mod_add_meter_17/0,
         meter_mod_modify_meter_17/0,
         config_request_meter_17/0,
         add_meter_19_with_burst_size/0,
         get_stats_meter_19/0,
         flow_mod_with_flags/0,
         set_async/0,
         get_async_request/0,
         bin_port_desc_request/0,
         flow_mod_issue91/0,
         flow_mod_output_to_port/3,
         async_config/3,
         role_request/2,
         flow_mod_issue153/0,
         table_features_keep_table_0/0
         ]).
-export([flow_add/3]).

-include_lib("of_protocol/include/of_protocol.hrl").
-include_lib("of_protocol/include/ofp_v5.hrl").
-include_lib("pkt/include/pkt.hrl").

-record(cstate, {
          parent :: pid(),
          socket,
          parser,
          fwd_table = [] :: [{binary(), integer()}]
         }).

%%%-----------------------------------------------------------------------------
%%% API functions
%%%-----------------------------------------------------------------------------

start() ->
    start_scenario(6653, all_messages).

start(PortOrRemotePeer) ->
    start_scenario(PortOrRemotePeer, all_messages).

start_scenario(Scenario) ->
    start_scenario(6653, Scenario).

start_scenario(PortOrRemotePeer, Scenario) ->
    lager:start(),
    try passive_or_active_controller(PortOrRemotePeer) of
        {passive, Port} ->
            {ok, spawn(fun() ->
                               init(passive, Port, Scenario)
                       end)};
        {active, Address, Port} ->
            {ok, spawn(fun() ->
                               init(active, {Address, Port}, Scenario)
                       end)}
    catch
        error:bad_argument ->
            lager:error("Incorrectly formed RemotePeer argument: ~p",
                        [PortOrRemotePeer]),
            init:stop()
    end.

stop(Pid) ->
    Pid ! stop.

get_connections(Pid) ->
    Pid ! {get_connections, Ref = make_ref(), self()},
    receive
        {connections, Ref, Connections} ->
            {ok, Connections}
    after 1000 ->
            {error, timeout}
    end.

send(Pid, To, Message) ->
    cast(Pid, To, Message).

send(Pid, To, Message, Timeout) ->
    call(Pid, To, Message, Timeout).

barrier(Pid, To) ->
    send(Pid, To, barrier_request(), 1000).

%%%-----------------------------------------------------------------------------
%%% Controller logic
%%%-----------------------------------------------------------------------------

init(passive, Port, Scenario) ->
    Pid = self(),
    spawn_link(fun() ->
                       Opts = [binary, {packet, raw},
                               {active, once}, {reuseaddr, true}],
                       {ok, LSocket} = gen_tcp:listen(Port, Opts),
                       accept(Pid, LSocket, Scenario)
               end),
    loop([], Scenario);
init(active, {Address, Port}, Scenario) ->
    connect(self(), Address, Port, Scenario),
    loop([], Scenario).

accept(Parent, LSocket, Scenario) ->
    {ok, Socket} = gen_tcp:accept(LSocket),
    Pid = spawn_link(fun() ->
                             handle_connection(Parent, Socket, Scenario)
                     end),
    ok = gen_tcp:controlling_process(Socket, Pid),
    Parent ! {connected, passive, Socket, Pid},
    accept(Parent, LSocket, Scenario).

connect(Parent, Address, Port, Scenario) ->
    Opts = [binary, {packet, raw}, {active, once}, {reuseaddr, true}],
    case gen_tcp:connect(Address, Port, Opts) of
        {ok, Socket} ->
            Pid = spawn_link(fun() ->
                                     handle_connection(Parent, Socket, Scenario)
                             end),
            ok = gen_tcp:controlling_process(Socket, Pid),
            Parent ! {connected, active, Socket, Pid};
        {error, Reason} ->
            lager:error("Cannot connect to controller ~p:~p. Reason: ~p.~n",
                        [Address, Port, Reason])
    end.

handle_connection(Parent, Socket, Scenario) ->
    gen_tcp:send(Socket, encoded_hello_message(Scenario)),
    {ok, Parser} = ofp_parser:new(?VERSION),
    inet:setopts(Socket, [{active, once}]),
    handle(#cstate{parent = Parent, socket = Socket, parser = Parser}).


scenario(all_messages) ->
    [flow_mod_table_miss,
     flow_mod_issue68,
     flow_mod_issue79,
     flow_stats_request,
     echo_request,
     features_request,
     get_config_request,
     set_config,
     group_mod,
     port_mod,
     port_desc_request,
     %% table_mod
     %% table_features,
     %% meter_mod,
     %% meter_features,
     %% meter_stats,
     %% meter_config,
     desc_request,
     aggregate_stats_request,
     table_stats_request,
     port_stats_request,
     queue_stats_request,
     group_stats_request,
     group_desc_request,
     group_features_request,
     queue_get_config_request,
     role_request,
     barrier_request,
     set_config_issue87,
     meter_mod_add_meter_17,
     meter_mod_modify_meter_17,
     config_request_meter_17];
scenario(delete_all_flows) ->
    [flow_mod_issue68,
     flow_mod_issue79,
     flow_stats_request,
     flow_mod_delete_all_flows,
     flow_stats_request];
scenario(master_slave) ->
    [get_async_request,
     set_async,
     get_async_request,
     flow_mod_table_miss];
scenario(set_config) ->
    [set_config_issue87,
     get_config_request];
scenario(set_vlan_tag) ->
    [flow_mod_delete_all_flows,
     flow_mod_issue90];
scenario(add_meter) ->
    [meter_mod_add_meter];
scenario(meter_17) ->
    [meter_mod_add_meter_17,
     meter_mod_modify_meter_17,
     config_request_meter_17];
%% Test meter bands with configured burst size.  This scenario creates
%% a meter band that allows 5 packets per second to pass, allowing an
%% initial burst of 10 packets.  It then requests stats for the meter.
%%
%% To test, perform the following steps:
%% 1. Run the scenario once and leave the controller running.
%% 2. Run "tcpreplay -i tap0 --loop 20 --pps 5 ../pcap.data/ping.pcap".
%% 3. Verify that all 20 packets made it through to tap1.
%% 4. Run "tcpreplay -i tap0 --loop 20 --pps 6 ../pcap.data/ping.pcap".
%% 5. Verify that only the first 10 packets made it through to tap1.
%% 6. Run the scenario again and observe the debug output.
%%
%% Ignore this message:
%% {ofp_message,4,error,3105434037,{ofp_error_msg,meter_mod_failed,meter_exists,<<>>}}
%%
%% Look at the meter stats and meter band stats:
%% {ofp_message,4,multipart_reply,4062250353,
%%    {ofp_meter_stats_reply,[],
%%       [{ofp_meter_stats,19,0,40,3920,59,748000,
%%          [{ofp_meter_band_stats,10,980}]}]}}
%%
%% The meter stats should show 40 packets received, and the meter band
%% stats should show 10 packets dropped.
%%
%% The first ping should be sent to the controller as a packet_in
%% message.  The reason field should have the value OFPR_ACTION_SET.
scenario(meter_burst) ->
    [add_meter_19_with_burst_size,
     flow_add([],
              [],
              [{meter, 19},
               {write_actions, [{output, controller, no_buffer}]}]),
     get_stats_meter_19];
scenario(flow_mod_with_flags) ->
    [flow_mod_with_flags,
     flow_stats_request];
scenario(port_desc_request_random_padding) ->
    [bin_port_desc_request];
scenario(ipv6_change_dst) ->
    [flow_mod_delete_all_flows,
     flow_mod_issue91];
scenario(set_ip_ecn_dscp) ->
    [flow_mod_delete_all_flows,
     flow_mod_issue153];

%% The two following scenarios are motivated by issues #97 and #124
%% (https://github.com/FlowForwarding/LINC-Switch/issues/97 and
%% https://github.com/FlowForwarding/LINC-Switch/issues/124 respectively).
%% Each of them start a controller. They should by run one after another
%% from different consoles. The switch should be configured with 3 ports.
%% Scenario for equal controller:
%% 1. Request equal role.
%% 2. Delete all flows.
%% 3. Set asynchronous messages config so that equal/master controller receives
%%    packet ins generated by an action.
%% 4. Set a flow mod that sends traffic from port 1 to 2.
%% 5. Set a flow mod that sends traffic from port 2 to 1.
%% 6. Set a flow mod that generates packet in for traffic received at port 1.
%% 7. Set a flow mod that generates packet in for not matched traffic.
scenario(equal_controller) ->
    [role_request(equal, generation_id()),
     flow_mod_delete_all_flows(),
     async_config({[table_miss], []}, {[], []}, {[], []}),
     flow_add([], [{in_port, <<1:32>>}], [{apply_actions,
                                           [{output,controller,no_buffer},
                                            {output,2, no_buffer}]}]),
     flow_mod_output_to_port(2, 1, undefined),
     flow_mod_table_miss()];
%% Scenario for slave controller:
%% 1. Request slave role.
%% 2. Set asynchronous messages config so that slave controller receives
%%    packet ins generated by a no_match.
scenario(slave_controller) ->
    [role_request(slave, generation_id()),
     async_config({[], [apply_action]}, {[], []}, {[], []})];

%% Scenario motivated by issue #124
%% (https://github.com/FlowForwarding/LINC-Switch/issues/124). It works
%% as follows:
%% 1. Request master role.
%% 2. Delete all flows.
%% 3. Set a flow mod that forwards entire packets received at port no 1 to the
%%    controller without buffering it in the switch.
%% 4. Set asynchronous messages config  on the ofp channel so that a slave
%%    controller receives "packet ins" triggerd by an action.
%% 5. Request slave role.
%% The controller should receive packet ins with the entire packet included
%% for all the packets sent to its port 1.
scenario(port_1_to_slave_controller_all_bytes) ->
    [role_request(master, generation_id()),
     flow_mod_delete_all_flows(),
     flow_mod_output_to_port(1, controller, no_buffer),
     async_config({[], [apply_action]}, {[], []}, {[], []}),
     role_request(slave, generation_id())];

%% Scenario motivated by issue #124
%% (https://github.com/FlowForwarding/LINC-Switch/issues/124). It works
%% as follows:
%% 1. Swtich this controller to equal role.
%% 2. Delete all flows.
%% 3. Set a flow mod that generates packet in for all the packets received
%%    at port 1 and buffer the entire packet in the switch.
%% 4. Set asynchronous messages config on the ofp channel so that a master/equal
%%    controller receives all packet ins.
%% The controller should receive packet ins with NO packet included for all
%% the packets sent to its port 1. The packets referred in packet ins should be
%% buffered by the switch.
scenario(port_1_to_controller_0_bytes) ->
    [role_request(equal, generation_id()),
     flow_mod_delete_all_flows(),
     flow_mod_output_to_port(1, controller,  0),
     async_config({[apply_action], []}, {[], []}, {[], []})];

%% Scenario motivated by issue #124
%% (https://github.com/FlowForwarding/LINC-Switch/issues/124). It works
%% as follows:
%% 1. Reqest  equal role.
%% 2. Delete all flows.
%% 3. Set a flow mod that generates packet in for all the packets received
%%    at port 1 and buffer the packets in the switch. Include 12 bytes
%%    of the buffered packet in the packet in.
%% 4. Set asynchronous messages config on the ofp channel so that a master/equal
%%    controller receives all packet ins.
%% The controller should receive packet ins with 12 bytes of the packet included
%% for all the packets sent to its port 1. The packets referred in packet ins
%% should be buffered by the switch.  The reason field of the packet_in message
%% should be set to OFPR_APPLY_ACTION.
scenario(port_1_to_controller_12_bytes) ->
    [role_request(equal, generation_id()),
     flow_mod_delete_all_flows(),
     flow_mod_output_to_port(1, controller, 12),
     async_config({[apply_action], []}, {[], []}, {[], []})];

%% Scenario motivated by issue #143
%% (https://github.com/FlowForwarding/LINC-Switch/issues/143). It works
%% as follows
%% 1. Request slave role.
%% 2. Request master role with greater generation id.
%% 3. Request equal role whit random generation id.
%% 4. Request nochange  with random generation id (only check the current role).
%% 5. Request master role with smaller generation id.
%% After each of the two first requests the controller should return
%% a generation id that it got in the request. After the two subsequent request
%% the swith should respond with the generation id that id got in the second
%% request. Finally, it should return an error after the last request.
scenario(change_roles) ->
    GenId = generation_id(),
    [role_request(slave, GenId),
     role_request(master, GenId + 1),
     role_request(equal, generation_id()),
     role_request(nochange, generation_id()),
     role_request(master, GenId - 10)];

%% Scenario motivated by issue #142
%% (https://github.com/FlowForwarding/LINC-Switch/issues/142). It sends a flow
%% modification message that tries to add a new flow entry to the switch but has
%% malformed mask in the match. The switch is expected to return an
%% error bad_wildcards.
scenario(bad_match_mask) ->
    [flow_add([],
              [{eth_type, <<16#800:16>>},
               {ipv4_src, <<10,0,0,7>>, <<10,0,0,6>>}],
              [{write_actions,[{output,15,no_buffer}]}])];

%% Scenario motivated by #144
%% (https://github.com/FlowForwarding/LINC-Switch/issues/144). It sends a flow
%% mod that matches on packets incoming on port 1 with MPLS header labeled with
%% value 18 and BoS bit set. The flow mod should make the switch pop the MPLS
%% header, set EtherType of the MPLS payload to IPv4 and forward the packet
%% through the port 2.
%% To make this scenario complete send pcap file pcap.data/mpls.pcap on port 1
%% and verify the output on the port 2.
scenario(pop_mpls) ->
    [flow_add([],
              [{eth_type, <<16#8847:16>>},
               {in_port, <<1:32>>},
               {mpls_label, <<18:20>>},
               {mpls_bos, <<1:1>>}],
              [{apply_actions, [{pop_mpls, 16#0800}]},
               {write_actions, [{output, 2, no_buffer}]}])];

%% Scenario motivated by #146
%% (https://github.com/FlowForwarding/LINC-Switch/issues/146). We
%% create a flow entry in flow table 1, ask for flow table 1 to be
%% deleted, and then verify that the flow entry has been deleted.
%%
%% In the first flow stats response, the flow entry should be listed,
%% but in the second response, it should be gone.
scenario(table_features_delete_flow_entries) ->
    Cookie = <<"flow_del">>,
    [flow_add([{table_id, 1},
               {cookie, Cookie}],
              [],
              [{write_actions, [{output, controller, no_buffer}]}]),
     flow_stats_request_with_cookie(Cookie),
     table_features_keep_table_0,
     flow_stats_request_with_cookie(Cookie)];

%% Scenario motivated by #113
%% (https://github.com/FlowForwarding/LINC-Switch/issues/113).
%%
%% This scenario requests that the switch not send flow_removed
%% messages when a flow entry expires because of a hard timeout, and
%% then creates a flow entry with a hard timeout of 1 second.
%%
%% The expected behaviour is that the switch log should contain a
%% message like the following but no crash reports:
%%
%% Message: ... filtered and not sent through the channel with id: 0
scenario(flow_removed_hard_timeout) ->
    [async_config({[], []},
                  {[], []},
                  %% hard_timeout is not set
                  {[idle_timeout, delete, group_delete],
                   [idle_timeout, delete, group_delete]}),
     flow_add([{hard_timeout, 1},
               {flags, [send_flow_rem]}],
              [],
              [{write_actions, [{output, controller, no_buffer}]}])];

%% Scenario motivated by #134
%% (https://github.com/FlowForwarding/LINC-Switch/issues/134).
%% It sends a flow modification message that should make switch match frames
%% tagged with VID 50 and forward them to port no 2. To verify that this scenario
%% works start the switch with two ports and send prepared packet to the first
%% one using tcpreplay:
%% sudo tcpreplay -i tap0 pcap.data/ping_vlan_50.pcap
%% Using some packet capturing tool (like Wireshark) you should see that this
%% packet will appear on the second port.
scenario(masked_vlan_id) ->
    [flow_mod_delete_all_flows(),
     flow_add([],
              [{vlan_vid, <<(16#32 bor 16#1000):13>>,
                <<(16#32 bor 16#1000):13>>}],
              [{write_actions, [{output, 2, no_buffer}]}])];

%% Scenario motivated by #111
%% (https://github.com/FlowForwarding/LINC-Switch/issues/111).
%%
%% This scenarios sends a flow modification message to the switch that make it
%% change SCTP source port in every packet and forwards it to the port no 2.
%%
%% To run this scenario start switch with two ports (1 and 2). Send pcap file
%% pcap.data/sctp_src_port_32836.pcap on port 1 and verify the output
%% on the other port. The frame going out through the port no 2 should has
%% SCTP source port changed to 32999.
scenario(sctp_src_port_change) ->
    [flow_mod_delete_all_flows(),
     flow_add([],
              [{eth_type, <<(16#0800):16>>},
               %% SCTP payload
               {ip_proto, <<?IPPROTO_SCTP:8>>}],
              [{apply_actions, [{set_field, sctp_src, <<32999:16>>}]},
               {write_actions, [{output, 2, no_buffer}]}])];

%% Scenario motivated by #105
%% (https://github.com/FlowForwarding/LINC-Switch/issues/105).
%%
%% This scenario proves that LINC-Swich accepts several OFP messages that spans
%% one TCP datagram.
scenario(several_messages_in_one_tcp_packet) ->
    [lists:foldr(fun(Message, Acc) ->
                         {ok, EncodedMessage} = of_protocol:encode(Message),
                         <<EncodedMessage/binary, Acc/binary>>
                 end, <<>>, [desc_request(),
                             port_desc_request(),
                             flow_mod_table_miss(),
                             flow_mod_delete_all_flows()])];

%% Scenario motivated by #208
%% (https://github.com/FlowForwarding/LINC-Switch/issues/208).
%%
%% This scenario verifies that all table features property types are correctly
%% encoded (apart from experimenter ones).
scenario(all_table_0_features) ->
    [all_table_features_request(0)];

scenario(table_miss) ->
    [flow_mod_table_miss()];

%% Scenario motivated by #218
%% (https://github.com/FlowForwarding/LINC-Switch/issues/218).
%%
%% This scenario reproduces the error reported in the bug. The correct behavior
%% should be that the switch sends a single packet_in message to a controller
%% each time it receives a packet on port 1. The reason field of the packet_in
%% message should be set to OFPR_GROUP.
scenario(group_with_output_to_controller) ->
    GroupId = 10,
    [flow_mod_delete_all_flows(),
     delete_all_groups(),
     group_mod_add_bucket_with_output_to_controller(GroupId),
     flow_add([],
              [{in_port, <<1:32>>}],
              [{write_actions, [{group, GroupId}]}])];

%% Scenario motivated by #228
%% (https://github.com/FlowForwarding/LINC-Switch/issues/228).
%%
%% This scenario first adds a group that forwards packets to controller and then
%% modifies this group so that packets are forwarded to port 2. Then it sends
%% a flow mod that matches packets on port 1 and applies previously defined group
%% to them.
%%
%% In result packets from port 1 should be sent out through port 2.
scenario(group_mod_modify_group) ->
    GroupId =10,
    [flow_mod_delete_all_flows(),
     delete_all_groups(),
     group_mod_add_bucket_with_output_to_controller(GroupId),
     group_mod_modify_bucket(GroupId),
     flow_add([],
              [{in_port, <<1:32>>}],
              [{write_actions, [{group, GroupId}]}])];

%% This scenario first requests to become master, and then installs a
%% flow entry and waits for packets.  This can be used for testing
%% task #161 (https://github.com/FlowForwarding/LINC-Switch/issues/161):
%% run two controllers using this scenario on separate ports,
%% configure the switch to connect to both controllers, and verify
%% that one controller gets a role_status message demoting it to slave.
scenario(master_controller) ->
    GenId = generation_id(),
    [role_request(master, GenId),
     flow_mod_table_miss()];

scenario(table_desc) ->
    [message(#ofp_table_desc_request{})];

%% This scenario sends a packet to the switch that the switch should
%% send right back to the controller in a packet-in message.  The
%% reason field of the packet-in message should contain OFPR_PACKET_OUT.
scenario(packet_out_plus_packet_in) ->
    ICMPv6 = <<51,51,0,0,0,22,162,253,145,45,205,21,134,221,96,0,
               0,0,0,36,0,1,254,128,0,0,0,0,0,0,160,253,
               145,255,254,45,205,21,255,2,0,0,0,0,0,0,0,0,
               0,0,0,0,0,22,58,0,5,2,0,0,1,0,143,0,
               165,133,0,0,0,1,4,0,0,0,255,2,0,0,0,0,
               0,0,0,0,0,1,255,45,205,21>>,
    [message(#ofp_packet_out{
                buffer_id = no_buffer,
                in_port = controller,
                data = ICMPv6,
                actions = [#ofp_action_output{port = controller}]})];

%% Send table_mod messages to the switch.
%%
%% The first message should be rejected with OFPET_TABLE_MOD_FAILED +
%% OFPTMFC_BAD_CONFIG, since the switch doesn't support flow entry
%% eviction.
%%
%% The second message should be silently accepted.
scenario(table_mod_config) ->
    [message(#ofp_table_mod{table_id = all, config = [eviction]}),
     message(#ofp_table_mod{table_id = all, config = [vacancy_events]})];

scenario(queue_desc) ->
    [message(#ofp_queue_desc_request{port_no = any, queue_id = all})];

%% Testing task #261 (https://github.com/FlowForwarding/LINC-Switch/issues/261):
%% Implement Flow Monitoring 
scenario(flow_monitor) ->
    [message(#ofp_flow_monitor_request{
                flags      = [], 
                monitor_id = 1,
                out_port   = any,
                out_group  = any,
                monitor_flags = [initial, add, removed, modify, 
                                 instructions, no_abbrev, only_own],
                table_id   = 0,
                command    = add,
                match      = #ofp_match{fields = []}
               })];

scenario(bundle) ->
    Cookie1 = <<"cookie01">>,
    Cookie2 = <<"cookie02">>,

    [flow_mod_delete_all_flows(),
     message(#ofp_bundle_add_msg{
                bundle_id = 1,
                message = flow_add(
                            [{table_id, 1},
                             {cookie, Cookie1}],
                            [{eth_type, <<(16#0800):16>>},
                             {ip_proto, <<?IPPROTO_SCTP:8>>}],
                            [{write_actions, [{output, controller, no_buffer}]}])}),
     message(#ofp_bundle_add_msg{
                bundle_id = 1,
                message = flow_add(
                            [{table_id, 1},
                             {cookie, Cookie2}],
                            [{eth_type, <<(16#0800):16>>},
                             {ip_proto, <<?IPPROTO_UDP:8>>}],
                            [{write_actions, [{output, controller, no_buffer}]}])}),
     %% Should be empty so far
     flow_stats_request,
     message(#ofp_bundle_ctrl_msg{bundle_id = 1, type = commit_request}),
     %% Should show two entries
     flow_stats_request];

scenario(bundle_modify) ->
    Cookie1 = <<"cookie01">>,

    [flow_mod_delete_all_flows(),
     flow_add(
       [{table_id, 1},
        {cookie, Cookie1}],
       [{eth_type, <<(16#0800):16>>},
        {ip_proto, <<?IPPROTO_SCTP:8>>}],
       [{write_actions, [{output, controller, no_buffer}]}]),
     %% Should show one entry, outputting to controller
     flow_stats_request,
     message(#ofp_bundle_add_msg{
                bundle_id = 1,
                message = message(ofp_v5_utils:flow_modify(
                                    modify,
                                    [{table_id, 1},
                                     {cookie, Cookie1},
                                     {cookie_mask, <<-1:64>>}],
                                    [],
                                    [{write_actions, [{output, 1, no_buffer}]}]))}),
     %% Should show the same as above
     flow_stats_request,
     message(#ofp_bundle_ctrl_msg{bundle_id = 1, type = commit_request}),
     %% Should show one entry, outputting to port 1
     flow_stats_request];

scenario(bundle_error) ->
    Cookie1 = <<"cookie01">>,
    Cookie2 = <<"cookie02">>,

    [flow_mod_delete_all_flows(),
     message(#ofp_bundle_add_msg{
                bundle_id = 1,
                message = flow_add(
                            [{table_id, 1},
                             {cookie, Cookie1}],
                            [{eth_type, <<(16#0800):16>>},
                             {ip_proto, <<?IPPROTO_SCTP:8>>}],
                            [{write_actions, [{output, controller, no_buffer}]}])}),
     message(#ofp_bundle_add_msg{
                bundle_id = 1,
                message = flow_add(
                            [{table_id, 1},
                             {cookie, Cookie2}],
                            [{eth_type, <<(16#0800):16>>},
                             {ip_proto, <<?IPPROTO_UDP:8>>}],
                            [{write_actions, [{output, controller, no_buffer}]}])}),
     %% Add an invalid flow_mod message at the end of the bundle
     message(#ofp_bundle_add_msg{
                bundle_id = 1,
                message = flow_add(
                            [{table_id, 1}],
                            %% Match packets that are _both_ IPv4 and IPv6 - an
                            %% impossible match.
                            [{eth_type, <<(16#0800):16>>},
                             {eth_type, <<(16#86DD):16>>}],
                            [])}),
     %% Should be empty so far
     flow_stats_request,
     %% This should generate two error messages
     message(#ofp_bundle_ctrl_msg{bundle_id = 1, type = commit_request}),
     %% Should still be empty
     flow_stats_request];

%% Scenario motivated by #322
%% (https://github.com/FlowForwarding/LINC-Switch/issues/322).
%%
%% This is a scenario for testing buffering packets in LINC between ofp_packet_in
%% and ofp_packet_out messages. It sends a flow that generate a ofp_packet_in
%% for every packet. The packets are buffered in the switch.
scenario(forward_to_controller_and_buffer) ->
    [flow_mod_output_to_port(1, controller, 128)];

%% This scenario is empty as hello message is malformed and sent just after
%% the connection is established.
scenario(hello_with_bad_version) ->
    [];
scenario(idle) ->
    [];
scenario(_Unknown) ->
    lager:debug("Unknown controller's scenario. Running `all_messages` one."),
    scenario(all_messages).



loop(Connections, Scenario) ->
    receive
        {connected, Type, Socket, Pid} ->
            {ok, {Address, Port}} = inet:peername(Socket),
            case Type of
                passive ->
                    lager:info("Accepted connection from ~p {~p,~p}",
                               [Socket, Address, Port]);
                active ->
                    lager:info(
                      "Connected to listening switch through ~p {~p,~p}",
                      [Socket, Address, Port])
            end,
            [begin
                 Message = case MsgOrMsgGen of
                               MsgGen when is_atom(MsgGen) ->
                                   ?MODULE:MsgGen();
                               Msg ->
                                   Msg
                           end,
                 timer:sleep(200),
                 do_send(Socket, Message)
             end || MsgOrMsgGen  <- scenario(Scenario)],
            loop([{{Address, Port}, Socket, Pid} | Connections], Scenario);
        {cast, Message, AddressPort} ->
            NewConnections = filter_connections(Connections),
            do_send(NewConnections, AddressPort, Message),
            loop(NewConnections, Scenario);
        {call, wait_for_message, _AddressPort, Ref, ReplyPid, Timeout} ->
            NewConnections = filter_connections(Connections),
            receive
                {message, #ofp_message{xid = 0,
                                       type = Type} = Update} when Type =/= hello ->
                    lager:info("update received: ~p", [Update]),
                    ReplyPid ! {reply, Ref, {update, Update}}
            after Timeout ->
                    ReplyPid ! {reply, Ref, {error, timeout}}
            end,
            loop(NewConnections, Scenario);
        {call, #ofp_message{xid = Xid} = Message,
         AddressPort, Ref, ReplyPid, Timeout} ->
            NewConnections = filter_connections(Connections),
            do_send(NewConnections, AddressPort, Message),
            receive
                {message, #ofp_message{xid = Xid} = Reply} ->
                    ReplyPid ! {reply, Ref, {reply, Reply}};
                {message, #ofp_message{xid = 0,
                                       type = Type} = Update} when Type =/= hello ->
                    lager:info("update received: ~p", [Update]),
                    ReplyPid ! {reply, Ref, {update, Update}}
            after Timeout ->
                    ReplyPid ! {reply, Ref, {error, timeout}}
            end,
            loop(NewConnections, Scenario);
        {get_connections, Ref, Pid} ->
            Pid ! {connections, Ref, [AP || {AP,_,_} <- Connections]},
            loop(Connections, Scenario);
        stop ->
            lager:info("controller ~p stopped", [self()]),
            ok
    end.

handle(#cstate{parent = Parent, socket = Socket,
               parser = Parser, fwd_table = FwdTable} = State) ->
    receive
        {tcp, Socket, Data} ->
            {ok, NewParser} = parse_tcp(Socket, Parser, Data),
            handle(State#cstate{parser = NewParser});
        {tcp_closed, Socket} ->
            lager:info("Socket ~p closed", [Socket]);
        {tcp_error, Socket, Reason} ->
            lager:error("Error on socket ~p: ~p", [Socket, Reason]);
        {msg, Socket, #ofp_message{
                body = #ofp_error_msg{type = hello_failed,
                                  code = incompatible}} = Message} ->
            lager:error("Received hello_failed from ~p: ~p",
                        [Socket, Message]),
            gen_tcp:close(Socket);
        {msg, Socket, #ofp_message{
                body = #ofp_packet_in{buffer_id = BufferId,
                                      %% in_port = InPort,
                                      match = Match,
                                      data = Data}} = Message} ->
            lager:debug("Received packet_in from ~p: ~p", [Socket, Message]),
            try
                [EthHeader | _] = pkt:decapsulate(Data),
                EthSrc = EthHeader#ether.shost,
                EthDst = EthHeader#ether.dhost,
                #ofp_field{value = <<InPort:32>>} = lists:keyfind(in_port, #ofp_field.name,
                                                                  Match#ofp_match.fields),
                NewMatch = #ofp_match{fields = [#ofp_field{name = eth_dst,
                                                               value = EthSrc}]},
                %% ApplyActions = #ofp_instruction_apply_actions{
                %%   actions = [#ofp_action_output{port = controller}]},
                ActionOutput = #ofp_instruction_write_actions{
                  actions = [#ofp_action_output{port = InPort}]},
                case lists:keyfind(EthSrc, 1, FwdTable) of
                    {EthSrc, InPort} ->
                        lager:debug("Already exists: ~p | ~p", [EthSrc, InPort]),
                        NewFwdTable = FwdTable,
                        ok;
                    {EthSrc, OtherPort} ->
                        FlowMod = message(#ofp_flow_mod{table_id = 0,
                                                        command = modify_strict,
                                                        match = NewMatch,
                                                        instructions = [%% ApplyActions,
                                                                        ActionOutput]}),
                        lager:info("Modifying existing entry: ~p | ~p  ->  ~p | ~p", [EthSrc, OtherPort,
                                                                                      EthSrc, InPort]),
                        {ok, EncodedFlowMod} = of_protocol:encode(FlowMod),
                        NewFwdTable = lists:keyreplace(EthSrc, 1, FwdTable, {EthSrc, InPort}),
                        gen_tcp:send(Socket, EncodedFlowMod);
                    false ->
                        FlowMod = message(#ofp_flow_mod{table_id = 0,
                                                        command = add,
                                                        match = NewMatch,
                                                        instructions = [%% ApplyActions,
                                                                        ActionOutput]}),
                        MAC = binary_to_hex(EthSrc),
                        lager:info("Adding new entry: ~2w | ~18s | ~p",
                                   [InPort, MAC, EthSrc]),
                        {ok, EncodedFlowMod} = of_protocol:encode(FlowMod),
                        NewFwdTable = [{EthSrc, InPort} | FwdTable],
                        gen_tcp:send(Socket, EncodedFlowMod)
                end,
                case lists:keymember(EthDst, 1, FwdTable) of
                    true ->
                        ok;
                    false ->
                        OutputToAll = #ofp_action_output{port = all},
                        PacketOut = Message#ofp_message{
                                      body = #ofp_packet_out{buffer_id = BufferId,
                                                             in_port = InPort,
                                                             actions = [OutputToAll],
                                                             data = Data}},
                        lager:debug("Send packet to all ports"),
                        {ok, EncodedPacketOut} = of_protocol:encode(PacketOut),
                        gen_tcp:send(Socket, EncodedPacketOut)
                end,
                %% lager:debug("Forwarding table: ~p", [NewFwdTable]),
                handle(State#cstate{fwd_table = NewFwdTable})
            catch
                E1:E2 ->
                    lager:error("Pkt decapsulate error: ~p:~p", [E1, E2]),
                    lager:error("Probably received malformed frame", []),
                    lager:error("With data: ~p", [Data]),
                    handle(State)
            end;
        {msg, Socket, Message} ->
            lager:info("Received message from ~p: ~p", [Socket, Message]),
            Parent ! {message, Message},
            handle(State)
    end.

binary_to_hex(Bin) ->
    binary_to_hex(Bin, "").

binary_to_hex(<<>>, Result) ->
    Result;
binary_to_hex(<<B:8, Rest/bits>>, Result) ->
    Hex = erlang:integer_to_list(B, 16),
    NewResult = Result ++ ":" ++ Hex,
    binary_to_hex(Rest, NewResult).

%%%-----------------------------------------------------------------------------
%%% Message generators
%%%-----------------------------------------------------------------------------

hello() ->
    message(#ofp_hello{}).

features_request() ->
    message(#ofp_features_request{}).

echo_request() ->
    echo_request(<<>>).
echo_request(Data) ->
    message(#ofp_echo_request{data = Data}).

get_config_request() ->
    message(#ofp_get_config_request{}).

barrier_request() ->
    message(#ofp_barrier_request{}).

queue_get_config_request() ->
    message(#ofp_queue_get_config_request{port = any}).

desc_request() ->
    message(#ofp_desc_request{}).

flow_stats_request() ->
    message(#ofp_flow_stats_request{table_id = all}).

flow_stats_request_with_cookie(Cookie) ->
    message(#ofp_flow_stats_request{table_id = all,
                                    cookie = Cookie,
                                    cookie_mask = <<-1:64>>}).

aggregate_stats_request() ->
    message(#ofp_aggregate_stats_request{table_id = all}).

table_stats_request() ->
    message(#ofp_table_stats_request{}).

port_stats_request() ->
    message(#ofp_port_stats_request{port_no = any}).

queue_stats_request() ->
    message(#ofp_queue_stats_request{port_no = any, queue_id = all}).

group_stats_request() ->
    message(#ofp_group_stats_request{group_id = all}).

group_desc_request() ->
    message(#ofp_group_desc_request{}).

group_features_request() ->
    message(#ofp_group_features_request{}).

remove_all_flows() ->
    message(#ofp_flow_mod{command = delete}).

set_config() ->
    message(#ofp_set_config{miss_send_len = no_buffer}).

group_mod() ->
    message(#ofp_group_mod{
               command  = add,
               type = all,
               group_id = 1,
               buckets = [#ofp_bucket{
                             weight = 1,
                             watch_port = 1,
                             watch_group = 1,
                             actions = [#ofp_action_output{port = 2}]}]}).

port_mod() ->
    message(#ofp_port_mod{port_no = 1,
                          hw_addr = <<0,17,0,0,17,17>>,
                          config = [],
                          mask = [],
                          properties = [#ofp_port_mod_prop_ethernet{
                                           advertise = [fiber]}]}).

group_mod_add_bucket_with_output_to_controller(GroupId) ->
    message(#ofp_group_mod{
               command  = add,
               type = all,
               group_id = GroupId,
               buckets = [#ofp_bucket{
                             actions = [#ofp_action_output{port = controller}]}]
              }).

group_mod_modify_bucket(GroupId) ->
    message(#ofp_group_mod{
               command  = modify,
               type = all,
               group_id = GroupId,
               buckets = [#ofp_bucket{
                             actions = [#ofp_action_output{port = 2}]}]
              }).

delete_all_groups() ->
    message(#ofp_group_mod{
               command = delete,
               type = all,
               group_id = 16#fffffffc
              }).

port_desc_request() ->
    message(#ofp_port_desc_request{}).

role_request() ->
    message(#ofp_role_request{role = nochange, generation_id = 1}).

flow_mod_table_miss() ->
    Action = #ofp_action_output{port = controller},
    Instruction = #ofp_instruction_apply_actions{actions = [Action]},
    message(#ofp_flow_mod{table_id = 0,
                          command = add,
                          priority = 0,
                          instructions = [Instruction]}).

flow_mod_delete_all_flows() ->
    message(#ofp_flow_mod{table_id = all,
                          command = delete}).

%% Flow mod to test behaviour reported in:
%% https://github.com/FlowForwarding/LINC-Switch/issues/68
flow_mod_issue68() ->
    %% Match fields
    MatchField1 = #ofp_field{class = openflow_basic,
                             has_mask = false,
                             name = eth_type,
                             value = <<2048:16>>},
    MatchField2 = #ofp_field{class = openflow_basic,
                             has_mask = false,
                             name = ipv4_src,
                             value = <<192:8,168:8,0:8,68:8>>},
    Match = #ofp_match{fields = [MatchField1, MatchField2]},
    %% Instructions
    SetField = #ofp_field{class = openflow_basic,
                           has_mask = false,
                           name = ipv4_dst,
                           value = <<10:8,0:8,0:8,68:8>>},
    Action1 = #ofp_action_set_field{field = SetField},
    Action2 = #ofp_action_output{port = 2, max_len = no_buffer},
    Instruction = #ofp_instruction_apply_actions{actions = [Action1, Action2]},
    %% Flow Mod
    message(#ofp_flow_mod{
               cookie = <<0:64>>,
               cookie_mask = <<0:64>>,
               table_id = 0,
               command = add,
               idle_timeout = 0,
               hard_timeout = 0,
               priority = 1,
               buffer_id = no_buffer,
               out_port = any,
               out_group = any,
               flags = [],
               match = Match,
               instructions = [Instruction]
              }).

%% Flow mod to test behaviour reported in:
%% https://github.com/FlowForwarding/LINC-Switch/issues/79
flow_mod_issue79() ->
    %% Match fields
    MatchField1 = #ofp_field{class = openflow_basic,
                             has_mask = false,
                             name = eth_type,
                             value = <<2048:16>>},
    MatchField2 = #ofp_field{class = openflow_basic,
                             has_mask = false,
                             name = ip_proto,
                             value = <<6:8>>},
    MatchField3 = #ofp_field{class = openflow_basic,
                             has_mask = false,
                             name = ipv4_src,
                             value = <<192:8,168:8,0:8,79:8>>},
    Match = #ofp_match{fields = [MatchField1, MatchField2, MatchField3]},
    %% Instructions
    SetField = #ofp_field{class = openflow_basic,
                           has_mask = false,
                           name = tcp_dst,
                           value = <<7979:16>>},
    Action1 = #ofp_action_set_field{field = SetField},
    Action2 = #ofp_action_output{port = 2, max_len = no_buffer},
    Instruction = #ofp_instruction_apply_actions{actions = [Action1, Action2]},
    %% Flow Mod
    message(#ofp_flow_mod{
               cookie = <<0:64>>,
               cookie_mask = <<0:64>>,
               table_id = 0,
               command = add,
               idle_timeout = 0,
               hard_timeout = 0,
               priority = 1,
               buffer_id = no_buffer,
               out_port = any,
               out_group = any,
               flags = [],
               match = Match,
               instructions = [Instruction]
              }).

%% Flow mod to test behaviour reported in:
%% https://github.com/FlowForwarding/LINC-Switch/issues/87
set_config_issue87() ->
    message(#ofp_set_config{
               flags = [frag_drop],
               miss_send_len = 16#FFFF - 100}).

%% Flow mod to test behaviour reported in:
%% https://github.com/FlowForwarding/LINC-Switch/issues/90
flow_mod_issue90() ->
    SetField = #ofp_field{class = openflow_basic,
                          has_mask = false,
                          name = vlan_vid,
                          value = <<11:12>>},
    Action1 = #ofp_action_push_vlan{ethertype = 16#8100},
    Action2 = #ofp_action_set_field{field = SetField},
    Action3 = #ofp_action_output{port = 2, max_len = no_buffer},
    Instriction = #ofp_instruction_apply_actions{actions = [Action1,
                                                            Action2,
                                                            Action3]},
    message(#ofp_flow_mod{
               cookie = <<0:64>>,
               cookie_mask = <<0:64>>,
               table_id = 0,
               command = add,
               idle_timeout = 0,
               hard_timeout = 0,
               priority = 1,
               buffer_id = no_buffer,
               out_port = any,
               out_group = any,
               flags = [],
               match = #ofp_match{fields = []},
               instructions = [Instriction]}).

%% Meter mod to test behaviour related with pull request repotred in:
%% https://github.com/FlowForwarding/of_protocol/pull/28
meter_mod_add_meter() ->
    message(#ofp_meter_mod{
               command = add,
               flags = [kbps],
               meter_id = 1,
               bands = [#ofp_meter_band_drop{rate  = 200}]}).

%% Meters' messages to test behaviour related with pull request
%% repotred in: https://github.com/FlowForwarding/of_protocol/pull/23
meter_mod_add_meter_17() ->
    message(#ofp_meter_mod{
               command = add,
               flags = [kbps],
               meter_id = 17,
               bands = [#ofp_meter_band_drop{rate  = 200}]}).

meter_mod_modify_meter_17() ->
    message(#ofp_meter_mod{
               command = modify,
               flags = [kbps],
               meter_id = 17,
               bands = [#ofp_meter_band_drop{rate  = 900}]}).

config_request_meter_17() ->
    message(#ofp_meter_config_request{
               flags = [],
               meter_id = 17}).

add_meter_19_with_burst_size() ->
    message(#ofp_meter_mod{
               command = add,
               flags = [pktps, burst, stats],
               meter_id = 19,
               bands = [#ofp_meter_band_drop{rate = 5, burst_size = 10}]}).

get_stats_meter_19() ->
    message(#ofp_meter_stats_request{meter_id = 19}).

%% Flow mod with flags set to check if they are correctly encoded/decoded.
flow_mod_with_flags() ->
    message(#ofp_flow_mod{
               cookie = <<0:64>>,
               cookie_mask = <<0:64>>,
               table_id = 0,
               command = add,
               idle_timeout = 0,
               hard_timeout = 0,
               priority = 99,
               buffer_id = no_buffer,
               out_port = any,
               out_group = any,
               flags = [send_flow_rem, reset_counts],
               match = #ofp_match{},
               instructions = []
              }).

set_async() ->
    message(#ofp_set_async{
               packet_in_mask = {
                 [no_match],
                 [action]},
               port_status_mask = {
                 [add, delete, modify],
                 [add, delete, modify]},
               flow_removed_mask = {
                 [idle_timeout, hard_timeout, delete, group_delete],
                 [idle_timeout, hard_timeout, delete, group_delete]
                }}).

get_async_request() ->
    message(#ofp_get_async_request{}).

-spec role_request(ofp_controller_role(), integer()) -> ofp_message().
role_request(Role, GenerationId) ->
    message(#ofp_role_request{role = Role, generation_id = GenerationId}).

%% Creates a flow mod message that forwards a packet received at one port
%% to another. If the output port is controller the MaxLen specifies
%% the amount of bytes of the received packet to be included in the packet in.
-spec flow_mod_output_to_port(integer(), ofp_port_no(), ofp_packet_in_bytes())
                             -> ofp_message().
flow_mod_output_to_port(InPort, OutPort, MaxLen) ->
    MatchField = #ofp_field{class = openflow_basic,
                            has_mask = false,
                            name = in_port,
                            value = <<InPort:32>>},
    Match = #ofp_match{fields = [MatchField]},
    Action = case OutPort =:= controller of
                 true ->
                     #ofp_action_output{port = OutPort, max_len = MaxLen};
                 false ->
                     #ofp_action_output{port = OutPort}
             end,
    Instruction = #ofp_instruction_apply_actions{actions = [Action]},
    message(#ofp_flow_mod{
               cookie = <<0:64>>,
               cookie_mask = <<0:64>>,
               table_id = 0,
               command = add,
               idle_timeout = 0,
               hard_timeout = 0,
               priority = 1,
               buffer_id = no_buffer,
               out_port = any,
               out_group = any,
               flags = [],
               match = Match,
               instructions = [Instruction]
              }).

flow_add(Opts, Matches, Instructions) ->
    message(ofp_v5_utils:flow_add(Opts, Matches, Instructions)).

%% Creates async config message that sets up filtering on an ofp channel.
-spec async_config({[ofp_packet_in_reason()], [ofp_packet_in_reason()]},
                   {[ofp_port_status_reason()], [ofp_port_status_reason()]},
                   {[ofp_flow_removed_reason()], [ofp_flow_removed_reason()]}) ->
                          ofp_message().
async_config(PacketInMask, PortStatusMask, FlowRemovedMask) ->
    message(#ofp_set_async{
               packet_in_mask = PacketInMask,
               port_status_mask = PortStatusMask,
               flow_removed_mask = FlowRemovedMask
              }).

%% Binary port description request with 4 byte long random padding to check
%% behaviour reported in:
%% https://github.com/FlowForwarding/LINC-Switch/issues/110
bin_port_desc_request() ->
    {ok, EncodedMessage} = of_protocol:encode(message(#ofp_port_desc_request{})),
    %% Strip for 4 byte padding from the message.
    <<(binary:part(EncodedMessage, 0, byte_size(EncodedMessage) - 4))/binary,
      (random:uniform(16#FFFFFFFF)):32>>.

%% Flow mod to test behaviour reported in:
%% https://github.com/FlowForwarding/LINC-Switch/issues/91
flow_mod_issue91() ->
    MatchField1 = #ofp_field{class = openflow_basic,
                             has_mask = false,
                             name = eth_type,
                             %% IPv6
                             value = <<(16#86dd):16>>},
    MatchField2 = #ofp_field{class = openflow_basic,
                             has_mask = false,
                             name = in_port,
                             value = <<1:32>>},
    Match = #ofp_match{fields = [MatchField1, MatchField2]},
    SetField = #ofp_field{class = openflow_basic,
                          has_mask = false,
                          name = ipv6_dst,
                          value =
                              <<(16#fe80):16, 0:48, (16#2420):16, (16#52ff):16,
                                (16#fe8f):16, (16#5189):16>>},
    Action1 = #ofp_action_set_field{field = SetField},
    Action2 = #ofp_action_output{port = 2, max_len = no_buffer},
    Instruction = #ofp_instruction_apply_actions{actions = [Action1, Action2]},
    message(#ofp_flow_mod{
               cookie = <<0:64>>,
               cookie_mask = <<0:64>>,
               table_id = 0,
               command = add,
               idle_timeout = 0,
               hard_timeout = 0,
               priority = 1,
               buffer_id = no_buffer,
               out_port = any,
               out_group = any,
               flags = [],
               match = Match,
               instructions = [Instruction]
              }).

%% Flow mod to test behaviour reported in:
%% https://github.com/FlowForwarding/LINC-Switch/issues/153
%%
%% This should set the ECN field for any IPv4 packet to 2 (binary 10),
%% and the DSCP field to 10 (binary 001010).
flow_mod_issue153() ->
    MatchField = #ofp_field{class = openflow_basic,
                            has_mask = false,
                            name = eth_type,
                            %% IPv4
                            value= <<16#0800:16>>},
    SetField1 = #ofp_field{class = openflow_basic,
                           has_mask = false,
                           name = ip_ecn,
                           value = <<2:2>>},
    SetField2 = #ofp_field{class = openflow_basic,
                           has_mask = false,
                           name = ip_dscp,
                           value = <<10:6>>},
    Action1 = #ofp_action_set_field{field = SetField1},
    Action2 = #ofp_action_set_field{field = SetField2},
    Action3 = #ofp_action_output{port = 2, max_len = no_buffer},
    Instruction = #ofp_instruction_apply_actions{actions = [Action1,
                                                            Action2,
                                                            Action3]},
    message(#ofp_flow_mod{
               cookie = <<0:64>>,
               cookie_mask = <<0:64>>,
               table_id = 0,
               command = add,
               idle_timeout = 0,
               hard_timeout = 0,
               priority = 1,
               buffer_id = no_buffer,
               out_port = any,
               out_group = any,
               flags = [],
               match = #ofp_match{fields = [MatchField]},
               instructions = [Instruction]}).

table_features_keep_table_0() ->
    message(#ofp_table_features_request{
               body = [#ofp_table_features{
                          table_id = 0,
                          name = <<"flow table 0">>,
                          metadata_match = <<0:64>>,
                          metadata_write = <<0:64>>,
                          max_entries = 10,
                          properties = [#ofp_table_feature_prop_instructions{}
                                       , #ofp_table_feature_prop_next_tables{}
                                       , #ofp_table_feature_prop_write_actions{}
                                       , #ofp_table_feature_prop_apply_actions{}
                                       , #ofp_table_feature_prop_match{}
                                       , #ofp_table_feature_prop_wildcards{}
                                       , #ofp_table_feature_prop_write_setfield{}
                                       , #ofp_table_feature_prop_apply_setfield{}
                                       ]}]}).

%%% Helpers --------------------------------------------------------------------

message(Body) ->
    #ofp_message{version = 5,
                 xid = get_xid(),
                 body = Body}.

all_table_features_request(TableId) ->
    message(#ofp_table_features_request{
               body = [#ofp_table_features{
                          table_id = TableId,
                          name = <<"flow table 0">>,
                          metadata_match = <<0:64>>,
                          metadata_write = <<0:64>>,
                          max_entries = 10,
                          properties =
                              [#ofp_table_feature_prop_instructions{},
                               #ofp_table_feature_prop_instructions_miss{},
                               #ofp_table_feature_prop_next_tables{},
                               #ofp_table_feature_prop_next_tables_miss{},
                               #ofp_table_feature_prop_write_actions{},
                               #ofp_table_feature_prop_write_actions_miss{},
                               #ofp_table_feature_prop_apply_actions{},
                               #ofp_table_feature_prop_apply_actions_miss{},
                               #ofp_table_feature_prop_match{},
                               #ofp_table_feature_prop_wildcards{},
                               #ofp_table_feature_prop_write_setfield{},
                               #ofp_table_feature_prop_write_setfield_miss{},
                               #ofp_table_feature_prop_apply_setfield{},
                               #ofp_table_feature_prop_apply_setfield_miss{}]
                         }]}).

get_xid() ->
    random:uniform(1 bsl 32 - 1).

%%%-----------------------------------------------------------------------------
%%% Helper functions
%%%-----------------------------------------------------------------------------

parse_tcp(Socket, Parser, Data) ->
    %% lager:info("Received TCP data from ~p: ~p", [Socket, Data]),
    inet:setopts(Socket, [{active, once}]),
    {ok, NewParser, Messages} = ofp_parser:parse(Parser, Data),
    lists:foreach(fun(Message) ->
                          self() ! {msg, Socket, Message}
                  end, Messages),
    {ok, NewParser}.

filter_connections(Connections) ->
    [Conn || {_, _, Pid} = Conn <- Connections, is_process_alive(Pid)].

cast(Pid, To, Message) ->
    case is_process_alive(Pid) of
        true ->
            lager:info("Sending ~p", [Message]),
            Pid ! {cast, Message, To};
        false ->
            {error, controller_dead}
    end.

call(Pid, To, Message, Timeout) ->
    case is_process_alive(Pid) of
        true ->
            lager:info("Sending ~p", [Message]),
            Pid ! {call, Message, To, Ref = make_ref(), self(), Timeout},
            lager:info("Waiting for reply"),
            receive
                {reply, Ref, Reply} ->
                    Reply
            end;
        false ->
            {error, controller_dead}
    end.

do_send(Connections, {Address, Port}, Message) ->
    case lists:keyfind({Address, Port}, 1, Connections) of
        false ->
            lager:error("Sending message failed: ~p not found in ~p", [{Address, Port}, Connections]);
        {{Address, Port}, Socket, _} ->
            do_send(Socket, Message)
    end.

do_send(Socket, Message) when is_binary(Message) ->
    try
        gen_tcp:send(Socket, Message)
    catch
        _:_ ->
            ok
    end;
do_send(Socket, Message) when is_tuple(Message) ->
    case of_protocol:encode(Message) of
        {ok, EncodedMessage} ->
            do_send(Socket, EncodedMessage);
        _Error ->
            lager:error("Error in encode of: ~p", [Message])
    end.

generation_id() ->
    {Mega, Sec, Micro} = erlang:now(),
    (Mega * 1000000 + Sec) * 1000000 + Micro.

encoded_hello_message(Scenario) ->
    {ok, EncodedHello} = of_protocol:encode(hello()),
    case Scenario of
        hello_with_bad_version ->
            malform_version_in_hello(EncodedHello);
        _ ->
            EncodedHello
    end.

malform_version_in_hello(<<_:8, Rest/binary>>) ->
    <<(16#5):8, Rest/binary>>.

passive_or_active_controller(Port) when is_integer(Port) ->
    {passive, Port};
passive_or_active_controller(RemotePeer) ->
    case string:tokens(RemotePeer, ":") of
        [Address, Port] ->
            {ok, ParsedAddress} = inet_parse:address(Address),
            {active, ParsedAddress, erlang:list_to_integer(Port)};
        [Port] ->
            {passive, erlang:list_to_integer(Port)};
        _ ->
            erlang:error(bad_argument, RemotePeer)
    end.
