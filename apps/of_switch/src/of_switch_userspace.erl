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
         modify_flow/2,
         modify_table/2,
         modify_port/2,
         modify_group/2,
         packet_out/2,
         echo_request/2,
         barrier_request/2,
         get_desc_stats/2,
         get_flow_stats/2,
         get_aggregate_stats/2,
         get_table_stats/2,
         get_port_stats/2,
         get_queue_stats/2,
         get_group_stats/2,
         get_group_desc_stats/2,
         get_group_features_stats/2,
         stop/1]).

-include_lib("pkt/include/pkt.hrl").
-include_lib("of_protocol/include/of_protocol.hrl").
-include("of_switch.hrl").
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

-spec add_port(ofs_port_type(), list(tuple(interface |
                                           ofs_port_num |
                                           ip, string()))) -> ok.
add_port(physical, Opts) ->
    {ok, _Pid} = supervisor:start_child(ofs_userspace_port_sup, [Opts]);
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

-spec pkt_to_ofs([record()], integer()) -> #ofs_pkt{}.
pkt_to_ofs(Packet, PortNum) ->
    #ofs_pkt{packet = Packet,
             fields = #match{type = oxm,
                             oxm_fields = [oxm_field(in_port, PortNum) |
                                           packet_fields(Packet)]},
             in_port = PortNum}.

%%%-----------------------------------------------------------------------------
%%% gen_switch callbacks
%%%-----------------------------------------------------------------------------

