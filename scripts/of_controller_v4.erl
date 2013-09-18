%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2012, Erlang Solutions Ltd.
%%% @doc OpenFlow 1.2 Controller.
%%% @end
%%%-----------------------------------------------------------------------------
-module(of_controller_v4).

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
         flow_mod_with_flags/0,
         set_async/0,
         get_async_request/0,
         bin_port_desc_request/0,
         flow_mod_issue91/0,
         flow_mod_output_to_port/3,
         async_config/3,
         role_request/2
         ]).

-include_lib("of_protocol/include/of_protocol.hrl").
-include_lib("of_protocol/include/ofp_v4.hrl").
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
    start_scenario(6633, all_messages).

start(Port) ->
    start_scenario(Port, all_messages).

start_scenario(Scenario) ->
    start_scenario(6633, Scenario).

start_scenario(Port, Scenario) ->
    lager:start(),
    {ok, spawn(fun() ->
                       init(Port, Scenario)
               end)}.

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

init(Port, Scenario) ->
    Pid = self(),
    spawn_link(fun() ->
                       Opts = [binary, {packet, raw},
                               {active, once}, {reuseaddr, true}],
                       {ok, LSocket} = gen_tcp:listen(Port, Opts),
                       accept(Pid, LSocket)
               end),
    loop([], Scenario).

accept(Parent, LSocket) ->
    {ok, Socket} = gen_tcp:accept(LSocket),
    Pid = spawn_link(fun() ->
                             {ok, EncodedHello} = of_protocol:encode(hello()),
                             gen_tcp:send(Socket, EncodedHello),
                             {ok, Parser} = ofp_parser:new(4),
                             inet:setopts(Socket, [{active, once}]),
                             handle(#cstate{parent = Parent,
                                            socket = Socket,
                                            parser = Parser})
                     end),
    ok = gen_tcp:controlling_process(Socket, Pid),
    Parent ! {accept, Socket, Pid},
    accept(Parent, LSocket).

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
scenario(flow_mod_with_flags) ->
    [flow_mod_with_flags,
     flow_stats_request];
scenario(port_desc_request_random_padding) ->
    [bin_port_desc_request];
scenario(ipv6_change_dst) ->
    [flow_mod_delete_all_flows,
     flow_mod_issue91];

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
     async_config({[no_match], []}, {[], []}, {[], []}),
     flow_mod_output_to_port(1, 2, undefined),
     flow_mod_output_to_port(2, 1, undefined),
     flow_mod_output_to_port(1, controller, no_buffer),
     flow_mod_table_miss()];
%% Scenario for slave controller:
%% 1. Request slave role.
%% 2. Set asynchronous messages config so that slave controller receives
%%    packet ins generated by a no_match.
scenario(slave_controller) ->
    [role_request(slave, generation_id()),
     async_config({[], [action]}, {[], []}, {[], []})];

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
     async_config({[], [action]}, {[], []}, {[], []}),
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
     async_config({[action], []}, {[], []}, {[], []})];

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
%% should be buffered by the switch.
scenario(port_1_to_controller_12_bytes) ->
    [role_request(equal, generation_id()),
     flow_mod_delete_all_flows(),
     flow_mod_output_to_port(1, controller, 12),
     async_config({[action], []}, {[], []}, {[], []})];

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

scenario(table_miss) ->
    [flow_mod_table_miss()];

scenario(_Unknown) ->
    lager:debug("Unknown controller's scenario. Running `all_messages` one."),
    scenario(all_messages).


loop(Connections, Scenario) ->
    receive
        {accept, Socket, Pid} ->
            {ok, {Address, Port}} = inet:peername(Socket),
            lager:info("Accepted connection from ~p {~p,~p}",
                       [Socket, Address, Port]),
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
        {call, #ofp_message{xid = Xid} = Message,
         AddressPort, Ref, ReplyPid, Timeout} ->
            NewConnections = filter_connections(Connections),
            do_send(NewConnections, AddressPort, Message),
            receive
                {message, #ofp_message{xid = Xid} = Reply} ->
                    ReplyPid ! {reply, Ref, {reply, Reply}}
            after Timeout ->
                    ReplyPid ! {reply, Ref, {error, timeout}}
            end,
            loop(NewConnections, Scenario);
        {get_connections, Ref, Pid} ->
            Pid ! {connections, Ref, [AP || {AP,_,_} <- Connections]},
            loop(Connections, Scenario);
        stop ->
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
                          advertise = [fiber]}).

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
    Action = case InPort =:= controller of
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
    message(ofp_v4_utils:flow_add(Opts, Matches, Instructions)).

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

%%% Helpers --------------------------------------------------------------------

message(Body) ->
    #ofp_message{version = 4,
                 xid = get_xid(),
                 body = Body}.

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
            lager:error("Sending message failed");
        {{Address, Port}, Socket, _} ->
            do_send(Socket, Message)
    end.

do_send(Socket, Message) when is_binary(Message) ->
    ok = gen_tcp:send(Socket, Message);
do_send(Socket, Message) when is_tuple(Message) ->
    case of_protocol:encode(Message) of
        {ok, EncodedMessage} ->
            ok = gen_tcp:send(Socket, EncodedMessage);
        _Error ->
            lager:error("Error in encode of: ~p", [Message])
    end.

generation_id() ->
    {Mega, Sec, Micro} = erlang:now(),
    (Mega * 1000000 + Sec) * 1000000 + Micro.
