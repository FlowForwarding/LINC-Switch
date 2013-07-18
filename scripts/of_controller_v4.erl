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
         set_async/0,
         get_async_request/0
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
    start(6633).

start(Port) ->
    lager:start(),
    {ok, spawn(fun() ->
                       init(Port)
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

init(Port) ->
    Pid = self(),
    spawn_link(fun() ->
                       Opts = [binary, {packet, raw},
                               {active, once}, {reuseaddr, true}],
                       {ok, LSocket} = gen_tcp:listen(Port, Opts),
                       accept(Pid, LSocket)
               end),
    loop([]).

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
     set_config_issue87];
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
     get_config_request].

loop(Connections) ->
    receive
        {accept, Socket, Pid} ->
            {ok, {Address, Port}} = inet:peername(Socket),
            lager:info("Accepted connection from ~p {~p,~p}",
                       [Socket, Address, Port]),
            [begin
                 Msg = ?MODULE:Fun(),
                 case of_protocol:encode(Msg) of
                     {ok, EncodedMessage} ->
                         timer:sleep(200),
                         ok = gen_tcp:send(Socket, EncodedMessage);
                     _Error ->
                         lager:error("Error in encode of: ~p", [Msg])
                 end
             end || Fun <- scenario(all_messages)],
            loop([{{Address, Port}, Socket, Pid} | Connections]);
        {cast, Message, AddressPort} ->
            NewConnections = filter_connections(Connections),
            do_send(NewConnections, AddressPort, Message),
            loop(NewConnections);
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
            loop(NewConnections);
        {get_connections, Ref, Pid} ->
            Pid ! {connections, Ref, [AP || {AP,_,_} <- Connections]},
            loop(Connections);
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
            {ok, EncodedMessage} = of_protocol:encode(Message),
            ok = gen_tcp:send(Socket, EncodedMessage)
    end.
