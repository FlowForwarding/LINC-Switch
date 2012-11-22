%%------------------------------------------------------------------------------
%% Copyright 2012 FlowForwarding.org
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%-----------------------------------------------------------------------------

%% @author Erlang Solutions Ltd. <openflow@erlang-solutions.com>
%% @copyright 2012 FlowForwarding.org
%% @doc Userspace implementation of the OpenFlow Switch logic.
-module(linc_us3).

-behaviour(gen_switch).

%% Switch API
-export([route/1,
         add_port/2,
         remove_port/1,
         parse_ofs_pkt/2,
         get_group_stats/0,
         get_group_stats/1]).

%% gen_switch callbacks
-export([start/1,
         stop/1,
         handle_message/2]).

%% Handle all message types
-export([ofp_flow_mod/2,
         ofp_table_mod/2,
         ofp_port_mod/2,
         ofp_group_mod/2,
         ofp_packet_out/2,
         ofp_echo_request/2,
         ofp_barrier_request/2,
         ofp_desc_stats_request/2,
         ofp_flow_stats_request/2,
         ofp_aggregate_stats_request/2,
         ofp_table_stats_request/2,
         ofp_port_stats_request/2,
         ofp_queue_stats_request/2,
         ofp_group_stats_request/2,
         ofp_group_desc_stats_request/2,
         ofp_group_features_stats_request/2]).

-include("linc_us3.hrl").

-record(state, {}).
-type state() :: #state{}.

%%%-----------------------------------------------------------------------------
%%% Switch API
%%%-----------------------------------------------------------------------------

-spec route(#ofs_pkt{}) -> pid().
route(Pkt) ->
    proc_lib:spawn_link(linc_us3_routing, do_route, [Pkt]).

-spec add_port(ofs_port_type(), [ofs_port_config()]) -> pid() | error.
add_port(physical, Opts) ->
    case supervisor:start_child(linc_us3_port_sup, [Opts]) of
        {ok, Pid} ->
            ?INFO("Created port: ~p", [Opts]),
            Pid;
        {error, shutdown} ->
            ?ERROR("Cannot create port ~p", [Opts]),
            error
    end;
add_port(logical, _Opts) ->
    error;
add_port(reserved, _Opts) ->
    error.

-spec remove_port(ofp_port_no()) -> ok | bad_port.
remove_port(PortNo) ->
    linc_us3_port:remove(PortNo).

-spec parse_ofs_pkt(binary(), ofp_port_no()) -> #ofs_pkt{}.
parse_ofs_pkt(Binary, PortNum) ->
    try
        Packet = pkt:decapsulate(Binary),
        Fields = [linc_us3_convert:ofp_field(in_port, <<PortNum:32>>)
                  || is_integer(PortNum)]
            ++ linc_us3_convert:packet_fields(Packet),
        #ofs_pkt{packet = Packet,
                 fields =
                     #ofp_match{fields = Fields},
                 in_port = PortNum,
                 size = byte_size(Binary)}
    catch
        E1:E2 ->
            ?ERROR("Decapsulate failed for pkt: ~p because: ~p:~p",
                   [Binary, E1, E2]),
            io:format("Stacktrace: ~p~n", [erlang:get_stacktrace()]),
            #ofs_pkt{}
    end.

-spec get_group_stats() -> [ofp_group_stats()].
get_group_stats() ->
    ets:tab2list(group_stats).

-spec get_group_stats(ofp_group_id()) -> ofp_group_stats() | undefined.
get_group_stats(GroupId) ->
    case ets:lookup(group_stats, GroupId) of
        [] ->
            undefined;
        [Any] ->
            Any
    end.

%%%-----------------------------------------------------------------------------
%%% gen_switch callbacks
%%%-----------------------------------------------------------------------------

