%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2012, Erlang Solutions Ltd.
%%% @author Krzysztof Rutka <krzysztof.rutka@erlang-solutions.com>
%%% @doc Userspace implementation of the OpenFlow Switch logic.
%%% @end
%%%-----------------------------------------------------------------------------
-module(of_switch_userspace).

-behaviour(gen_switch).

%% Switch API
-export([
         route/1,
         add_port/2,
         remove_port/1,
         pkt_to_ofs/2
        ]).

%% Spawns
-export([do_route/2]).

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
-include_lib("of_protocol/include/of_protocol.hrl").
-include_lib("of_protocol/include/ofp_v3.hrl").
-include("of_switch.hrl").
-include("of_switch_userspace.hrl").

-record(state, {}).

-type state() :: #state{}.
-type route_result() :: drop | controller | output.

%%%-----------------------------------------------------------------------------
%%% Switch API
%%%-----------------------------------------------------------------------------

-spec route(#ofs_pkt{}) -> pid().
route(Pkt) ->
    proc_lib:spawn_link(?MODULE, do_route, [Pkt, 0]).

-spec add_port(ofs_port_type(), list(tuple(interface |
                                           ofs_port_num |
                                           ip, string()))) -> ok.
add_port(physical, Opts) ->
    case supervisor:start_child(ofs_userspace_port_sup, [Opts]) of
        {ok, _Pid} ->
            lager:info("Created port: ~p", [Opts]),
            ok;
        {error, shutdown} ->
            lager:error("Cannot create port ~p", [Opts])
    end;
add_port(logical, _Opts) ->
    ok;
add_port(reserved, _Opts) ->
    ok.

-spec remove_port(integer()) -> ok.
remove_port(PortId) ->
    case ets:lookup(ofs_ports, PortId) of
        [] ->
            ok;
        [#ofs_port{handle = Pid}] ->
            ofs_userspace_port:stop(Pid),
            ets:delete(PortId)
    end.

-spec pkt_to_ofs([pkt:packet()], ofp_port_no()) -> #ofs_pkt{}.
pkt_to_ofs(Packet, PortNum) ->
    #ofs_pkt{packet = Packet,
             fields = #ofp_match{type = oxm,
                             oxm_fields = [ofp_field(in_port, <<PortNum:32>>) |
                                           packet_fields(Packet)]},
             in_port = PortNum}.

%%%-----------------------------------------------------------------------------
%%% gen_switch callbacks
%%%-----------------------------------------------------------------------------

