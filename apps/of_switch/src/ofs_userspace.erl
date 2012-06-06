%%%-----------------------------------------------------------------------------
%%% Use is subject to License terms.
%%% @copyright (C) 2012 FlowForwarding.org
%%% @author Krzysztof Rutka <krzysztof.rutka@erlang-solutions.com>
%%% @doc Userspace implementation of the OpenFlow Switch logic.
%%% @end
%%%-----------------------------------------------------------------------------
-module(ofs_userspace).
-author("Erlang Solutions Ltd. <openflow@erlang-solutions.com>").

-behaviour(gen_switch).

%% Switch API
-export([
         route/1,
         add_port/2,
         remove_port/1,
         parse_ofs_pkt/2,
         get_group_stats/0,
         get_group_stats/1
        ]).

%% gen_switch callbacks
-export([start/1,
         ofp_flow_mod/2,
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
         ofp_group_features_stats_request/2,
         stop/1]).

-include_lib("pkt/include/pkt.hrl").
-include_lib("of_protocol/include/ofp_v3.hrl").
-include("ofs_userspace.hrl").

-record(state, {}).
-type state() :: #state{}.

%%%-----------------------------------------------------------------------------
%%% Switch API
%%%-----------------------------------------------------------------------------

-spec route(#ofs_pkt{}) -> pid().
route(Pkt) ->
    proc_lib:spawn_link(ofs_userspace_routing, do_route, [Pkt, 0]).

-spec add_port(ofs_port_type(), [ofs_port_config()]) -> pid() | error.
add_port(physical, Opts) ->
    case supervisor:start_child(ofs_userspace_port_sup, [Opts]) of
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
    ofs_userspace_port:remove(PortNo).

-spec parse_ofs_pkt(binary(), ofp_port_no()) -> #ofs_pkt{}.
parse_ofs_pkt(Binary, PortNum) ->
    try
        Packet = pkt:decapsulate(Binary),
        Fields = [ofs_userspace_convert:ofp_field(in_port, <<PortNum:32>>)
                  || is_integer(PortNum)]
            ++ ofs_userspace_convert:packet_fields(Packet),
        #ofs_pkt{packet = Packet,
                 fields =
                     #ofp_match{type = oxm,
                                oxm_fields = Fields},
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
    %% Flows
    flow_tables = ets:new(flow_tables, [named_table, public,
                                        {keypos, #flow_table.id},
                                        {read_concurrency, true}]),
    ets:insert(flow_tables, [#flow_table{id = Id,
                                         entries = [],
                                         config = drop}
                             || Id <- lists:seq(0, ?OFPTT_MAX)]),
    flow_table_counters = ets:new(flow_table_counters,
                                  [named_table, public,
                                   {keypos, #flow_table_counter.id},
                                   {read_concurrency, true}]),
    ets:insert(flow_table_counters, [#flow_table_counter{id = Id}
                                     || Id <- lists:seq(0, ?OFPTT_MAX)]),
    flow_entry_counters = ets:new(flow_entry_counters,
                                  [named_table, public,
                                   {keypos, #flow_entry_counter.key},
                                   {read_concurrency, true}]),
    %% Ports
    ofs_ports = ets:new(ofs_ports, [named_table, public,
                                    {keypos, #ofs_port.number},
                                    {read_concurrency, true}]),
    port_stats = ets:new(port_stats,
                         [named_table, public,
                          {keypos, #ofp_port_stats.port_no},
                          {read_concurrency, true}]),
    ofs_port_queue = ets:new(ofs_port_queue,
                             [named_table, public,
                              {keypos, #ofs_port_queue.key},
                              {read_concurrency, true}]),
    %% Groups
    group_table = ets:new(group_table, [named_table, public,
                                        {keypos, #group.id},
                                        {read_concurrency, true},
                                        {write_concurrency, true}]),
    group_stats = ets:new(group_stats, [named_table, public,
                                        {keypos, #ofp_group_stats.group_id},
                                        {read_concurrency, true},
                                        {write_concurrency, true}]),
    {ok, Ports} = application:get_env(of_switch, ports),
    [add_port(physical, PortOpts) || PortOpts <- Ports],
    {ok, #state{}}.

%% @doc Stop the switch.
-spec stop(state()) -> any().
stop(_State) ->
    [ofs_userspace_port:remove(PortNo) ||
        #ofs_port{number = PortNo} <- ofs_userspace_port:list_ports()],
    %% Flows
    ets:delete(flow_tables),
    ets:delete(flow_table_counters),
    ets:delete(flow_entry_counters),
    %% Ports
    ets:delete(ofs_ports),
    ets:delete(port_stats),
    ets:delete(ofs_port_queue),
    %% Groups
    ets:delete(group_table),
    ets:delete(group_stats),
    ok.

%% @doc Modify flow entry in the flow table.
ofp_flow_mod(State, #ofp_flow_mod{command = add,
                          table_id = TableId,
                          priority = Priority,
                          flags = Flags} = FlowMod) ->
    AddFlowEntry =
        fun(#flow_table{entries = Entries} = Table) ->
                NewEntry = ofs_userspace_flow:create_flow_entry(FlowMod,
                                                                TableId),
                NewEntries = ordsets:add_element(NewEntry, Entries),
                NewTable = Table#flow_table{entries = NewEntries},
                ets:insert(flow_tables, NewTable)
        end,
    Tables = ofs_userspace_flow:get_flow_tables(TableId),
    case ofs_userspace_flow:has_priority_overlap(Flags, Priority, Tables) of
        true ->
            OverlapError = #ofp_error{type = flow_mod_failed,
                                      code = overlap},
            {error, OverlapError, State};
        false ->
            lists:foreach(AddFlowEntry, Tables),
            {ok, State}
    end;
ofp_flow_mod(State, #ofp_flow_mod{command = modify} = FlowMod) ->
    ofs_userspace_flow:apply_flow_mod(State, FlowMod,
                                      fun ofs_userspace_flow:modify_entries/2,
                                      fun ofs_userspace_flow:fm_non_strict_match/2);
ofp_flow_mod(State, #ofp_flow_mod{command = modify_strict} = FlowMod) ->
    ofs_userspace_flow:apply_flow_mod(State, FlowMod,
                                      fun ofs_userspace_flow:modify_entries/2,
                                      fun ofs_userspace_flow:fm_strict_match/2);
ofp_flow_mod(State, #ofp_flow_mod{command = delete} = FlowMod) ->
    ofs_userspace_flow:apply_flow_mod(State, FlowMod,
                                      fun ofs_userspace_flow:delete_entries/2,
                                      fun ofs_userspace_flow:fm_non_strict_match/2);
ofp_flow_mod(State, #ofp_flow_mod{command = delete_strict} = FlowMod) ->
    ofs_userspace_flow:apply_flow_mod(State, FlowMod,
                                      fun ofs_userspace_flow:delete_entries/2,
                                      fun ofs_userspace_flow:fm_strict_match/2).

%% @doc Modify flow table configuration.
-spec ofp_table_mod(state(), ofp_table_mod()) ->
                           {ok, #state{}} | {error, ofp_error(), #state{}}.
ofp_table_mod(State, #ofp_table_mod{table_id = TableId, config = Config}) ->
    lists:foreach(fun(FlowTable) ->
                          ets:insert(flow_tables,
                                     FlowTable#flow_table{config = Config})
                  end, ofs_userspace_flow:get_flow_tables(TableId)),
    {ok, State}.

%% @doc Modify port configuration.
-spec ofp_port_mod(state(), ofp_port_mod()) ->
      {ok, #state{}} | {error, ofp_error(), #state{}}.
ofp_port_mod(State, #ofp_port_mod{port_no = PortNo} = PortMod) ->
    case ofs_userspace_port:change_config(PortNo, PortMod) of
        {error, Code} ->
            Error = #ofp_error{type = port_mod_failed,
                               code = Code},
            {error, Error, State};
        ok ->
            {ok, State}
    end.

%% @doc Modify group entry in the group table.
-spec ofp_group_mod(state(), ofp_group_mod()) ->
                           {ok, #state{}} | {error, ofp_error(), #state{}}.
ofp_group_mod(State, #ofp_group_mod{command = add, group_id = Id, type = Type,
                                    buckets = Buckets}) ->
    %% Add new entry to the group table, if entry with given group id is already
    %% present, then return error.
    OFSBuckets = lists:map(fun(B) ->
                                   #ofs_bucket{value = B,
                                               counter = #ofp_bucket_counter{}}
                           end, Buckets),
    Entry = #group{id = Id, type = Type, buckets = OFSBuckets},
    case ets:insert_new(group_table, Entry) of
        true ->
            {ok, State};
        false ->
            {error, #ofp_error{type = group_mod_failed,
                               code = group_exists}, State}
    end;
ofp_group_mod(State, #ofp_group_mod{command = modify, group_id = Id, type = Type,
                                    buckets = Buckets}) ->
    %% Modify existing entry in the group table, if entry with given group id
    %% is not in the table, then return error.
    Entry = #group{id = Id, type = Type, buckets = Buckets},
    case ets:member(group_table, Id) of
        true ->
            ets:insert(group_table, Entry),
            {ok, State};
        false ->
            {error, #ofp_error{type = group_mod_failed,
                               code = unknown_group}, State}
    end;
ofp_group_mod(State, #ofp_group_mod{command = delete, group_id = Id}) ->
    %% Deletes existing entry in the group table, if entry with given group id
    %% is not in the table, no error is recorded. Flows containing given
    %% group id are removed along with it.
    %% If one wishes to effectively delete a group yet leave in flow entries
    %% using it, that group can be cleared by sending a modify with no buckets
    %% specified.
    case Id of
        all ->
            ets:delete_all_objects(group_table);
        any ->
            %% TODO: Should we support this case at all?
            ok;
        Id ->
            ets:delete(group_table, Id)
    end,
    %% TODO: Remove flows containing given group along with it
    {ok, State}.

%% @doc Handle a packet received from controller.
-spec ofp_packet_out(state(), ofp_packet_out()) ->
                            {ok, #state{}} | {error, ofp_error(), #state{}}.
ofp_packet_out(State, #ofp_packet_out{actions = Actions,
                                      in_port = InPort,
                                      data = Data}) ->
    ofs_userspace_routing:apply_action_list(0, Actions,
                                            parse_ofs_pkt(Data, InPort)),
    {ok, State}.

%% @doc Reply to echo request.
-spec ofp_echo_request(state(), ofp_echo_request()) ->
      {ok, #ofp_echo_reply{}, #state{}} | {error, ofp_error(), #state{}}.
ofp_echo_request(State, #ofp_echo_request{data = Data}) ->
    EchoReply = #ofp_echo_reply{data = Data},
    {ok, EchoReply, State}.

%% @doc Reply to barrier request.
-spec ofp_barrier_request(state(), ofp_barrier_request()) ->
                                 {ok, #ofp_barrier_reply{}, #state{}} | {error, ofp_error(), #state{}}.
ofp_barrier_request(State, #ofp_barrier_request{}) ->
    BarrierReply = #ofp_barrier_reply{},
    {ok, BarrierReply, State}.

%% @doc Get switch description statistics.
-spec ofp_desc_stats_request(state(), ofp_desc_stats_request()) ->
      {ok, ofp_desc_stats_reply(), #state{}} | {error, ofp_error(), #state{}}.
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
                                    {error, ofp_error(), #state{}}.
ofp_flow_stats_request(State,
                       #ofp_flow_stats_request{table_id = TableId} = Request) ->
    Stats = lists:flatmap(fun(#flow_table{id = TID, entries = Entries}) ->
                                  ofs_userspace_flow:get_flow_stats(TID,
                                                                    Entries,
                                                                    Request)
                          end, ofs_userspace_flow:get_flow_tables(TableId)),
    {ok, #ofp_flow_stats_reply{flags = [], stats = Stats}, State}.

%% @doc Get aggregated flow statistics.
-spec ofp_aggregate_stats_request(state(), ofp_aggregate_stats_request()) ->
                                         {ok, ofp_aggregate_stats_reply(),
                                          #state{}} |
                                         {error, ofp_error(), #state{}}.
ofp_aggregate_stats_request(State, #ofp_aggregate_stats_request{} = Request) ->
    Tables = ofs_userspace_flow:get_flow_tables(Request#ofp_aggregate_stats_request.table_id),
    %% for each table, for each flow, collect matching stats
    Reply = lists:foldl(fun(#flow_table{id = TableId, entries = Entries},
                            OuterAcc) ->
                                lists:foldl(fun(Entry, Acc) ->
                                                    ofs_userspace_stats:update_aggregate_stats(Acc,
                                                                                               TableId,
                                                                                               Entry,
                                                                                               Request)
                                            end, OuterAcc, Entries)
                        end, #ofp_aggregate_stats_reply{}, Tables),
    {ok, Reply, State}.

%% @doc Get flow table statistics.
-spec ofp_table_stats_request(state(), ofp_table_stats_request()) ->
                                     {ok, ofp_table_stats_reply(), #state{}} |
                                     {error, ofp_error(), #state{}}.
ofp_table_stats_request(State, #ofp_table_stats_request{}) ->
    Stats = [ofs_userspace_stats:table_stats(Table) ||
                Table <- lists:sort(ets:tab2list(flow_tables))],
    {ok, #ofp_table_stats_reply{flags = [],
                                stats = Stats}, State}.

%% @doc Get port statistics.
-spec ofp_port_stats_request(state(), ofp_port_stats_request()) ->
                                    {ok, ofp_port_stats_reply(), #state{}} |
                                    {error, ofp_error(), #state{}}.
ofp_port_stats_request(State, #ofp_port_stats_request{port_no = PortNo}) ->
    %% TODO: Should we return error when bad_port is encountered?
    Stats = case ofs_userspace_port:get_port_stats(PortNo) of
                bad_port ->
                    [];
                PortStats ->
                    [PortStats]
            end,
    {ok, #ofp_port_stats_reply{stats = Stats}, State}.

%% @doc Get queue statistics.
-spec ofp_queue_stats_request(state(), ofp_queue_stats_request()) ->
                                     {ok, ofp_queue_stats_reply(), #state{}} |
                                     {error, ofp_error(), #state{}}.
ofp_queue_stats_request(State, #ofp_queue_stats_request{port_no = PortNo,
                                                        queue_id = QueueId}) ->
    %% TODO: Should we return error when undefined is encountered?
    Stats = case ofs_userspace_port:get_queue_stats(PortNo, QueueId) of
                undefined ->
                    [];
                QueueStats ->
                    [QueueStats]
            end,
    {ok, #ofp_queue_stats_reply{stats = Stats}, State}.

%% @doc Get group statistics.
-spec ofp_group_stats_request(state(), ofp_group_stats_request()) ->
                                     {ok, ofp_group_stats_reply(), #state{}} |
                                     {error, ofp_error(), #state{}}.
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
      {ok, ofp_group_desc_stats_reply(), #state{}} | {error, ofp_error(), #state{}}.
ofp_group_desc_stats_request(State, #ofp_group_desc_stats_request{}) ->
    %% TODO: Add group description statistics
    {ok, #ofp_group_desc_stats_reply{}, State}.

%% @doc Get group features statistics.
-spec ofp_group_features_stats_request(state(), ofp_group_features_stats_request()) ->
                                              {ok, ofp_group_features_stats_reply(), #state{}} |
                                              {error, ofp_error(), #state{}}.
ofp_group_features_stats_request(State, #ofp_group_features_stats_request{}) ->
    %% TODO: Add group festures statistics
    {ok, #ofp_group_features_stats_reply{}, State}.

%%%-----------------------------------------------------------------------------
%%% Helpers
%%%-----------------------------------------------------------------------------i

get_env(Env) ->
    {ok, Value} = application:get_env(of_switch, Env),
    Value.
