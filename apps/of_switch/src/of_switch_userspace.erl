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
         pkt_to_ofs/1
        ]).

%% Spawns
-export([do_route/2]).

%% gen_switch callbacks
-export([start/1, modify_flow/2, modify_table/2, modify_port/2, modify_group/2,
         echo_request/2, barrier_request/2, get_desc_stats/2, get_flow_stats/2,
         get_aggregate_stats/2, get_table_stats/2, get_port_stats/2,
         get_queue_stats/2, get_group_stats/2, get_group_desc_stats/2,
         get_group_features_stats/2, stop/1]).

-include_lib("pkt/include/pkt.hrl").
-include_lib("of_protocol/include/of_protocol.hrl").
-include("of_switch_userspace.hrl").

-record(state, {}).

-type state() :: #state{}.
-type route_result() :: drop | controller | output.

%%%-----------------------------------------------------------------------------
%%% Switch API
%%%-----------------------------------------------------------------------------

-spec route(#ofs_pkt{}) -> route_result().
route(Pkt) ->
    proc_lib:spawn_link(?MODULE, do_route, [Pkt, 0]).

-spec add_port(ofs_port_type(), integer()) -> ok.
add_port(physical, PortNumber) ->
    {ok, Pid} = supervisor:start_child(ofs_userspace_port_sup, []),
    OfsPort = #ofs_port{number = PortNumber,
                        type = physical,
                        handle = Pid
                       },
    ets:insert(ofs_ports, OfsPort);
add_port(logical, _PortNumber) ->
    ok;
add_port(reserved, _PortNumber) ->
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

-spec pkt_to_ofs([record()]) -> #ofs_pkt{}.
pkt_to_ofs(Packet) ->
    #ofs_pkt{fields = #match{type = oxm,
                             oxm_fields = packet_fields(Packet)}}.

%%%-----------------------------------------------------------------------------
%%% gen_switch callbacks
%%%-----------------------------------------------------------------------------