%% @doc Start the switch.
-spec start(any()) -> {ok, state()}.
start(_Opts) ->
    flow_tables = ets:new(flow_tables, [named_table, public,
                                        {keypos, #flow_table.id},
                                        {read_concurrency, true}]),
    ets:insert(flow_tables, [#flow_table{id = Id,
                                         entries = [],
                                         config = drop}
                             || Id <- lists:seq(0, ?OFPTT_MAX)]),
    ofs_ports = ets:new(ofs_ports, [named_table, public,
                                    {keypos, #ofs_port.number},
                                    {read_concurrency, true}]),

    %% Counters
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
    ofs_port_counters = ets:new(ofs_port_counters,
                                [named_table, public,
                                 {keypos, #ofs_port_counter.number},
                                 {read_concurrency, true}]),
    group_table = ets:new(group_table, [named_table, public,
                                        {keypos, #group_entry.id},
                                        {read_concurrency, true},
                                        {write_concurrency, true}]),
    group_entry_counters = ets:new(group_entry_counters, [named_table, public,
                                                          {keypos,
                                                           #group_entry_counters.id},
                                                          {read_concurrency, true},
                                                          {write_concurrency, true}]),
    {ok, Ports} = application:get_env(of_switch, ports),
    [add_port(physical, PortOpts) || PortOpts <- Ports],
    {ok, #state{}}.

%% @doc Stop the switch.
-spec stop(state()) -> any().
stop(_State) ->
    ets:delete(flow_tables),
    ets:delete(ofs_ports),
    ets:delete(flow_table_counters),
    ets:delete(flow_entry_counters),
    ets:delete(ofs_port_counters),
    ok.

%% @doc Modify flow entry in the flow table.
ofp_flow_mod(State, #ofp_flow_mod{command = add,
                          table_id = TableId,
                          priority = Priority,
                          flags = Flags} = FlowMod) ->
    AddFlowEntry =
        fun(#flow_table{entries = Entries} = Table) ->
                NewEntry = create_flow_entry(FlowMod, TableId),
                NewEntries = ordsets:add_element(NewEntry, Entries),
                NewTable = Table#flow_table{entries = NewEntries},
                ets:insert(flow_tables, NewTable)
        end,
    Tables = get_flow_tables(TableId),
    case has_priority_overlap(Flags, Priority, Tables) of
        true ->
            OverlapError = #ofp_error{type = flow_mod_failed,
                                      code = overlap},
            {error, OverlapError, State};
        false ->
            lists:foreach(AddFlowEntry, Tables),
            {ok, State}
    end;
ofp_flow_mod(State, #ofp_flow_mod{command = modify} = FlowMod) ->
    apply_flow_mod(State, FlowMod, fun modify_entries/2,
                   fun fm_non_strict_match/2);
ofp_flow_mod(State, #ofp_flow_mod{command = modify_strict} = FlowMod) ->
    apply_flow_mod(State, FlowMod, fun modify_entries/2,
                   fun fm_strict_match/2);
ofp_flow_mod(State, #ofp_flow_mod{command = delete} = FlowMod) ->
    apply_flow_mod(State, FlowMod, fun delete_entries/2,
                   fun fm_non_strict_match/2);
ofp_flow_mod(State, #ofp_flow_mod{command = delete_strict} = FlowMod) ->
    apply_flow_mod(State, FlowMod, fun delete_entries/2,
                   fun fm_strict_match/2).

%% @doc Modify flow table configuration.
-spec ofp_table_mod(state(), ofp_table_mod()) ->
      {ok, #state{}} | {error, ofp_error(), #state{}}.
ofp_table_mod(State, #ofp_table_mod{table_id = TableId, config = Config}) ->
    lists:foreach(fun(FlowTable) ->
        ets:insert(flow_tables, FlowTable#flow_table{config = Config})
    end, get_flow_tables(TableId)),
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
    Entry = #group_entry{id = Id, type = Type, buckets = Buckets},
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
    Entry = #group_entry{id = Id, type = Type, buckets = Buckets},
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
            ok;
        Id ->
            ets:delete(group_table, Id)
    end,
    {ok, State}.

%% @doc Send packet to controller
-spec ofp_packet_out(state(), ofp_packet_out()) ->
      {ok, #state{}} | {error, ofp_error(), #state{}}.
ofp_packet_out(State, #ofp_packet_out{actions = Actions,
                              in_port = InPort,
                              data = Data}) ->
    Pkt = pkt:decapsulate(Data),
    apply_action_list(0, Actions, pkt_to_ofs(Pkt, InPort)),
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
                           mfr_desc = <<"Dummy mfr_desc">>,
                           hw_desc = <<"Dummy hw_desc">>,
                           sw_desc = <<"Dummy sw_desc">>,
                           serial_num = <<"Dummy serial_num">>,
                           dp_desc = <<"Dummy dp_desc">>
                       }, State}.

%% @doc Get flow entry statistics.
-spec ofp_flow_stats_request(state(), ofp_flow_stats_request()) ->
      {ok, ofp_flow_stats_reply(), #state{}} | {error, ofp_error(), #state{}}.
ofp_flow_stats_request(State, #ofp_flow_stats_request{table_id = TableId} = Request) ->
    try
        Stats = lists:flatmap(fun(#flow_table{id = TID, entries = Entries}) ->
                                  get_flow_stats(TID, Entries, Request)
                              end, get_flow_tables(TableId)),
        {ok, #ofp_flow_stats_reply{flags = [],
                               stats = Stats}, State}
    catch #ofp_error{} = ErrorMsg ->
        {error, ErrorMsg, State}
    end.

%% @doc Get aggregated flow statistics.
-spec ofp_aggregate_stats_request(state(), ofp_aggregate_stats_request()) ->
      {ok, ofp_aggregate_stats_reply(), #state{}} | {error, ofp_error(), #state{}}.
ofp_aggregate_stats_request(State, #ofp_aggregate_stats_request{}) ->
    {ok, #ofp_aggregate_stats_reply{}, State}.

%% @doc Get flow table statistics.
-spec ofp_table_stats_request(state(), ofp_table_stats_request()) ->
      {ok, ofp_table_stats_reply(), #state{}} | {error, ofp_error(), #state{}}.
ofp_table_stats_request(State, #ofp_table_stats_request{}) ->
    {ok, #ofp_table_stats_reply{}, State}.

%% @doc Get port statistics.
-spec ofp_port_stats_request(state(), ofp_port_stats_request()) ->
      {ok, ofp_port_stats_reply(), #state{}} | {error, ofp_error(), #state{}}.
ofp_port_stats_request(State, #ofp_port_stats_request{}) ->
    {ok, #ofp_port_stats_reply{}, State}.

%% @doc Get queue statistics.
-spec ofp_queue_stats_request(state(), ofp_queue_stats_request()) ->
      {ok, ofp_queue_stats_reply(), #state{}} | {error, ofp_error(), #state{}}.
ofp_queue_stats_request(State, #ofp_queue_stats_request{}) ->
    {ok, #ofp_queue_stats_reply{}, State}.

%% @doc Get group statistics.
-spec ofp_group_stats_request(state(), ofp_group_stats_request()) ->
      {ok, ofp_group_stats_reply(), #state{}} | {error, ofp_error(), #state{}}.
ofp_group_stats_request(State, #ofp_group_stats_request{}) ->
    {ok, #ofp_group_stats_reply{}, State}.

%% @doc Get group description statistics.
-spec ofp_group_desc_stats_request(state(), ofp_group_desc_stats_request()) ->
      {ok, ofp_group_desc_stats_reply(), #state{}} | {error, ofp_error(), #state{}}.
ofp_group_desc_stats_request(State, #ofp_group_desc_stats_request{}) ->
    {ok, #ofp_group_desc_stats_reply{}, State}.

%% @doc Get group features statistics.
-spec ofp_group_features_stats_request(state(), ofp_group_features_stats_request()) ->
      {ok, ofp_group_features_stats_reply(), #state{}} | {error, ofp_error(), #state{}}.
ofp_group_features_stats_request(State, #ofp_group_features_stats_request{}) ->
    {ok, #ofp_group_features_stats_reply{}, State}.

%%%-----------------------------------------------------------------------------
%%% Helpers
%%%-----------------------------------------------------------------------------

-spec xid() -> integer().
xid() ->
    %% TODO: think about sequental XIDs
    %% XID is a 32 bit integer
    random:uniform(1 bsl 32) - 1.

-spec get_flow_tables(integer() | all) -> [#flow_table{}].
get_flow_tables(all) ->
    ets:tab2list(flow_tables);
get_flow_tables(TableId) when is_integer(TableId) ->
    ets:lookup(flow_tables, TableId).

apply_flow_mod(State, FlowMod, ModFun, MatchFun) ->
    try
        ModFun(FlowMod, MatchFun),
        {ok, State}
    catch #ofp_error{} = Error ->
        {error, Error, State}
    end.

modify_entries(#ofp_flow_mod{table_id = TableId} = FlowMod, MatchFun) ->
    lists:foreach(
        fun(#flow_table{entries = Entries} = Table) ->
            NewEntries = [modify_flow_entry(Entry, FlowMod, MatchFun)
                          || Entry <- Entries],
            ets:insert(flow_tables, Table#flow_table{entries = NewEntries})
        end, get_flow_tables(TableId)).

modify_flow_entry(#flow_entry{} = Entry,
                  #ofp_flow_mod{match = NewMatch,
                            instructions = NewInstructions} = FlowMod,
                  MatchFun) ->
    case MatchFun(Entry, FlowMod) of
        true ->
            %% TODO: update counters
            Entry#flow_entry{match = NewMatch,
                             instructions = NewInstructions};
        false ->
            Entry
    end.

delete_entries(#ofp_flow_mod{table_id = TableId} = FlowMod, MatchFun) ->
    lists:foreach(
      fun(#flow_table{entries = Entries} = Table) ->
              NewEntries = lists:filter(fun(Entry) ->
                                                not MatchFun(Entry, FlowMod)
                                        end, Entries),
              ets:insert(flow_tables, Table#flow_table{entries = NewEntries})
      end, get_flow_tables(TableId)).

get_flow_stats(TID, Entries, #ofp_flow_stats_request{out_port = OutPort,
                                                     out_group = OutGroup,
                                                     cookie = Cookie,
                                                     cookie_mask = CookieMask,
                                                     match = Match}) ->
    MatchingEntries = [Entry || Entry <- Entries,
                                non_strict_match(Entry, Match),
                                port_match(Entry, OutPort),
                                group_match(Entry, OutGroup),
                                cookie_match(Entry, Cookie, CookieMask)],
    [#ofp_flow_stats{table_id = TID,
                     duration_sec = DurationUSec div 1000000,
                     duration_nsec = (DurationUSec rem 1000000) * 1000,
                     priority = Entry#flow_entry.priority,
                     idle_timeout = -1, %% FIXME
                     hard_timeout = -1, %% FIXME
                     cookie = Entry#flow_entry.cookie,
                     packet_count = EntryStats#flow_entry_counter.received_packets,
                     byte_count = EntryStats#flow_entry_counter.received_bytes,
                     match = Entry#flow_entry.match,
                     instructions = Entry#flow_entry.instructions}
     || Entry <- MatchingEntries,
        EntryStats <- ets:lookup(flow_entry_counters, {TID, Entry}),
        DurationUSec <- [
                         timer:now_diff(now(), Entry#flow_entry.install_time)
                        ]].

%% strict match: use all match fields (including the masks) and the priority
fm_strict_match(#flow_entry{priority = Priority, match = Match} = Entry,
                #ofp_flow_mod{priority = Priority, match = Match} = FlowMod) ->
    cookie_match(Entry, FlowMod#ofp_flow_mod.cookie, FlowMod#ofp_flow_mod.cookie_mask);
fm_strict_match(_FlowEntry, _FlowMod) ->
    false.

%% non-strict match: match more specific fields, ignore the priority
fm_non_strict_match(FlowEntry, #ofp_flow_mod{match = Match,
                                         cookie = Cookie,
                                         cookie_mask = CookieMask}) ->
    cookie_match(FlowEntry, Cookie, CookieMask)
    andalso
    non_strict_match(FlowEntry, Match).

non_strict_match(#flow_entry{match = #ofp_match{type = oxm,
                                            oxm_fields = EntryFields}},
                 #ofp_match{type = oxm, oxm_fields = FlowModFields}) ->
    lists:all(fun(#ofp_field{field = Field} = FlowModField) ->
        case lists:keyfind(Field, #ofp_field.field, EntryFields) of
            #ofp_field{} = EntryField ->
                is_more_specific(EntryField, FlowModField);
            false ->
                false
        end
    end, FlowModFields);
non_strict_match(_FlowEntry, _Match) ->
    throw(#ofp_error{type = bad_match, code = bad_type}).

is_more_specific(#ofp_field{class = Cls1}, #ofp_field{class = Cls2}) when
        Cls1 =/= openflow_basic; Cls2 =/= openflow_basic ->
    throw(#ofp_error{type = bad_match, code = bad_field});
is_more_specific(#ofp_field{has_mask = true},
                 #ofp_field{has_mask = false}) ->
    false; %% masked is less specific than non-masked
is_more_specific(#ofp_field{has_mask = false, value = Value},
                 #ofp_field{has_mask = _____, value = Value}) ->
    true; %% value match with no mask is more specific
is_more_specific(#ofp_field{has_mask = true, mask = M1, value = V1},
                 #ofp_field{has_mask = true, mask = M2, value = V2}) ->
    %% M1 is more specific than M2 (has all of it's bits)
    %% and V1*M2 == V2*M2
    is_mask_more_specific(M1, M2)
    andalso
    mask_match(V1, V2, M2);
is_more_specific(_MoreSpecific, _LessSpecific) ->
    false.

-spec is_mask_more_specific(binary(), binary()) -> boolean().
is_mask_more_specific(<<B1,Rest1/binary>>, <<B2,Rest2/binary>>) ->
    B1 bor B2 == B1
    andalso
    is_mask_more_specific(Rest1, Rest2);
is_mask_more_specific(<<>>, <<>>) ->
    true.

mask_match(<<V1,Rest1/binary>>, <<V2,Rest2/binary>>, <<M,Rest3/binary>>) ->
    V1 band M == V2 band M
    andalso
    mask_match(Rest1, Rest2, Rest3);
mask_match(<<>>, <<>>, <<>>) ->
    true.

-spec create_flow_entry(ofp_flow_mod(), integer()) -> #flow_entry{}.
create_flow_entry(#ofp_flow_mod{priority = Priority,
                            cookie = Cookie,
                            match = Match,
                            instructions = Instructions},
                  FlowTableId) ->
    FlowEntry = #flow_entry{priority = Priority,
                            cookie = Cookie,
                            match = Match,
                            install_time = erlang:now(),
                            instructions = Instructions},
    ets:insert(flow_entry_counters,
               #flow_entry_counter{key = {FlowTableId, FlowEntry}}),
    FlowEntry.

has_priority_overlap(Flags, Priority, Tables) ->
    lists:member(check_overlap, Flags)
    andalso
    lists:any(fun(Table) ->
                  lists:keymember(Priority, #flow_entry.priority,
                                  Table#flow_table.entries)
              end, Tables).

%%% Routing functions ----------------------------------------------------------

-spec do_route(#ofs_pkt{}, integer()) -> route_result().
do_route(Pkt, FlowId) ->
    case apply_flow(Pkt, FlowId) of
        {match, goto, NextFlowId, NewPkt} ->
            do_route(NewPkt, NextFlowId);
        {match, output, NewPkt} ->
            apply_action_set(FlowId, NewPkt#ofs_pkt.actions, NewPkt),
            output;
        {match, group, NewPkt} ->
            apply_action_set(FlowId, NewPkt#ofs_pkt.actions, NewPkt),
            output;
        {match, drop, _NewPkt} ->
            drop;
        {table_miss, controller} ->
            route_to_controller(FlowId, Pkt, no_match),
            controller;
        {table_miss, drop} ->
            drop;
        {table_miss, continue, NextFlowId} ->
            do_route(Pkt, NextFlowId)
    end.

-type miss() :: tuple(table_miss, drop | controller) |
                tuple(table_miss, continue, integer()).

-spec apply_flow(#ofs_pkt{}, #flow_entry{}) -> match() | miss().
apply_flow(Pkt, FlowId) ->
    [FlowTable] = ets:lookup(flow_tables, FlowId),
    FlowTableId = FlowTable#flow_table.id,
    case match_flow_entries(Pkt, FlowTableId, FlowTable#flow_table.entries) of
        {match, goto, NextFlowId, NewPkt} ->
            update_flow_table_match_counters(FlowTableId),
            {match, goto, NextFlowId, NewPkt};
        {match, Action, NewPkt} ->
            update_flow_table_match_counters(FlowTableId),
            {match, Action, NewPkt};
        table_miss when FlowTable#flow_table.config == drop ->
            update_flow_table_miss_counters(FlowTableId),
            {table_miss, drop};
        table_miss when FlowTable#flow_table.config == controller ->
            update_flow_table_miss_counters(FlowTableId),
            {table_miss, controller};
        table_miss when FlowTable#flow_table.config == continue ->
            update_flow_table_miss_counters(FlowTableId),
            {table_miss, continue, FlowId + 1}
    end.

-spec update_flow_table_match_counters(integer()) -> [integer()].
update_flow_table_match_counters(FlowTableId) ->
    ets:update_counter(flow_table_counters, FlowTableId,
                       [{#flow_table_counter.packet_lookups, 1},
                        {#flow_table_counter.packet_matches, 1}]).

-spec update_flow_table_miss_counters(integer()) -> [integer()].
update_flow_table_miss_counters(FlowTableId) ->
    ets:update_counter(flow_table_counters, FlowTableId,
                       [{#flow_table_counter.packet_lookups, 1}]).

-spec update_flow_entry_counters(integer(), #flow_entry{}, integer())
                                -> [integer()].
update_flow_entry_counters(FlowTableId, FlowEntry, PktSize) ->
    ets:update_counter(flow_entry_counters,
                       {FlowTableId, FlowEntry},
                       [{#flow_entry_counter.received_packets, 1},
                        {#flow_entry_counter.received_bytes, PktSize}]).

-spec match_flow_entries(#ofs_pkt{}, integer(), list(#flow_entry{}))
                        -> match() | table_miss.
match_flow_entries(Pkt, FlowTableId, [FlowEntry | Rest]) ->
    case match_flow_entry(Pkt, FlowTableId, FlowEntry) of
        {match, goto, NextFlowId, NewPkt} ->
            update_flow_entry_counters(FlowTableId,
                                       FlowEntry,
                                       Pkt#ofs_pkt.size),
            {match, goto, NextFlowId, NewPkt};
        {match, Action, NewPkt} ->
            update_flow_entry_counters(FlowTableId,
                                       FlowEntry,
                                       Pkt#ofs_pkt.size),
            {match, Action, NewPkt};
        nomatch ->
            match_flow_entries(Pkt, FlowTableId, Rest)
    end;
match_flow_entries(_Pkt, _FlowTableId, []) ->
    table_miss.

-spec match_flow_entry(#ofs_pkt{}, integer(), #flow_entry{})
                      -> match() | nomatch.
match_flow_entry(Pkt, FlowTableId, FlowEntry) ->
    case fields_match(Pkt#ofs_pkt.fields#ofp_match.oxm_fields,
                      FlowEntry#flow_entry.match#ofp_match.oxm_fields) of
        true ->
            apply_instructions(FlowTableId,
                               FlowEntry#flow_entry.instructions,
                               Pkt,
                               output_or_group);
        false ->
            nomatch
    end.

-spec fields_match(list(#ofp_field{}), list(#ofp_field{})) -> boolean().
fields_match(PktFields, FlowFields) ->
    lists:all(fun(#ofp_field{field = F1} = PktField) ->
                  %% TODO: check for class other than openflow_basic
                  lists:all(fun(#ofp_field{field = F2} = FlowField) ->
                                F1 =/= F2 %% field is not relevant here
                                orelse
                                two_fields_match(PktField, FlowField)
                            end, FlowFields)
              end, PktFields).


two_fields_match(#ofp_field{value=Val},
                 #ofp_field{value=Val, has_mask = false}) ->
    true;
two_fields_match(#ofp_field{value=Val1},
                 #ofp_field{value=Val2, has_mask = true, mask = Mask}) ->
    mask_match(Val1, Val2, Mask);
two_fields_match(_, _) ->
    false.

port_match(_, _) ->
    true. %% FIXME: implement

group_match(_, _) ->
    true. %% FIXME: implement

cookie_match(#flow_entry{cookie = Cookie1}, Cookie2, CookieMask) ->
    mask_match(Cookie1, Cookie2, CookieMask).

-type match() :: tuple(match, output | group | drop, #ofs_pkt{}) |
                 tuple(match, goto, integer(), #ofs_pkt{}).

-spec apply_instructions(integer(),
                         list(of_protocol:instruction()),
                         #ofs_pkt{},
                         output_or_group | {goto, integer()}) -> match().
apply_instructions(TableId,
                   [#ofp_instruction_apply_actions{actions = Actions} | Rest],
                   Pkt,
                   NextStep) ->
    NewPkt = apply_action_list(TableId, Actions, Pkt),
    apply_instructions(TableId, Rest, NewPkt, NextStep);
apply_instructions(TableId,
                   [#ofp_instruction_clear_actions{} | Rest],
                   Pkt,
                   NextStep) ->
    apply_instructions(TableId, Rest, Pkt#ofs_pkt{actions = []}, NextStep);
apply_instructions(TableId,
                   [#ofp_instruction_write_actions{actions = Actions} | Rest],
                   #ofs_pkt{actions = OldActions} = Pkt,
                   NextStep) ->
    UActions = lists:ukeysort(2, Actions),
    NewActions = lists:ukeymerge(2, UActions, OldActions),
    apply_instructions(TableId, Rest, Pkt#ofs_pkt{actions = NewActions},
                       NextStep);
apply_instructions(TableId,
                   [#ofp_instruction_write_metadata{metadata = Metadata,
                                                metadata_mask = Mask} | Rest],
                   Pkt,
                   NextStep) ->
    MaskedMetadata = apply_mask(Metadata, Mask),
    apply_instructions(TableId, Rest, Pkt#ofs_pkt{metadata = MaskedMetadata},
                       NextStep);
apply_instructions(TableId,
                   [#ofp_instruction_goto_table{table_id = Id} | Rest],
                   Pkt,
                   _NextStep) ->
    apply_instructions(TableId, Rest, Pkt, {goto, Id});
apply_instructions(_TableId, [], Pkt, output_or_group) ->
    case lists:keymember(ofp_action_group, 1, Pkt#ofs_pkt.actions) of
        true ->
            {match, group, Pkt};
        false ->
            case lists:keymember(ofp_action_output, 1, Pkt#ofs_pkt.actions) of
                true ->
                    {match, output, Pkt};
                false ->
                    {match, drop, Pkt}
            end
    end;
apply_instructions(_TableId, [], Pkt, {goto, Id}) ->
    {match, goto, Id, Pkt}.

-spec apply_mask(binary(), binary()) -> binary().
apply_mask(Metadata, _Mask) ->
    Metadata.

-spec apply_action_list(integer(),
                        list(ofp_structures:action()),
                        #ofs_pkt{}) -> #ofs_pkt{}.
apply_action_list(TableId, [#ofp_action_output{port = PortNum} | _Rest], Pkt) ->
    route_to_output(TableId, Pkt, PortNum),
    Pkt;
apply_action_list(_TableId, [#ofp_action_group{group_id = GroupId} | _Rest],
                  Pkt) ->
    apply_group(GroupId, Pkt);
apply_action_list(TableId, [#ofp_action_set_queue{} | Rest], Pkt) ->
    NewPkt = Pkt,
    apply_action_list(TableId, Rest, NewPkt);
apply_action_list(TableId, [#ofp_action_set_mpls_ttl{} | Rest], Pkt) ->
    NewPkt = Pkt,
    apply_action_list(TableId, Rest, NewPkt);
apply_action_list(TableId, [#ofp_action_dec_mpls_ttl{} | Rest], Pkt) ->
    NewPkt = Pkt,
    apply_action_list(TableId, Rest, NewPkt);
apply_action_list(TableId, [#ofp_action_set_nw_ttl{} | Rest], Pkt) ->
    NewPkt = Pkt,
    apply_action_list(TableId, Rest, NewPkt);
apply_action_list(TableId, [#ofp_action_dec_nw_ttl{} | Rest], Pkt) ->
    NewPkt = Pkt,
    apply_action_list(TableId, Rest, NewPkt);
apply_action_list(TableId, [#ofp_action_copy_ttl_out{} | Rest], Pkt) ->
    NewPkt = Pkt,
    apply_action_list(TableId, Rest, NewPkt);
apply_action_list(TableId, [#ofp_action_copy_ttl_in{} | Rest], Pkt) ->
    NewPkt = Pkt,
    apply_action_list(TableId, Rest, NewPkt);
apply_action_list(TableId, [#ofp_action_push_vlan{} | Rest], Pkt) ->
    NewPkt = Pkt,
    apply_action_list(TableId, Rest, NewPkt);
apply_action_list(TableId, [#ofp_action_pop_vlan{} | Rest], Pkt) ->
    NewPkt = Pkt,
    apply_action_list(TableId, Rest, NewPkt);
apply_action_list(TableId, [#ofp_action_push_mpls{} | Rest], Pkt) ->
    NewPkt = Pkt,
    apply_action_list(TableId, Rest, NewPkt);
apply_action_list(TableId, [#ofp_action_pop_mpls{} | Rest], Pkt) ->
    NewPkt = Pkt,
    apply_action_list(TableId, Rest, NewPkt);
apply_action_list(TableId, [#ofp_action_set_field{} | Rest], Pkt) ->
    NewPkt = Pkt,
    apply_action_list(TableId, Rest, NewPkt);
apply_action_list(TableId, [#ofp_action_experimenter{} | Rest], Pkt) ->
    NewPkt = Pkt,
    apply_action_list(TableId, Rest, NewPkt);
apply_action_list(_TableId, [], Pkt) ->
    Pkt.

-spec apply_group(ofp_group_id(), #ofs_pkt{}) -> #ofs_pkt{}.
apply_group(GroupId, Pkt) ->
    [Group] = ets:lookup(group_table, GroupId),
    apply_group_type(Group#group_entry.type, Group#group_entry.buckets, Pkt).

-spec apply_group_type(ofp_group_type(), [#ofs_bucket{}], #ofs_pkt{}) ->
                              #ofs_pkt{}.
apply_group_type(all, Buckets, Pkt) ->
    lists:map(fun(Bucket) ->
                      apply_bucket(Bucket, Pkt)
              end, Buckets);
apply_group_type(select, [Bucket | _Rest], Pkt) ->
    apply_bucket(Bucket, Pkt);
apply_group_type(indirect, [Bucket], Pkt) ->
    apply_bucket(Bucket, Pkt);
apply_group_type(ff, Buckets, Pkt) ->
    case pick_live_bucket(Buckets) of
        false ->
            drop;
        Bucket ->
            apply_bucket(Bucket, Pkt)
    end.

apply_bucket(#ofs_bucket{value = #ofp_bucket{actions = Actions}}, Pkt) ->
    apply_action_list(0, Actions, Pkt).

-spec pick_live_bucket([#ofs_bucket{}]) -> #ofs_bucket{} | false.
pick_live_bucket(Buckets) ->
    %% TODO Implement bucket liveness logic
    hd(Buckets).

-spec apply_action_set(integer(),
                       ordsets:ordset(ofp_structures:action()),
                       #ofs_pkt{}) -> #ofs_pkt{}.
apply_action_set(TableId, [Action | Rest], Pkt) ->
    NewPkt = apply_action_list(TableId, [Action], Pkt),
    apply_action_set(TableId, Rest, NewPkt);
apply_action_set(_TableId, [], Pkt) ->
    Pkt.

-spec route_to_controller(integer(), #ofs_pkt{}, atom()) -> ok.
route_to_controller(TableId,
                    #ofs_pkt{fields = Fields,
                             packet = Packet},
                    Reason) ->
    PacketIn = #ofp_packet_in{buffer_id = ?OFPCML_NO_BUFFER, %% TODO: use no_buffer
                          reason = Reason,
                          table_id = TableId,
                          match = Fields,
                          data = pkt:encapsulate(Packet)},
    ofs_logic:send(#ofp_message{xid = xid(), body = PacketIn}).

-spec route_to_output(integer(), #ofs_pkt{}, integer() | atom()) -> any().
route_to_output(_TableId, Pkt = #ofs_pkt{in_port = InPort}, all) ->
    Ports = ets:tab2list(ofs_ports),
    [ofs_userspace_port:send(PortNum, Pkt)
     || #ofs_port{number = PortNum} <- Ports, PortNum /= InPort];
route_to_output(TableId, Pkt, controller) ->
    route_to_controller(TableId, Pkt, action);
route_to_output(_TableId, _Pkt, table) ->
    %% FIXME: Only valid in an output action in the
    %%        action list of a packet-out message.
    ok;
route_to_output(_TableId, Pkt = #ofs_pkt{in_port = InPort}, in_port) ->
    ofs_userspace_port:send(InPort, Pkt);
route_to_output(_TableId, Pkt, PortNum) when is_integer(PortNum) ->
    ofs_userspace_port:send(PortNum, Pkt);
route_to_output(_TableId, _Pkt, OtherPort) ->
    lager:warning("unsupported port type: ~p", [OtherPort]).

%%% Packet conversion functions ------------------------------------------------

-spec packet_fields([pkt:packet()]) -> [ofp_field()].
packet_fields(Packet) ->
    packet_fields(Packet, []).

-spec packet_fields([pkt:packet()], [ofp_field()]) -> [ofp_field()].
packet_fields([], Fields) ->
    Fields;
packet_fields([#ether{type = Type,
                      dhost = DHost,
                      shost = SHost} | Rest], Fields) ->
    NewFields = [ofp_field(eth_type, <<Type:16>>),
                 ofp_field(eth_dst, DHost),
                 ofp_field(eth_src, SHost)],
    packet_fields(Rest, Fields ++ NewFields);
packet_fields([#ipv4{p = Proto,
                     saddr = SAddr,
                     daddr = DAddr} | Rest], Fields) ->
    NewFields = [ofp_field(ip_proto, <<Proto:8>>),
                 ofp_field(ipv4_src, SAddr),
                 ofp_field(ipv4_dst, DAddr)],
    packet_fields(Rest, Fields ++ NewFields);
packet_fields([#ipv6{next = Proto,
                     saddr = SAddr,
                     daddr = DAddr} | Rest], Fields) ->
    NewFields = [ofp_field(ip_proto, <<Proto:8>>),
                 ofp_field(ipv6_src, SAddr),
                 ofp_field(ipv6_dst, DAddr)],
    packet_fields(Rest, Fields ++ NewFields);
packet_fields([#tcp{sport = SPort,
                    dport = DPort} | Rest], Fields) ->
    NewFields = [ofp_field(tcp_src, <<SPort:16>>),
                 ofp_field(tcp_dst, <<DPort:16>>)],
    packet_fields(Rest, Fields ++ NewFields);
packet_fields([#udp{sport = SPort,
                    dport = DPort} | Rest], Fields) ->
    NewFields = [ofp_field(udp_src, <<SPort:16>>),
                 ofp_field(udp_dst, <<DPort:16>>)],
    packet_fields(Rest, Fields ++ NewFields);
packet_fields([_Other | Rest], Fields) ->
    packet_fields(Rest, Fields).

-spec ofp_field(atom(), binary() | integer()) -> ofp_field().
ofp_field(Field, Value) ->
    #ofp_field{class = openflow_basic,
               field = Field,
               has_mask = false,
               value = Value}.