%% @doc Start the switch.
-spec start(any()) -> {ok, state()}.
start(_Opts) ->
    flow_tables = ets:new(flow_tables, [named_table,
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
            OverlapError = #error_msg{type = flow_mod_failed,
                                      code = overlap},
            {error, OverlapError, State};
        false ->
            lists:foreach(AddFlowEntry, Tables),
            {ok, State}
    end;
modify_flow(State, #flow_mod{command = modify} = FlowMod) ->
    apply_flow_mod(State, FlowMod, fun modify_entries/2,
                   fun non_strict_match/2);
modify_flow(State, #flow_mod{command = modify_strict} = FlowMod) ->
    apply_flow_mod(State, FlowMod, fun modify_entries/2,
                   fun strict_match/2);
modify_flow(State, #flow_mod{command = delete} = FlowMod) ->
    apply_flow_mod(State, FlowMod, fun delete_entries/2,
                   fun non_strict_match/2);
modify_flow(State, #flow_mod{command = delete_strict} = FlowMod) ->
    apply_flow_mod(State, FlowMod, fun delete_entries/2,
                   fun strict_match/2).

%% @doc Modify flow table configuration.
-spec modify_table(state(), table_mod()) ->
      {ok, #state{}} | {error, error_msg(), #state{}}.
modify_table(State, #table_mod{table_id = TableId, config = Config}) ->
    lists:foreach(fun(FlowTable) ->
        ets:insert(flow_tables, FlowTable#flow_table{config = Config})
    end, get_flow_tables(TableId)),
    {ok, State}.

%% @doc Modify port configuration.
-spec modify_port(state(), port_mod()) ->
      {ok, #state{}} | {error, error_msg(), #state{}}.
modify_port(State, #port_mod{port_no = PortNo} = PortMod) ->
    case ofs_userspace_port:change_config(PortNo, PortMod) of
        {error, Code} ->
            Error = #error_msg{type = port_mod_failed,
                               code = Code},
            {error, Error, State};
        ok ->
            {ok, State}
    end.

%% @doc Send packet to controller
-spec packet_out(state(), packet_out()) ->
      {ok, #state{}} | {error, error_msg(), #state{}}.
packet_out(State, #packet_out{actions = Actions,
                              in_port = InPort,
                              data = Data}) ->
    Pkt = pkt:decapsulate(Data),
    apply_action_list(Actions, pkt_to_ofs(Pkt, InPort)),
    {ok, State}.

%% @doc Modify group entry in the group table.
-spec modify_group(state(), group_mod()) ->
      {ok, #state{}} | {error, error_msg(), #state{}}.
modify_group(State, #group_mod{} = _GroupMod) ->
    {ok, State}.

%% @doc Reply to echo request.
-spec echo_request(state(), echo_request()) ->
      {ok, #echo_reply{}, #state{}} | {error, error_msg(), #state{}}.
echo_request(State, #echo_request{header = Header, data = Data}) ->
    EchoReply = #echo_reply{header = Header, data = Data},
    {ok, EchoReply, State}.

%% @doc Reply to barrier request.
-spec barrier_request(state(), barrier_request()) ->
      {ok, #echo_reply{}, #state{}} | {error, error_msg(), #state{}}.
barrier_request(State, #barrier_request{header = Header}) ->
    BarrierReply = #barrier_reply{header = Header},
    {ok, BarrierReply, State}.

%% @doc Get switch description statistics.
-spec get_desc_stats(state(), desc_stats_request()) ->
      {ok, desc_stats_reply(), #state{}} | {error, error_msg(), #state{}}.
get_desc_stats(State, #desc_stats_request{}) ->
    {ok, #desc_stats_reply{}, State}.

%% @doc Get flow entry statistics.
-spec get_flow_stats(state(), flow_stats_request()) ->
      {ok, flow_stats_reply(), #state{}} | {error, error_msg(), #state{}}.
get_flow_stats(State, #flow_stats_request{}) ->
    %% NOTE: re-use the logic from non_strict_match (spec, page 23)
    {ok, #flow_stats_reply{}, State}.

%% @doc Get aggregated flow statistics.
-spec get_aggregate_stats(state(), aggregate_stats_request()) ->
      {ok, aggregate_stats_reply(), #state{}} | {error, error_msg(), #state{}}.
get_aggregate_stats(State, #aggregate_stats_request{}) ->
    {ok, #aggregate_stats_reply{}, State}.

%% @doc Get flow table statistics.
-spec get_table_stats(state(), table_stats_request()) ->
      {ok, table_stats_reply(), #state{}} | {error, error_msg(), #state{}}.
get_table_stats(State, #table_stats_request{}) ->
    {ok, #table_stats_reply{}, State}.

%% @doc Get port statistics.
-spec get_port_stats(state(), port_stats_request()) ->
      {ok, port_stats_reply(), #state{}} | {error, error_msg(), #state{}}.
get_port_stats(State, #port_stats_request{}) ->
    {ok, #port_stats_reply{}, State}.

%% @doc Get queue statistics.
-spec get_queue_stats(state(), queue_stats_request()) ->
      {ok, queue_stats_reply(), #state{}} | {error, error_msg(), #state{}}.
get_queue_stats(State, #queue_stats_request{}) ->
    {ok, #queue_stats_reply{}, State}.

%% @doc Get group statistics.
-spec get_group_stats(state(), group_stats_request()) ->
      {ok, group_stats_reply(), #state{}} | {error, error_msg(), #state{}}.
get_group_stats(State, #group_stats_request{}) ->
    {ok, #group_stats_reply{}, State}.

%% @doc Get group description statistics.
-spec get_group_desc_stats(state(), group_desc_stats_request()) ->
      {ok, group_desc_stats_reply(), #state{}} | {error, error_msg(), #state{}}.
get_group_desc_stats(State, #group_desc_stats_request{}) ->
    {ok, #group_desc_stats_reply{}, State}.

%% @doc Get group features statistics.
-spec get_group_features_stats(state(), group_features_stats_request()) ->
      {ok, group_features_stats_reply(), #state{}} | {error, error_msg(), #state{}}.
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

apply_flow_mod(State, FlowMod, ModFun, MatchFun) ->
    try
        ModFun(FlowMod, MatchFun),
        {ok, State}
    catch #error_msg{} = Error ->
        {error, Error, State}
    end.

modify_entries(#flow_mod{table_id = TableId} = FlowMod, MatchFun) ->
    lists:foreach(
        fun(#flow_table{entries = Entries} = Table) ->
            NewEntries = [modify_flow_entry(Entry, FlowMod, MatchFun)
                          || Entry <- Entries],
            ets:insert(flow_tables, Table#flow_table{entries = NewEntries})
        end, get_flow_tables(TableId)).

modify_flow_entry(#flow_entry{} = Entry,
                  #flow_mod{match = NewMatch,
                            instructions = NewInstructions} = FlowMod,
                  MatchFun) ->
    case MatchFun(Entry, FlowMod) of
        true ->
            Entry#flow_entry{match = NewMatch,
                             instructions = NewInstructions};
        false ->
            Entry
    end.

delete_entries(#flow_mod{table_id = TableId} = FlowMod, MatchFun) ->
    lists:foreach(
        fun(#flow_table{entries = Entries} = Table) ->
            NewEntries = lists:filter(fun(Entry) ->
                                          not MatchFun(Entry, FlowMod)
                                      end, Entries),
            ets:insert(flow_tables, Table#flow_table{entries = NewEntries})
        end, get_flow_tables(TableId)).

%% strict match: use all match fields (including the masks) and the priority
strict_match(#flow_entry{priority = Priority, match = Match},
             #flow_mod{priority = Priority, match = Match}) ->
    true;
strict_match(_FlowEntry, _FlowMod) ->
    false.

%% non-strict match: match more specific fields, ignore the priority
non_strict_match(#flow_entry{match = #match{type = oxm,
                                            oxm_fields = EntryFields}},
                 #flow_mod{match = #match{type = oxm,
                                          oxm_fields = FlowModFields}}) ->
    lists:all(fun(#oxm_field{field = Field} = FlowModField) ->
        case lists:keyfind(Field, #oxm_field.field, EntryFields) of
            #oxm_field{} = EntryField ->
                is_more_specific(EntryField, FlowModField);
            false ->
                false
        end
    end, FlowModFields);
non_strict_match(_FlowEntry, _FlowMod) ->
    throw(#error_msg{type = bad_match, code = bad_type}).

is_more_specific(#oxm_field{class = Cls1}, #oxm_field{class = Cls2}) when
        Cls1 =/= openflow_basic; Cls2 =/= openflow_basic ->
    throw(#error_msg{type = bad_match, code = bad_field});
is_more_specific(#oxm_field{has_mask = true},
                 #oxm_field{has_mask = false}) ->
    false; %% masked is less specific than non-masked
is_more_specific(#oxm_field{has_mask = false, value = Value},
                 #oxm_field{has_mask = _____, value = Value}) ->
    true; %% value match with no mask is more specific
is_more_specific(#oxm_field{has_mask = true, mask = M1, value = V1},
                 #oxm_field{has_mask = true, mask = M2, value = V2}) ->
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
            ofs_userspace_port:send(2, Pkt),
            drop;
        {table_miss, continue, NextFlowId} ->
            do_route(Pkt, NextFlowId)
    end.

-spec apply_flow(#ofs_pkt{}, #flow_entry{}) -> tuple().
apply_flow(Pkt, FlowId) ->
    [FlowTable] = ets:lookup(flow_tables, FlowId),
    FlowTableId = FlowTable#flow_table.id,
    case match_flow_entries(Pkt, FlowTableId, FlowTable#flow_table.entries) of
        {match, goto, NextFlowId, NewPkt} ->
            update_flow_table_match_counters(FlowTableId),
            {match, goto, NextFlowId, NewPkt};
        {match, output, NewPkt} ->
            update_flow_table_match_counters(FlowTableId),
            {match, output, NewPkt};
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
    case fields_match(Pkt#ofs_pkt.fields#match.oxm_fields,
                      FlowEntry#flow_entry.match#match.oxm_fields) of
        true ->
            case apply_instructions(FlowEntry#flow_entry.instructions,
                                    Pkt,
                                    output) of
                {NewPkt, goto, NextFlowId} ->
                    {match, goto, NextFlowId, NewPkt};
                {NewPkt, output} ->
                    {match, output, NewPkt}
            end;
        false ->
            nomatch
    end.

-spec fields_match(list(#oxm_field{}), list(#oxm_field{})) -> boolean().
fields_match(PktFields, FlowFields) ->
    lists:all(fun(#oxm_field{field = F1} = PktField) ->
                  %% TODO: check for class other than openflow_basic
                  lists:all(fun(#oxm_field{field = F2} = FlowField) ->
                                F1 =/= F2 %% field is not relevant here
                                orelse
                                two_fields_match(PktField, FlowField)
                            end, FlowFields)
              end, PktFields).


two_fields_match(#oxm_field{value=Val},
                 #oxm_field{value=Val, has_mask = false}) ->
    true;
two_fields_match(#oxm_field{value=Val1},
                 #oxm_field{value=Val2, has_mask = true, mask = Mask}) ->
    mask_match(Val1, Val2, Mask);
two_fields_match(_, _) ->
    false.

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
apply_action_list([#action_output{port = PortNum} | Rest], Pkt) ->
    route_to_output(Pkt, PortNum),
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

-spec route_to_output(#ofs_pkt{}, integer() | atom()) -> any().
route_to_output(Pkt = #ofs_pkt{in_port = InPort}, all) ->
    Ports = ets:tab2list(ofs_ports),
    [ofs_userspace_port:send(PortNum, Pkt)
     || #ofs_port{number = PortNum} <- Ports, PortNum /= InPort];
route_to_output(Pkt, controller) ->
    route_to_controller(Pkt);
route_to_output(_Pkt, table) ->
    %% FIXME: Only valid in an output action in the
    %%        action list of a packet-out message.
    ok;
route_to_output(Pkt = #ofs_pkt{in_port = InPort}, in_port) ->
    ofs_userspace_port:send(InPort, Pkt);
route_to_output(Pkt, PortNum) when is_integer(PortNum) ->
    ofs_userspace_port:send(PortNum, Pkt);
route_to_output(_Pkt, OtherPort) ->
    lager:warning("unsupported port type: ~p", [OtherPort]).

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
    NewFields = [oxm_field(eth_type, <<Type:16>>),
                 oxm_field(eth_dst, DHost),
                 oxm_field(eth_src, SHost)],
    packet_fields(Rest, Fields ++ NewFields);
packet_fields([#ipv4{p = Proto,
                     saddr = SAddr,
                     daddr = DAddr} | Rest], Fields) ->
    NewFields = [oxm_field(ip_proto, <<Proto:8>>),
                 oxm_field(ipv4_src, SAddr),
                 oxm_field(ipv4_dst, DAddr)],
    packet_fields(Rest, Fields ++ NewFields);
packet_fields([#ipv6{next = Proto,
                     saddr = SAddr,
                     daddr = DAddr} | Rest], Fields) ->
    NewFields = [oxm_field(ip_proto, <<Proto:8>>),
                 oxm_field(ipv6_src, SAddr),
                 oxm_field(ipv6_dst, DAddr)],
    packet_fields(Rest, Fields ++ NewFields);
packet_fields([#tcp{sport = SPort,
                    dport = DPort} | Rest], Fields) ->
    NewFields = [oxm_field(tcp_src, <<SPort:16>>),
                 oxm_field(tcp_dst, <<DPort:16>>)],
    packet_fields(Rest, Fields ++ NewFields);
packet_fields([#udp{sport = SPort,
                    dport = DPort} | Rest], Fields) ->
    NewFields = [oxm_field(udp_src, <<SPort:16>>),
                 oxm_field(udp_dst, <<DPort:16>>)],
    packet_fields(Rest, Fields ++ NewFields);
packet_fields([_Other | Rest], Fields) ->
    packet_fields(Rest, Fields).

-spec oxm_field(atom(), binary() | integer()) -> oxm_field().
oxm_field(Field, Value) ->
    #oxm_field{class = openflow_basic,
               field = Field,
               has_mask = false,
               value = Value}.