%% @doc Start the switch.
-spec start(any()) -> {ok, state()}.
start(_Opts) ->
    flow_tables = ets:new(flow_tables, [named_table,
                                        {keypos, #flow_table.id},
                                        {read_concurrency, true}]),
    flow_table_counters = ets:new(flow_table_counters,
                                  [named_table, public,
                                   {keypos, #flow_table_counter.id},
                                   {read_concurrency, true}]),
    flow_entry_counters = ets:new(flow_entry_counters,
                                  [named_table, public,
                                   {keypos, #flow_entry_counter.key},
                                   {read_concurrency, true}]),
    ofs_ports = ets:new(ofs_ports, [named_table,
                                    {keypos, #ofs_port.number},
                                    {read_concurrency, true}]),
    ets:insert(flow_tables, [#flow_table{id = Id,
                                         entries = [],
                                         config = drop}
                             || Id <- lists:seq(0, ?OFPTT_MAX)]),
    ets:insert(flow_table_counters, [#flow_table_counter{id = Id}
                                     || Id <- lists:seq(0, ?OFPTT_MAX)]),
    {ok, #state{}}.

%% @doc Stop the switch.
-spec stop(state()) -> any().
stop(_State) ->
    ets:delete(flow_tables),
    ets:delete(flow_table_counters),
    ets:delete(flow_entry_counters),
    ets:delete(ofs_ports),
    ok.

%% @doc Modify flow entry in the flow table.
modify_flow(State, #flow_mod{command = add,
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
            {error, overlap, State};
        false ->
            lists:foreach(AddFlowEntry, Tables),
            {ok, State}
    end;
modify_flow(State, #flow_mod{command = modify,
                             table_id = TableId} = FlowMod) ->
    modify_entries(TableId, FlowMod, fun non_strict_match/2),
    {ok, State};
modify_flow(State, #flow_mod{command = modify_strict,
                             table_id = TableId} = FlowMod) ->
    modify_entries(TableId, FlowMod, fun strict_match/2),
    {ok, State};
modify_flow(State, #flow_mod{command = delete,
                             table_id = TableId} = FlowMod) ->
    delete_entries(TableId, FlowMod, fun non_strict_match/2),
    {ok, State};
modify_flow(State, #flow_mod{command = delete_strict,
                             table_id = TableId} = FlowMod) ->
    delete_entries(TableId, FlowMod, fun strict_match/2),
    {ok, State}.

%% @doc Modify flow table configuration.
-spec modify_table(state(), table_mod()) ->
      {ok, #state{}} | {error, atom(), #state{}}.
modify_table(State, #table_mod{} = _TableMod) ->
    {ok, State}.

%% @doc Modify port configuration.
-spec modify_port(state(), port_mod()) ->
      {ok, #state{}} | {error, atom(), #state{}}.
modify_port(State, #port_mod{} = _PortMod) ->
    {ok, State}.

%% @doc Modify group entry in the group table.
-spec modify_group(state(), group_mod()) ->
      {ok, #state{}} | {error, atom(), #state{}}.
modify_group(State, #group_mod{} = _GroupMod) ->
    {ok, State}.

%% @doc Reply to echo request.
-spec echo_request(state(), echo_request()) ->
      {ok, #echo_reply{}, #state{}} | {error, atom(), #state{}}.
echo_request(State, #echo_request{header = Header, data = Data}) ->
    EchoReply = #echo_reply{header = Header, data = Data},
    {ok, EchoReply, State}.

%% @doc Reply to barrier request.
-spec barrier_request(state(), barrier_request()) ->
      {ok, #echo_reply{}, #state{}} | {error, atom(), #state{}}.
barrier_request(State, #barrier_request{header = Header}) ->
    BarrierReply = #barrier_reply{header = Header},
    {ok, BarrierReply, State}.

%% @doc Get switch description statistics.
-spec get_desc_stats(state(), desc_stats_request()) ->
      {ok, desc_stats_reply(), #state{}} | {error, atom(), #state{}}.
get_desc_stats(State, #desc_stats_request{}) ->
    {ok, #desc_stats_reply{}, State}.

%% @doc Get flow entry statistics.
-spec get_flow_stats(state(), flow_stats_request()) ->
      {ok, flow_stats_reply(), #state{}} | {error, atom(), #state{}}.
get_flow_stats(State, #flow_stats_request{}) ->
    {ok, #flow_stats_reply{}, State}.

%% @doc Get aggregated flow statistics.
-spec get_aggregate_stats(state(), aggregate_stats_request()) ->
      {ok, aggregate_stats_reply(), #state{}} | {error, atom(), #state{}}.
get_aggregate_stats(State, #aggregate_stats_request{}) ->
    {ok, #aggregate_stats_reply{}, State}.

%% @doc Get flow table statistics.
-spec get_table_stats(state(), table_stats_request()) ->
      {ok, table_stats_reply(), #state{}} | {error, atom(), #state{}}.
get_table_stats(State, #table_stats_request{}) ->
    {ok, #table_stats_reply{}, State}.

%% @doc Get port statistics.
-spec get_port_stats(state(), port_stats_request()) ->
      {ok, port_stats_reply(), #state{}} | {error, atom(), #state{}}.
get_port_stats(State, #port_stats_request{}) ->
    {ok, #port_stats_reply{}, State}.

%% @doc Get queue statistics.
-spec get_queue_stats(state(), queue_stats_request()) ->
      {ok, queue_stats_reply(), #state{}} | {error, atom(), #state{}}.
get_queue_stats(State, #queue_stats_request{}) ->
    {ok, #queue_stats_reply{}, State}.

%% @doc Get group statistics.
-spec get_group_stats(state(), group_stats_request()) ->
      {ok, group_stats_reply(), #state{}} | {error, atom(), #state{}}.
get_group_stats(State, #group_stats_request{}) ->
    {ok, #group_stats_reply{}, State}.

%% @doc Get group description statistics.
-spec get_group_desc_stats(state(), group_desc_stats_request()) ->
      {ok, group_desc_stats_reply(), #state{}} | {error, atom(), #state{}}.
get_group_desc_stats(State, #group_desc_stats_request{}) ->
    {ok, #group_desc_stats_reply{}, State}.

%% @doc Get group features statistics.
-spec get_group_features_stats(state(), group_features_stats_request()) ->
      {ok, group_features_stats_reply(), #state{}} | {error, atom(), #state{}}.
get_group_features_stats(State, #group_features_stats_request{}) ->
    {ok, #group_features_stats_reply{}, State}.

%%%-----------------------------------------------------------------------------
%%% Helpers
%%%-----------------------------------------------------------------------------

-spec get_flow_tables(integer() | all) -> [#flow_table{}].
get_flow_tables(all) ->
    ets:tab2list(flow_tables);
get_flow_tables(TableId) when is_integer(TableId) ->
    ets:lookup(flow_tables, TableId).

modify_entries(TableId, FlowMod, MatchFun) ->
    lists:foreach(
        fun(#flow_table{entries = Entries} = Table) ->
            NewEntries = [modify_flow_entry(Entry, FlowMod, MatchFun)
                          || Entry <- Entries],
            ets:insert(flow_tables, Table#flow_table{entries = NewEntries})
        end, get_flow_tables(TableId)).

modify_flow_entry(#flow_entry{} = Entry,
                  #flow_mod{} = FlowMod,
                  MatchFun) ->
    case MatchFun(Entry, FlowMod) of
        true ->
            %% FIXME: implement
            do_the_work;
        false ->
            Entry
    end.

delete_entries(TableId, FlowMod, MatchFun) ->
    lists:foreach(
        fun(#flow_table{entries = Entries} = Table) ->
            NewEntries = lists:filter(fun(Entry) ->
                                          not MatchFun(Entry, FlowMod)
                                      end, Entries),
            ets:insert(flow_tables, Table#flow_table{entries = NewEntries})
        end, get_flow_tables(TableId)).

strict_match(#flow_entry{}, #flow_mod{}) ->
    %% FIXME: non implemented
    false.

non_strict_match(#flow_entry{}, #flow_mod{}) ->
    %% FIXME: non implemented
    false.

create_flow_entry(#flow_mod{priority = Priority,
                            match = Match,
                            instructions = Instructions},
                  FlowTableId) ->
    FlowEntry = #flow_entry{priority = Priority,
                            match = Match,
                            instructions = Instructions},
    ets:insert(flow_entry_counters,
               #flow_entry_counter{key = {FlowTableId, FlowEntry},
                                   install_time = erlang:universaltime()}),
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
            case lists:keymember(action_output, 1, NewPkt#ofs_pkt.actions) of
                true ->
                    apply_action_set(NewPkt#ofs_pkt.actions, NewPkt),
                    output;
                false ->
                    drop
            end;
        {table_miss, controller} ->
            route_to_controller(Pkt),
            controller;
        {table_miss, drop} ->
            drop;
        {table_miss, continue, NextFlowId} ->
            do_route(Pkt, NextFlowId)
    end.

-spec apply_flow(#ofs_pkt{}, #flow_entry{}) -> tuple().
apply_flow(Pkt, FlowId) ->
    [FlowTable] = ets:lookup(flow_tables, FlowId),
    case match_flow_entries(Pkt,
                            FlowTable#flow_table.id,
                            FlowTable#flow_table.entries) of
        {match, goto, NextFlowId, NewPkt} ->
            update_flow_table_match_counters(FlowTable#flow_table.id),
            {match, goto, NextFlowId, NewPkt};
        {match, output, NewPkt} ->
            update_flow_table_match_counters(FlowTable#flow_table.id),
            {match, output, NewPkt};
        table_miss when FlowTable#flow_table.config == drop ->
            update_flow_table_miss_counters(FlowTable#flow_table.id),
            {table_miss, drop};
        table_miss when FlowTable#flow_table.config == controller ->
            update_flow_table_miss_counters(FlowTable#flow_table.id),
            {table_miss, controller};
        table_miss when FlowTable#flow_table.config == continue ->
            update_flow_table_miss_counters(FlowTable#flow_table.id),
            {table_miss, continue, FlowId + 1}
    end.

-spec update_flow_table_match_counters(integer()) -> ok.
update_flow_table_match_counters(FlowTableId) ->
    ets:update_counter(flow_table_counters, FlowTableId,
                       [{#flow_table_counter.packet_lookups, 1},
                        {#flow_table_counter.packet_matches, 1}]).

-spec update_flow_table_miss_counters(integer()) -> ok.
update_flow_table_miss_counters(FlowTableId) ->
    ets:update_counter(flow_table_counters, FlowTableId,
                       [{#flow_table_counter.packet_lookups, 1}]).

-spec update_flow_entry_counters(integer(), #flow_entry{}, integer()) -> ok.
update_flow_entry_counters(FlowTableId, FlowEntry, PktSize) ->
    ets:update_counter(flow_entry_counters,
                       {FlowTableId, FlowEntry},
                       [{#flow_entry_counter.received_packets, 1},
                        {#flow_entry_counter.received_bytes, PktSize}]).

-spec match_flow_entries(#ofs_pkt{}, integer(), list(#flow_entry{}))
                        -> tuple() | nomatch.
match_flow_entries(Pkt, FlowTableId, [FlowEntry | Rest]) ->
    case match_flow_entry(Pkt, FlowEntry) of
        {match, goto, NextFlowId, NewPkt} ->
            update_flow_entry_counters(FlowTableId,
                                       FlowEntry,
                                       Pkt#ofs_pkt.size),
            {match, goto, NextFlowId, NewPkt};
        {match, output, NewPkt} ->
            update_flow_entry_counters(FlowTableId,
                                       FlowEntry,
                                       Pkt#ofs_pkt.size),
            {match, output, NewPkt};
        nomatch ->
            match_flow_entries(Pkt, FlowTableId, Rest)
    end;
match_flow_entries(_Pkt, _FlowTableId, []) ->
    table_miss.

-spec match_flow_entry(#ofs_pkt{}, #flow_entry{}) -> match | nomatch.
match_flow_entry(Pkt, FlowEntry) ->
    case match_fields(Pkt#ofs_pkt.fields#match.oxm_fields,
                      FlowEntry#flow_entry.match#match.oxm_fields) of
        match ->
            case apply_instructions(FlowEntry#flow_entry.instructions,
                                    Pkt,
                                    output) of
                {NewPkt, goto, NextFlowId} ->
                    {match, goto, NextFlowId, NewPkt};
                {NewPkt, output} ->
                    {match, output, NewPkt}
            end;
        nomatch ->
            nomatch
    end.

-spec match_fields(list(#oxm_field{}), list(#oxm_field{})) -> match | nomatch.
match_fields(PktFields, [FlowField | FlowRest]) ->
    case has_field(FlowField, PktFields) of
        true ->
            match_fields(PktFields, FlowRest);
        false ->
            nomatch
    end;
match_fields(_PktFields, []) ->
    match.

-spec has_field(#oxm_field{}, list(#oxm_field{})) -> boolean().
has_field(Field, List) ->
    lists:member(Field, List).

-spec apply_instructions(list(of_protocol:instruction()),
                         #ofs_pkt{},
                         output | {goto, integer()}) -> tuple().
apply_instructions([#instruction_apply_actions{actions = Actions} | Rest],
                   Pkt,
                   NextStep) ->
    NewPkt = apply_action_list(Actions, Pkt),
    apply_instructions(Rest, NewPkt, NextStep);
apply_instructions([#instruction_clear_actions{} | Rest], Pkt, NextStep) ->
    apply_instructions(Rest, Pkt#ofs_pkt{actions = []}, NextStep);
apply_instructions([#instruction_write_actions{actions = Actions} | Rest],
                   #ofs_pkt{actions = OldActions} = Pkt,
                   NextStep) ->
    UActions = lists:ukeysort(2, Actions),
    NewActions = lists:ukeymerge(2, UActions, OldActions),
    apply_instructions(Rest, Pkt#ofs_pkt{actions = NewActions}, NextStep);
apply_instructions([#instruction_write_metadata{metadata = Metadata,
                                                metadata_mask = Mask} | Rest],
                   Pkt,
                   NextStep) ->
    MaskedMetadata = apply_mask(Metadata, Mask),
    apply_instructions(Rest, Pkt#ofs_pkt{metadata = MaskedMetadata}, NextStep);
apply_instructions([#instruction_goto_table{table_id = Id} | Rest],
                   Pkt,
                   _NextStep) ->
    apply_instructions(Rest, Pkt, {goto, Id});
apply_instructions([], Pkt, output) ->
    {Pkt, output};
apply_instructions([], Pkt, {goto, Id}) ->
    {Pkt, goto, Id}.

-spec apply_mask(binary(), binary()) -> binary().
apply_mask(Metadata, _Mask) ->
    Metadata.

-spec apply_action_list(list(ofp_structures:action()), #ofs_pkt{}) -> #ofs_pkt{}.
apply_action_list([#action_output{} = Output | Rest], Pkt) ->
    route_to_output(Output, Pkt),
    apply_action_list(Rest, Pkt);
apply_action_list([#action_group{} | Rest], Pkt) ->
    NewPkt = Pkt,
    apply_action_list(Rest, NewPkt);
apply_action_list([#action_set_queue{} | Rest], Pkt) ->
    NewPkt = Pkt,
    apply_action_list(Rest, NewPkt);
apply_action_list([#action_set_mpls_ttl{} | Rest], Pkt) ->
    NewPkt = Pkt,
    apply_action_list(Rest, NewPkt);
apply_action_list([#action_dec_mpls_ttl{} | Rest], Pkt) ->
    NewPkt = Pkt,
    apply_action_list(Rest, NewPkt);
apply_action_list([#action_set_nw_ttl{} | Rest], Pkt) ->
    NewPkt = Pkt,
    apply_action_list(Rest, NewPkt);
apply_action_list([#action_dec_nw_ttl{} | Rest], Pkt) ->
    NewPkt = Pkt,
    apply_action_list(Rest, NewPkt);
apply_action_list([#action_copy_ttl_out{} | Rest], Pkt) ->
    NewPkt = Pkt,
    apply_action_list(Rest, NewPkt);
apply_action_list([#action_copy_ttl_in{} | Rest], Pkt) ->
    NewPkt = Pkt,
    apply_action_list(Rest, NewPkt);
apply_action_list([#action_push_vlan{} | Rest], Pkt) ->
    NewPkt = Pkt,
    apply_action_list(Rest, NewPkt);
apply_action_list([#action_pop_vlan{} | Rest], Pkt) ->
    NewPkt = Pkt,
    apply_action_list(Rest, NewPkt);
apply_action_list([#action_push_mpls{} | Rest], Pkt) ->
    NewPkt = Pkt,
    apply_action_list(Rest, NewPkt);
apply_action_list([#action_pop_mpls{} | Rest], Pkt) ->
    NewPkt = Pkt,
    apply_action_list(Rest, NewPkt);
apply_action_list([#action_set_field{} | Rest], Pkt) ->
    NewPkt = Pkt,
    apply_action_list(Rest, NewPkt);
apply_action_list([#action_experimenter{} | Rest], Pkt) ->
    NewPkt = Pkt,
    apply_action_list(Rest, NewPkt);
apply_action_list([], Pkt) ->
    Pkt.

-spec apply_action_set(ordsets:ordset(ofp_structures:action()), #ofs_pkt{})
                      -> #ofs_pkt{}.
apply_action_set([Action | Rest], Pkt) ->
    NewPkt = apply_action_list([Action], Pkt),
    apply_action_set(Rest, NewPkt);
apply_action_set([], Pkt) ->
    Pkt.

-spec route_to_controller(#ofs_pkt{}) -> ok.
route_to_controller(_Pkt) ->
    ok.

-spec route_to_output(#action_output{}, #ofs_pkt{}) -> ok.
route_to_output(_Output, _Pkt) ->
    ok.

%%% Packet conversion functions ------------------------------------------------

-spec packet_fields([record()]) -> [oxm_field()].
packet_fields(Packet) ->
    packet_fields(Packet, []).

-spec packet_fields([record()], [oxm_field()]) -> [oxm_field()].
packet_fields([], Fields) ->
    Fields;
packet_fields([#ether{type = Type,
                      dhost = DHost,
                      shost = SHost} | Rest], Fields) ->
    NewFields = [oxm_field(eth_type, Type),
                 oxm_field(eth_dst, DHost),
                 oxm_field(eth_src, SHost)],
    packet_fields(Rest, Fields ++ NewFields);
packet_fields([#ipv4{p = Proto,
                     saddr = SAddr,
                     daddr = DAddr} | Rest], Fields) ->
    NewFields = [oxm_field(ip_proto, Proto),
                 oxm_field(ipv4_src, SAddr),
                 oxm_field(ipv4_dst, DAddr)],
    packet_fields(Rest, Fields ++ NewFields);
packet_fields([#ipv6{next = Proto,
                     saddr = SAddr,
                     daddr = DAddr} | Rest], Fields) ->
    NewFields = [oxm_field(ip_proto, Proto),
                 oxm_field(ipv6_src, SAddr),
                 oxm_field(ipv6_dst, DAddr)],
    packet_fields(Rest, Fields ++ NewFields);
packet_fields([#tcp{sport = SPort,
                    dport = DPort} | Rest], Fields) ->
    NewFields = [oxm_field(tcp_src, SPort),
                 oxm_field(tcp_dst, DPort)],
    packet_fields(Rest, Fields ++ NewFields);
packet_fields([#udp{sport = SPort,
                    dport = DPort} | Rest], Fields) ->
    NewFields = [oxm_field(udp_src, SPort),
                 oxm_field(udp_dst, DPort)],
    packet_fields(Rest, Fields ++ NewFields);
packet_fields([_Other | Rest], Fields) ->
    packet_fields(Rest, Fields).

-spec oxm_field(atom(), binary() | integer()) -> oxm_field().
oxm_field(Field, Value) ->
    #oxm_field{class = openflow_basic,
               field = Field,
               has_mask = false,
               value = Value}.