%% @doc Start the switch.
-spec start(any()) -> {ok, state()}.
start(_Opts) ->
    UserspaceSup = {linc_us3_sup, {linc_us3_sup, start_link, []},
                    permanent, 5000, supervisor, [linc_us3_sup]},
    supervisor:start_child(linc_sup, UserspaceSup),

    linc_us3_flow:initialize(),

    %% Ports
    ofs_ports = ets:new(ofs_ports, [named_table, public,
                                    {keypos, #ofs_port.number},
                                    {read_concurrency, true}]),
    port_stats = ets:new(port_stats,
                         [named_table, public,
                          {keypos, #ofp_port_stats.port_no},
                          {read_concurrency, true}]),

    case application:get_env(linc, queues) of
        undefined ->
            no_queues;
        {ok, _} ->
            linc_us3_queue:start()
    end,

    {ok, BackendOpts} = application:get_env(linc, backends),
    {userspace, UserspaceOpts} = lists:keyfind(userspace, 1, BackendOpts),
    {ports, UserspacePorts} = lists:keyfind(ports, 1, UserspaceOpts),
    [add_port(physical, Port) || Port <- UserspacePorts],

    {ok, #state{}}.

%% @doc Stop the switch.
-spec stop(state()) -> any().
stop(_State) ->
    [linc_us3_port:remove(PortNo) ||
        #ofs_port{number = PortNo} <- linc_us3_port:list_ports()],
    %% Flows
    linc_us3_flow:terminate(),
    %% Ports
    ets:delete(ofs_ports),
    ets:delete(port_stats),
    case application:get_env(linc, queues) of
        undefined ->
            ok;
        {ok, _} ->
            linc_us3_queue:stop()
    end,
    ok.

-spec handle_message(ofp_message_body(), state()) ->
                            {ok, state()} |
                            {error, ofp_error_msg(), state()}.
handle_message(MessageBody, State) ->
    MessageName = element(1, MessageBody),
    erlang:apply(?MODULE, MessageName, [State, MessageBody]).

%%%-----------------------------------------------------------------------------
%%% Handling of messages
%%%-----------------------------------------------------------------------------

%% @doc Modify flow entry in the flow table.
ofp_flow_mod(State, #ofp_flow_mod{command = add} = FlowMod) ->
    case linc_us3_flow:modify(FlowMod) of
        ok ->
            {ok,State};
        {error,{Type,Code}} ->
            ErrorMsg = #ofp_error_msg{type = Type,
                                      code = Code},
            {error, ErrorMsg, State}
    end;
                    
ofp_flow_mod(State, #ofp_flow_mod{command = modify} = FlowMod) ->
    linc_us3_flow:apply_flow_mod(State, FlowMod,
                                      fun linc_us3_flow:modify_entries/2,
                                      fun linc_us3_flow:fm_non_strict_match/2);
ofp_flow_mod(State, #ofp_flow_mod{command = modify_strict} = FlowMod) ->
    linc_us3_flow:apply_flow_mod(State, FlowMod,
                                      fun linc_us3_flow:modify_entries/2,
                                      fun linc_us3_flow:fm_strict_match/2);
ofp_flow_mod(State, #ofp_flow_mod{command = delete} = FlowMod) ->
    linc_us3_flow:apply_flow_mod(State, FlowMod,
                                      fun linc_us3_flow:delete_entries/2,
                                      fun linc_us3_flow:fm_non_strict_match/2);
ofp_flow_mod(State, #ofp_flow_mod{command = delete_strict} = FlowMod) ->
    linc_us3_flow:apply_flow_mod(State, FlowMod,
                                      fun linc_us3_flow:delete_entries/2,
                                      fun linc_us3_flow:fm_strict_match/2).

%% @doc Modify flow table configuration.
-spec ofp_table_mod(state(), ofp_table_mod()) ->
                           {ok, #state{}} | {error, ofp_error_msg(), #state{}}.
ofp_table_mod(State, #ofp_table_mod{}=TableMod) ->
    linc_us3_flow:table_mod(TableMod),
    {ok, State}.

%% @doc Modify port configuration.
-spec ofp_port_mod(state(), ofp_port_mod()) ->
      {ok, #state{}} | {error, ofp_error_msg(), #state{}}.
ofp_port_mod(State, #ofp_port_mod{port_no = PortNo} = PortMod) ->
    case linc_us3_port:change_config(PortNo, PortMod) of
        {error, Code} ->
            Error = #ofp_error_msg{type = port_mod_failed,
                                   code = Code},
            {error, Error, State};
        ok ->
            {ok, State}
    end.

%% @doc Modify group entry in the group table.
-spec ofp_group_mod(state(), ofp_group_mod()) ->
                           {ok, #state{}} | {error, ofp_error_msg(), #state{}}.
ofp_group_mod(State, Mod = #ofp_group_mod{}) ->
    %% TODO: move specific logic inside linc_us3_groups module
    case linc_us3_groups:modify(Mod) of
        ok -> {ok, State};
        {error, What} -> {error, What, State}
    end.

%% @doc Handle a packet received from controller.
-spec ofp_packet_out(state(), ofp_packet_out()) ->
                            {ok, #state{}} | {error, ofp_error_msg(), #state{}}.
ofp_packet_out(State, #ofp_packet_out{actions = Actions,
                                      in_port = InPort,
                                      data = Data}) ->
    linc_us3_actions:apply_list(0, Actions,
                                parse_ofs_pkt(Data, InPort)),
    {ok, State}.

%% @doc Reply to echo request.
-spec ofp_echo_request(state(), ofp_echo_request()) ->
      {ok, #ofp_echo_reply{}, #state{}} | {error, ofp_error_msg(), #state{}}.
ofp_echo_request(State, #ofp_echo_request{data = Data}) ->
    EchoReply = #ofp_echo_reply{data = Data},
    {ok, EchoReply, State}.

%% @doc Reply to barrier request.
-spec ofp_barrier_request(state(), ofp_barrier_request()) ->
                                 {ok, #ofp_barrier_reply{}, #state{}} | {error, ofp_error_msg(), #state{}}.
ofp_barrier_request(State, #ofp_barrier_request{}) ->
    BarrierReply = #ofp_barrier_reply{},
    {ok, BarrierReply, State}.

%% @doc Get switch description statistics.
-spec ofp_desc_stats_request(state(), ofp_desc_stats_request()) ->
      {ok, ofp_desc_stats_reply(), #state{}} | {error, ofp_error_msg(), #state{}}.
ofp_desc_stats_request(State, #ofp_desc_stats_request{}) ->
    {ok, #ofp_desc_stats_reply{flags = [],
                               mfr_desc = get_env(manufacturer_desc),
                               hw_desc = get_env(hardware_desc),
                               sw_desc = get_env(software_desc),
                               serial_num = get_env(serial_number),
                               dp_desc = get_env(datapath_desc)
                              }, State}.

%% @doc Get flow entry statistics.
-spec ofp_flow_stats_request(state(), ofp_flow_stats_request()) ->
                                    {ok, ofp_flow_stats_reply(), #state{}} |
                                    {error, ofp_error_msg(), #state{}}.
ofp_flow_stats_request(State,
                       #ofp_flow_stats_request{table_id = TableId} = Request) ->
    Stats = lists:flatmap(fun(#linc_flow_table{id = TID, entries = Entries}) ->
                                  linc_us3_flow:get_flow_stats(TID,
                                                                    Entries,
                                                                    Request)
                          end, linc_us3_flow:get_flow_tables(TableId)),
    {ok, #ofp_flow_stats_reply{flags = [], stats = Stats}, State}.

%% @doc Get aggregated flow statistics.
-spec ofp_aggregate_stats_request(state(), ofp_aggregate_stats_request()) ->
                                         {ok, ofp_aggregate_stats_reply(),
                                          #state{}} |
                                         {error, ofp_error_msg(), #state{}}.
ofp_aggregate_stats_request(State, #ofp_aggregate_stats_request{} = Request) ->
    Tables = linc_us3_flow:get_flow_tables(Request#ofp_aggregate_stats_request.table_id),
    %% for each table, for each flow, collect matching stats
    Reply = lists:foldl(fun(#linc_flow_table{id = TableId, entries = Entries},
                            OuterAcc) ->
                                lists:foldl(fun(Entry, Acc) ->
                                                    linc_us3_stats:update_aggregate_stats(Acc,
                                                                                               TableId,
                                                                                               Entry,
                                                                                               Request)
                                            end, OuterAcc, Entries)
                        end, #ofp_aggregate_stats_reply{}, Tables),
    {ok, Reply, State}.

%% @doc Get flow table statistics.
-spec ofp_table_stats_request(state(), ofp_table_stats_request()) ->
                                     {ok, ofp_table_stats_reply(), #state{}} |
                                     {error, ofp_error_msg(), #state{}}.
ofp_table_stats_request(State, #ofp_table_stats_request{}) ->
    Stats = [linc_us3_stats:table_stats(Table) ||
                Table <- lists:sort(ets:tab2list(flow_tables))],
    {ok, #ofp_table_stats_reply{flags = [],
                                stats = Stats}, State}.

%% @doc Get port statistics.
-spec ofp_port_stats_request(state(), ofp_port_stats_request()) ->
                                    {ok, ofp_port_stats_reply(), #state{}} |
                                    {error, ofp_error_msg(), #state{}}.
ofp_port_stats_request(State, #ofp_port_stats_request{port_no = PortNo}) ->
    %% TODO: Should we return error when bad_port is encountered?
    Stats = case linc_us3_port:get_port_stats(PortNo) of
                bad_port ->
                    [];
                PortStats ->
                    [PortStats]
            end,
    {ok, #ofp_port_stats_reply{stats = Stats}, State}.

%% @doc Get queue statistics.
-spec ofp_queue_stats_request(state(), ofp_queue_stats_request()) ->
                                     {ok, ofp_queue_stats_reply(), #state{}} |
                                     {error, ofp_error_msg(), #state{}}.
ofp_queue_stats_request(State, #ofp_queue_stats_request{port_no = PortNo,
                                                        queue_id = QueueId}) ->
    %% TODO: Should we return error when undefined is encountered?
    Stats = case linc_us3_port:get_queue_stats(PortNo, QueueId) of
                undefined ->
                    [];
                QueueStats ->
                    [QueueStats]
            end,
    {ok, #ofp_queue_stats_reply{stats = Stats}, State}.

%% @doc Get group statistics.
-spec ofp_group_stats_request(state(), ofp_group_stats_request()) ->
                                     {ok, ofp_group_stats_reply(), #state{}} |
                                     {error, ofp_error_msg(), #state{}}.
ofp_group_stats_request(State, #ofp_group_stats_request{group_id = GroupId}) ->
    Stats = case get_group_stats(GroupId) of
                undefined ->
                    [];
                GroupStats ->
                    [GroupStats]
            end,
    {ok, #ofp_group_stats_reply{stats = Stats}, State}.

%% @doc Get group description statistics.
-spec ofp_group_desc_stats_request(state(), ofp_group_desc_stats_request()) ->
                                          {ok, ofp_group_desc_stats_reply(), #state{}} |
                                          {error, ofp_error_msg(), #state{}}.
ofp_group_desc_stats_request(State, #ofp_group_desc_stats_request{}) ->
    %% TODO: Add group description statistics
    {ok, #ofp_group_desc_stats_reply{}, State}.

%% @doc Get group features statistics.
-spec ofp_group_features_stats_request(state(), ofp_group_features_stats_request()) ->
                                              {ok, ofp_group_features_stats_reply(), #state{}} |
                                              {error, ofp_error_msg(), #state{}}.
ofp_group_features_stats_request(State, #ofp_group_features_stats_request{}) ->
    Stats = #ofp_group_features_stats_reply{
      types = ?SUPPORTED_GROUP_TYPES,
      capabilities = ?SUPPORTED_GROUP_CAPABILITIES,
      max_groups = ?MAX_GROUP_ENTRIES,
      actions = {?SUPPORTED_APPLY_ACTIONS, [], [], []}},
    {ok, Stats, State}.

%%%-----------------------------------------------------------------------------
%%% Helpers
%%%-----------------------------------------------------------------------------i

get_env(Env) ->
    {ok, Value} = application:get_env(linc, Env),
    Value.

%% get_datapath_mac() ->
%%     {ok, Ifs} = inet:getifaddrs(),
%%     MACs =  [element(2, lists:keyfind(hwaddr, 1, Ps))
%%              || {_IF, Ps} <- Ifs, lists:keymember(hwaddr, 1, Ps)],
%%     %% Make sure MAC /= 0
%%     [MAC | _] = [M || M <- MACs, M /= [0,0,0,0,0,0]],
%%     list_to_binary(MAC).
