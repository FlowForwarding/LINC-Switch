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
%% @doc Module for handling flows.
-module(linc_us5_flow).

-behaviour(gen_server).

%% API
-export([initialize/1,
         terminate/1,
         table_mod/1,
         table_desc/0,
         modify/3,
         bundle/3,
         get_flow_table/2,
         delete_where_group/3,
         delete_where_meter/3,
         clear_table_flows/3,
         get_stats/2,
         get_aggregate_stats/2,
         get_table_stats/2,
         set_table_config/3,
         get_table_config/2,
         update_lookup_counter/2,
         update_match_counters/4,
         reset_idle_timeout/2]).

%% gen_server exports
-export([start_link/1,
         init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

%% Internal exports
-export([check_timers/1,
         non_strict_match/2,
         port_and_group_match/3,
         flow_table_ets/2]).

-include_lib("of_protocol/include/of_protocol.hrl").
-include_lib("of_protocol/include/ofp_v5.hrl").
-include_lib("linc/include/linc_logger.hrl").
-include_lib("stdlib/include/ms_transform.hrl").
-include("linc_us5.hrl").

-define(MAX64, 16#FFFFFFFF). % Max countervalue for 64 bit counters
-define(INSTRUCTIONS, [ofp_instruction_goto_table, ofp_instruction_write_metadata,
                       ofp_instruction_write_actions, ofp_instruction_apply_actions,
                       ofp_instruction_clear_actions, ofp_instruction_experimenter]).

-record(state,{switch_id :: integer(),
               tref}).

%% @doc Initialize the flow tables module. Only to be called on system startup.
-spec initialize(integer()) -> State::term().
initialize(SwitchId) ->
    FlowTableCounters = ets:new(flow_table_counters,
                                [public,
                                 {keypos, #flow_table_counter.id},
                                 {write_concurrency, true}]),
    linc:register(SwitchId, flow_table_counters, FlowTableCounters),

    FlowTableConfig = ets:new(flow_table_config,
                              [public,
                               {keypos, #flow_table_config.id},
                               {read_concurrency, true}]),
    linc:register(SwitchId, flow_table_config, FlowTableConfig),

    [create_flow_table(SwitchId, TableId)
     || TableId <- lists:seq(0, ?OFPTT_MAX)],

    FlowTimers = ets:new(flow_timers,
                         [public,
                          {keypos, #flow_timer.id},
                          {write_concurrency, true}]),
    linc:register(SwitchId, flow_timers, FlowTimers),
    {ok,Tref} = timer:apply_interval(1000, linc_us5_flow,
                                     check_timers, [SwitchId]),

    FlowEntryCounters = ets:new(flow_entry_counters,
                                [public,
                                 {keypos, #flow_entry_counter.id},
                                 {write_concurrency, true}]),
    linc:register(SwitchId, flow_entry_counters, FlowEntryCounters),
    #state{switch_id = SwitchId,
           tref=Tref}.

%% @doc Terminate the flow table module. Only to be called on system shutdown.
-spec terminate(#state{}) -> ok.
terminate(#state{switch_id = SwitchId, tref=Tref}) ->
    timer:cancel(Tref),
    [begin
         TId = flow_table_ets(SwitchId, TableId),
         ets:delete(TId)
     end || TableId <- lists:seq(0, ?OFPTT_MAX)],
    ets:delete(linc:lookup(SwitchId, flow_table_config)),
    ets:delete(linc:lookup(SwitchId, flow_table_counters)),
    ets:delete(linc:lookup(SwitchId, flow_timers)),
    ets:delete(linc:lookup(SwitchId, flow_entry_counters)),
    ok.

%% @doc Handle ofp_table_mod request
%% In version 1.4 this is used for configuring eviction and vacancy.
-spec table_mod(#ofp_table_mod{}) ->
                       ok | {error, {ofp_error_type(), ofp_error_code()}}.
table_mod(#ofp_table_mod{config = Config}) ->
    case lists:member(eviction, Config) of
        true ->
            %% "Flow entry eviction is optional and as a consequence a
            %% switch may not support setting this flag."
            {error, {table_mod_failed, bad_config}};
        false ->
            %% Supporting the flow vacancy flag is not optional, as
            %% far as I can see.  However, since the number of flow
            %% entries per flow table is virtually unlimited, we never
            %% have a reason to send any vacancy events, nor to store
            %% the vacancy setting anywhere.
            ok
    end.

-spec table_desc() -> ofp_table_desc_reply().
table_desc() ->
    #ofp_table_desc_reply{
       %% Entire reply in one packet - need to update this if we exceed 64 kB
       flags = [],
       tables = [#ofp_table_desc{
                    table_id = Id,
                    %% Eviction and vacancy - currently we support neither.
                    config = [],
                    %% Ditto for properties.
                    properties = []}
                 || Id <- lists:seq(0, ?OFPTT_MAX)]}.

%% @doc Handle a flow_mod request from a controller.
%% This may add/modify/delete one or more flows.
-spec modify(integer(), #ofp_flow_mod{}, {pid(), integer()}) ->
                    ok | {error, {Type :: atom(), Code :: atom()}}.
modify(SwitchId, #ofp_flow_mod{} = FlowMod, MonitorData) ->
    %% All modifications are serialised.
    Pid = linc:lookup(SwitchId, ?MODULE),
    gen_server:call(Pid, {modify, SwitchId, FlowMod, MonitorData}, infinity).

-spec bundle(integer(), [#ofp_message{body :: #ofp_flow_mod{}}], {pid(), integer()}) ->
                    ok | {error, [#ofp_message{body :: #ofp_error_msg{}}]}.
bundle(SwitchId, Messages, MonitorData) ->
    Pid = linc:lookup(SwitchId, ?MODULE),
    gen_server:call(Pid, {bundle, SwitchId, Messages, MonitorData}, infinity).

%% @doc Get all entries in one flow table.
-spec get_flow_table(integer(), integer()) -> [FlowTableEntryRepr :: term()].
get_flow_table(SwitchId, TableId) ->
    lists:reverse(ets:tab2list(flow_table_ets(SwitchId, TableId))).

%% @doc Delete all flow entries that are using a specific group.
-spec delete_where_group(integer(), integer(), #monitor_data{}) -> ok.
delete_where_group(SwitchId, GroupId, MonitorData) ->
    [delete_where_group(SwitchId, GroupId, TableId, MonitorData)
     || TableId <- lists:seq(0, ?OFPTT_MAX)],
    ok.

%% @doc Delete all flow entries that are pointing to a given meter.
-spec delete_where_meter(integer(), integer(), #monitor_data{}) -> ok.
delete_where_meter(SwitchId, MeterId, MonitorData) ->
    [delete_where_meter(SwitchId, MeterId, TableId, MonitorData)
     || TableId <- lists:seq(0, ?OFPTT_MAX)],
    ok.

%% @doc Delete all flow entries in the given flow table.
%%
%% `ofp_flow_removed' events are not sent.
-spec clear_table_flows(integer(), 0..?OFPTT_MAX, #monitor_data{}) -> ok.
clear_table_flows(SwitchId, TableId, MonitorData) ->
    Pid = linc:lookup(SwitchId, ?MODULE),
    gen_server:call(Pid, {clear_table_flows, SwitchId, TableId, MonitorData}, infinity).

%% @doc Get flow statistics.
-spec get_stats(integer(), #ofp_flow_stats_request{}) -> #ofp_flow_stats_reply{}.
get_stats(SwitchId, #ofp_flow_stats_request{table_id = all,
                                            out_port = OutPort,
                                            out_group = OutGroup,
                                            cookie = Cookie,
                                            cookie_mask = CookieMask,
                                            match = #ofp_match{fields=Match}}) ->
    Stats = [get_flow_stats(SwitchId, TableId, Cookie, CookieMask,
                            Match, OutPort,
                            OutGroup) || TableId <- lists:seq(0, ?OFPTT_MAX)],
    #ofp_flow_stats_reply{body = lists:concat(Stats)};

get_stats(SwitchId, #ofp_flow_stats_request{table_id = TableId,
                                            out_port = OutPort,
                                            out_group = OutGroup,
                                            cookie = Cookie,
                                            cookie_mask = CookieMask,
                                            match = #ofp_match{fields=Match}}) ->
    %%TODO
    Stats = get_flow_stats(SwitchId, TableId,Cookie, CookieMask,
                           Match, OutPort, OutGroup),
    #ofp_flow_stats_reply{body = Stats}.

%% @doc Get aggregate statistics.
-spec get_aggregate_stats(integer(), #ofp_aggregate_stats_request{}) ->
                                 #ofp_aggregate_stats_reply{}.
get_aggregate_stats(SwitchId, #ofp_aggregate_stats_request{
                                 table_id = all,
                                 out_port = OutPort,
                                 out_group = OutGroup,
                                 cookie = Cookie,
                                 cookie_mask = CookieMask,
                                 match = #ofp_match{fields=Match}}) ->
    %%TODO
    Stats = [get_aggregate_stats(SwitchId, TableId, Cookie, CookieMask,
                                 Match, OutPort, OutGroup)
             || TableId <- lists:seq(0, ?OFPTT_MAX)],
    %% TODO: merge results
    {PacketCount,ByteCount,FlowCount} = merge_aggregate_stats(Stats),
    #ofp_aggregate_stats_reply{packet_count = PacketCount,
                               byte_count = ByteCount,
                               flow_count = FlowCount};
get_aggregate_stats(SwitchId, #ofp_aggregate_stats_request{
                                 table_id = TableId,
                                 out_port = OutPort,
                                 out_group = OutGroup,
                                 cookie = Cookie,
                                 cookie_mask = CookieMask,
                                 match = #ofp_match{fields=Match}}) ->
    {PacketCount,ByteCount,FlowCount} = get_aggregate_stats(SwitchId,
                                                            TableId,
                                                            Cookie,
                                                            CookieMask,
                                                            Match,
                                                            OutPort,
                                                            OutGroup),
    #ofp_aggregate_stats_reply{packet_count = PacketCount,
                               byte_count = ByteCount,
                               flow_count = FlowCount}.

%% @doc Get table statistics.
-spec get_table_stats(integer(), #ofp_table_stats_request{}) ->
                             #ofp_table_stats_reply{}.
get_table_stats(SwitchId, #ofp_table_stats_request{}) ->
    #ofp_table_stats_reply{body = get_table_stats(SwitchId)}.

-spec set_table_config(integer(), integer(), linc_table_config()) -> ok.
set_table_config(SwitchId, TableId, Config) ->
    true = ets:insert(linc:lookup(SwitchId, flow_table_config),
                      #flow_table_config{id = TableId, config = Config}),
    ok.

-spec get_table_config(integer(), integer()) -> linc_table_config().
get_table_config(SwitchId, TableId) ->
    case ets:lookup(linc:lookup(SwitchId, flow_table_config), TableId) of
        [#flow_table_config{config = Config}] ->
            Config;
        [] ->
            drop
    end.

%% @doc Update the table lookup statistics counters for a table.
-spec update_lookup_counter(integer(), integer()) -> ok.
update_lookup_counter(SwitchId, TableId) ->
    ets:update_counter(linc:lookup(SwitchId, flow_table_counters), TableId,
                       [{#flow_table_counter.packet_lookups, 1, ?MAX64, 0}]),
    ok.

%% @doc Update the match lookup statistics counters for a specific flow.
-spec update_match_counters(SwitchId :: integer(), TableId :: integer(),
                            FlowId :: flow_id(), PktByteSize :: integer()) -> ok.
update_match_counters(SwitchId, TableId, FlowId, PktByteSize) ->
    try
        ets:update_counter(linc:lookup(SwitchId, flow_table_counters), TableId,
                           [{#flow_table_counter.packet_lookups, 1, ?MAX64, 0},
                            {#flow_table_counter.packet_matches, 1, ?MAX64, 0}]),
        ets:update_counter(linc:lookup(SwitchId, flow_entry_counters),
                           FlowId,[{#flow_entry_counter.received_packets,
                                    1, ?MAX64, 0},
                                   {#flow_entry_counter.received_bytes,
                                    PktByteSize, ?MAX64, 0}]),
        ok
    catch
        _:_ ->
            ok
    end.

%% @doc Reset the idle timeout timer for a specific flow.
-spec reset_idle_timeout(integer(), integer()) -> ok.
reset_idle_timeout(SwitchId, FlowId) ->
    case get_flow_timer(SwitchId, FlowId) of
        #flow_timer{idle_timeout = 0} ->
            ok;
        #flow_timer{idle_timeout = IdleTimeout}=_R ->
            Now = os:timestamp(),
            Next = calc_timeout(Now, IdleTimeout),
            true = ets:update_element(linc:lookup(SwitchId, flow_timers),
                                      FlowId,
                                      {#flow_timer.expire, Next}),
            ok
    end.

%%=============================================================================
%% gen_server callback functions

start_link(SwitchId) ->
    gen_server:start_link(?MODULE, SwitchId, []).

init(SwitchId) ->
    linc:register(SwitchId, linc_us5_flow, self()),
    {ok, {}}.

handle_call({modify, SwitchId, FlowMod, MonitorData}, _From, State) ->
    %% Serialise instructions that modify flow tables.
    Reply = case do_bundle(SwitchId, [#ofp_message{body = FlowMod}], MonitorData) of
                ok ->
                    ok;
                {error, [#ofp_message{body = #ofp_error_msg{type = Type, code = Code}}]} ->
                    %% Since we only pass one flow mod message, we're
                    %% guaranteed to get only one error message back.
                    {error, {Type, Code}}
            end,
    {reply, Reply, State};
handle_call({bundle, SwitchId, Messages, MonitorData}, _From, State) ->
    Reply = do_bundle(SwitchId, Messages, MonitorData),
    {reply, Reply, State};
handle_call({clear_table_flows, SwitchId, TableId, MonitorData}, _From, State) ->
    ets:foldl(fun(#flow_entry{} = FlowEntry, _Acc) ->
                      delete_flow(SwitchId, TableId, FlowEntry, no_event, true, MonitorData)
              end, ok, flow_table_ets(SwitchId, TableId)),
    {reply, ok, State}.

handle_cast(_, State) ->
    {noreply, State}.

handle_info(_, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

-record(bundle_commit, {
          inserts = [] :: [{TableId::non_neg_integer(), #flow_entry{}}],
          modifications = [] :: [{TableId::non_neg_integer(), Old::#flow_entry{}, New::#flow_entry{}}],
          deletes = [] :: [{TableId::non_neg_integer(), #flow_entry{}, 'no_event' | ofp_flow_removed_reason()}],
          timers = [] :: [{TableId::non_neg_integer(),
                           flow_id(),
                           IdleTimeout::non_neg_integer(),
                           HardTimeout::non_neg_integer()}],
          keep_flow_counters = [] :: [flow_id()],
          send_buffered_packets = [] :: [ofp_buffer_id()],
          errors = [] :: [#ofp_message{body :: #ofp_error_msg{}}]}).

already_added(TableId, FlowId, #bundle_commit{inserts = Added}) ->
    already_added(TableId, FlowId, Added);
already_added(TableId, FlowId, Added) ->
    lists:any(
      fun({TheTableId, #flow_entry{id = AddedId}}) ->
              TheTableId =:= TableId andalso AddedId =:= FlowId
      end, Added).

already_modified(TableId, FlowId, #bundle_commit{modifications = Modified}) ->
    already_modified(TableId, FlowId, Modified);
already_modified(TableId, FlowId, Modified) ->
    lists:any(
      fun({TheTableId, _OldEntry, #flow_entry{id = ModifiedId}}) ->
              TheTableId =:= TableId andalso ModifiedId =:= FlowId
      end, Modified).

already_deleted(TableId, FlowId, #bundle_commit{deletes = Deleted}) ->
    already_deleted(TableId, FlowId, Deleted);
already_deleted(TableId, FlowId, Deleted) ->
    lists:any(
      fun({TheTableId, #flow_entry{id = DeletedId}, _Reason}) ->
              TheTableId =:= TableId andalso DeletedId =:= FlowId
      end, Deleted).

do_bundle(SwitchId, Messages, MonitorData) ->
    Result = lists:foldl(fun(Message, Acc) -> delayed_modify(SwitchId, Message, Acc) end,
                         #bundle_commit{},
                         Messages),
    case Result of
        #bundle_commit{errors = Errors = [_|_]} ->
            {error, lists:reverse(Errors)};
        #bundle_commit{
           inserts = Inserts,
           modifications = Modifications,
           deletes = Deletes,
           timers = Timers,
           keep_flow_counters = KeepFlowCounters,
           send_buffered_packets = SendBufferedPackets,
           errors = []} ->
            lists:foreach(
              fun({TableId, FlowToRemove = #flow_entry{id = Id}, Reason}) ->
                      delete_flow(SwitchId, TableId, FlowToRemove, Reason,
                                  not lists:member(Id, KeepFlowCounters), MonitorData)
              end, lists:reverse(Deletes)),
            lists:foreach(
              fun({TableId, FlowToAdd = #flow_entry{id = Id}}) ->
                      add_new_flow(SwitchId, TableId, FlowToAdd,
                                   not lists:member(Id, KeepFlowCounters), MonitorData)
              end, lists:reverse(Inserts)),
            lists:foreach(
              fun({TableId, OldFlow, NewFlow = #flow_entry{id = Id}}) ->
                      modify_flow(SwitchId, TableId, OldFlow, NewFlow,
                                  not lists:member(Id, KeepFlowCounters), MonitorData)
              end, lists:reverse(Modifications)),
            lists:foreach(
              fun({TableId, FlowId, IdleTime, HardTime}) ->
                      create_flow_timer(SwitchId, TableId, FlowId,
                                        IdleTime, HardTime)
              end, lists:reverse(Timers)),
            lists:foreach(
              fun(BufferId) ->
                      case linc_buffer:get_buffer(SwitchId, BufferId) of
                          #linc_pkt{} = OfsPkt ->
                              Action = #ofp_action_output{port = table},
                              linc_us5_actions:apply_list(OfsPkt, [Action]);
                          not_found ->
                              %% Buffer has been dropped, ignore
                              ok
                      end
              end, lists:reverse(SendBufferedPackets)),
            ok
    end.

delayed_modify(_SwitchId, Msg = #ofp_message{body = #ofp_flow_mod{command = Cmd, table_id = all}}, Acc)
  when Cmd == add orelse Cmd == modify orelse Cmd == modify_strict ->
    bundle_error(Msg, Acc, flow_mod_failed, bad_table_id);
delayed_modify(SwitchId, Msg = #ofp_flow_mod{command = Cmd, buffer_id = BufferId} = FlowMod, Acc)
  when (Cmd == add orelse Cmd == modify orelse Cmd == modify_strict)
       andalso BufferId /= no_buffer ->
    %% A buffer_id is provided, we have to first do the flow_mod
    %% and then a packet_out to OFPP_TABLE. This actually means to first
    %% perform the flow_mod and then restart the processing of the buffered
    %% packet starting in flow_table=0.
    NewAcc = delayed_modify(SwitchId, Msg#ofp_message{body = FlowMod#ofp_flow_mod{buffer_id = no_buffer}}, Acc),
    NewAcc#bundle_commit{send_buffered_packets = [BufferId] ++ Acc#bundle_commit.send_buffered_packets};
delayed_modify(SwitchId, Msg = #ofp_message{body = #ofp_flow_mod{command = add,
                                                                 table_id = TableId,
                                                                 priority = Priority,
                                                                 flags = Flags,
                                                                 match = #ofp_match{fields = Match},
                                                                 instructions = Instructions}} = FlowMod,
               Acc = #bundle_commit{inserts = Added,
                                    deletes = Deleted}) ->
    case validate_match_and_instructions(SwitchId, TableId,
                                         Match, Instructions) of
        ok ->
            case lists:member(check_overlap, Flags) of
                true ->
                    %% Check that there are no overlapping flows.
                    case check_overlap(SwitchId, TableId, Priority, Match, Added, Deleted) of
                        true ->
                            bundle_error(Msg, Acc, flow_mod_failed, overlap);
                        false ->
                            delayed_add_new_flow(FlowMod, Acc)
                    end;
                false ->
                    %% Check if there is any entry with the exact same 
                    %% priority and match
                    case find_exact_match(SwitchId, TableId,
                                          Priority, Match,
                                          Added, Deleted) of
                        #flow_entry{} = Matching ->
                            delayed_replace_existing_flow(Msg, Matching, Acc);
                        no_match ->
                            delayed_add_new_flow(FlowMod, Acc)
                    end
            end;
        {error, {Type, Code}} ->
            bundle_error(Msg, Acc, Type, Code)
    end;
delayed_modify(SwitchId, Msg = #ofp_message{body = #ofp_flow_mod{command = modify,
                                                                 cookie = Cookie,
                                                                 cookie_mask = CookieMask,
                                                                 table_id = TableId,
                                                                 flags = Flags,
                                                                 match = #ofp_match{fields = Match},
                                                                 instructions = Instructions}},
              Acc) ->
    case validate_match_and_instructions(SwitchId, TableId,
                                         Match, Instructions) of
        ok ->
            delayed_modify_matching_flows(SwitchId, TableId, Cookie, CookieMask,
                                          Match, Instructions, Flags, Msg, Acc);
        {error, {Type, Code}} ->
            bundle_error(Msg, Acc, Type, Code)
    end;
delayed_modify(SwitchId, Msg = #ofp_message{body = #ofp_flow_mod{command = modify_strict,
                                                                 table_id = TableId,
                                                                 priority = Priority,
                                                                 flags = Flags,
                                                                 match = #ofp_match{fields = Match},
                                                                 instructions = Instructions}},
               Acc = #bundle_commit{inserts = Added,
                                    deletes = Deleted}) ->
    case validate_match_and_instructions(SwitchId, TableId,
                                         Match, Instructions) of
        ok ->
            case find_exact_match(SwitchId, TableId, Priority, Match, Added, Deleted) of
                #flow_entry{} = Flow ->
                    delayed_modify_flow(TableId, Flow, Instructions, Flags, Acc);
                no_match ->
                    %% Do nothing
                    Acc
            end;
        {error, {Type, Code}} ->
            bundle_error(Msg, Acc, Type, Code)
    end;
delayed_modify(SwitchId, Msg = #ofp_message{body = #ofp_flow_mod{command = Cmd, table_id = all} = FlowMod},
               Acc)
  when Cmd == delete; Cmd == delete_strict ->
    %% Ensure that we only send one error.
    AccWithoutErrors = Acc#bundle_commit{errors = []},
    case lists:foldl(fun(Id, NewAcc) ->
                             delayed_modify(SwitchId, Msg#ofp_message{body = FlowMod#ofp_flow_mod{table_id = Id}}, NewAcc)
                     end, AccWithoutErrors, lists:seq(0, ?OFPTT_MAX)) of
        NewAccWithoutErrors = #bundle_commit{errors = []} ->
            NewAccWithoutErrors#bundle_commit{errors = Acc#bundle_commit.errors};
        NewAccWithErrors = #bundle_commit{errors = Errors} ->
            FirstError = lists:last(Errors),
            NewAccWithErrors#bundle_commit{errors = [FirstError] ++ Acc#bundle_commit.errors}
    end;
delayed_modify(SwitchId, #ofp_message{body = #ofp_flow_mod{command = delete,
                                                                 table_id = TableId,
                                                                 cookie = Cookie,
                                                                 cookie_mask = CookieMask,
                                                                 out_port = OutPort,
                                                                 out_group = OutGroup,
                                                                 match = #ofp_match{fields = Match}}} = Msg,
               Acc) ->
    delayed_delete_matching_flows(SwitchId, TableId, Cookie, CookieMask,
                                  Match, OutPort, OutGroup, Msg, Acc);
delayed_modify(SwitchId, #ofp_message{body = #ofp_flow_mod{command = delete_strict,
                                                           table_id = TableId,
                                                           priority = Priority,
                                                           match = #ofp_match{fields = Match}}},
               Acc = #bundle_commit{inserts = Added,
                                    deletes = Deleted}) ->
    case find_exact_match(SwitchId, TableId, Priority, Match, Added, Deleted) of
        #flow_entry{} = FlowEntry ->
            delayed_delete_flow(TableId, FlowEntry, deleted, Acc);
        _ ->
            %% Do nothing
            Acc
    end.

bundle_error(Msg, Acc, Type, Code) ->
    ErrorMsg = Msg#ofp_message{body = #ofp_error_msg{type = Type, code = Code}},
    Acc#bundle_commit{errors = [ErrorMsg] ++ Acc#bundle_commit.errors}.

%%=============================================================================

%% Return flow table name for table id.
flow_table_name(TableId) ->
    list_to_atom(lists:concat([flow_table_,TableId])).

%% Return flow table ETS tid for given switch id and table id.
flow_table_ets(SwitchId, TableId) ->
    TableName = flow_table_name(TableId),
    linc:lookup(SwitchId, TableName).

%% Create an ETS table for flow table Id, also initialize flow table counters
%% for the table.
create_flow_table(SwitchId, TableId) ->
    TableName = flow_table_name(TableId),
    Tid = ets:new(TableName, [ordered_set, public,
                              {keypos, #flow_entry.id},
                              {read_concurrency, true}]),
    linc:register(SwitchId, TableName, Tid),
    ets:insert(linc:lookup(SwitchId, flow_table_counters),
               #flow_table_counter{id = TableId}),
    Tid.

%% Check if there exists a flow in flow table=TableId with priority=Priority with
%% a match that overlaps with Match.
check_overlap(SwitchId, TableId, Priority, NewMatch, Added, Deleted) ->
    ExistingFlows = lists:sort(get_flows_by_priority(SwitchId, TableId, Priority)),
    %% Exclude flow entries that have been deleted in this bundle.
    ExistingNotDeleted =
        lists:filter(
          fun(#flow_entry{id = Id}) ->
                  not already_deleted(TableId, Id, Deleted)
          end, ExistingFlows),
    %% Include flow entries that are newly added
    ExistingAdded =
        lists:filter(
          fun({TheTableId, #flow_entry{id = {Prio,_},
                                       match = #ofp_match{fields = Fields}}}) ->
                  TheTableId =:= TableId andalso
                      Prio =:= Priority andalso
                      Fields =:= NewMatch
          end, Added),
    Existing = ExistingAdded ++ ExistingNotDeleted,
    ExistingMatches = lists:map(
                        fun(#flow_entry{match = #ofp_match{fields = Fields}}) ->
                                Fields
                        end, Existing),
    SortedNewMatch = lists:sort(NewMatch),
    lists:any(fun (ExistingMatch) ->
                      overlaps(SortedNewMatch, lists:sort(ExistingMatch))
              end, ExistingMatches).

overlaps([#ofp_field{class=C,name=F,has_mask=false,value=V}|Ms1],
         [#ofp_field{class=C,name=F,has_mask=false,value=V}|Ms2]) ->
    overlaps(Ms1,Ms2);
overlaps([#ofp_field{class=C,name=F,has_mask=false,value=V1}|_Fields1],
         [#ofp_field{class=C,name=F,has_mask=false,value=V2}|_Fields2])
  when V1=/=V2 ->
    false;
overlaps([#ofp_field{class=C,name=F,has_mask=true,value=V1,mask=MaskBin}|_Fields1],
         [#ofp_field{class=C,name=F,has_mask=false,value=V2}|_Fields2]) ->
    Bits = bit_size(MaskBin),
    <<Val1:Bits>> = V1,
    <<Val2:Bits>> = V2,
    <<Mask:Bits>> = MaskBin,
    Val1 band Mask == Val2 band Mask;
overlaps([#ofp_field{class=C,name=F,has_mask=true,value=V1}|_Fields1],
         [#ofp_field{class=C,name=F,has_mask=false,value=V2,mask=MaskBin}|_Fields2]) ->
    Bits = bit_size(MaskBin),
    <<Val1:Bits>> = V1,
    <<Val2:Bits>> = V2,
    <<Mask:Bits>> = MaskBin,
    Val1 band Mask == Val2 band Mask;
overlaps([#ofp_field{class=C,name=F,has_mask=true,value=V1,mask=M1}|Ms1],
         [#ofp_field{class=C,name=F,has_mask=true,value=V2,mask=M2}|Ms2]) ->
    Bits = bit_size(M1),
    <<Val1:Bits>> = V1,
    <<Val2:Bits>> = V2,
    <<Mask1:Bits>> = M1,
    <<Mask2:Bits>> = M2,
    CommonBits = Mask1 band Mask2,
    %% Is this correct?
    case (Val1 band CommonBits)==(Val2 band CommonBits) of
        false ->
            false;
        true ->
            overlaps(Ms1,Ms2)
    end;
overlaps([#ofp_field{class=C,name=F1}|Ms1],
         [#ofp_field{class=C,name=F2}|_]=Ms2) when F1<F2 ->
    %% Both lists of match fields have been sorted, so this actually works.
    overlaps(Ms1,Ms2);
overlaps([#ofp_field{class=C,name=F1}|_]=Ms1,
         [#ofp_field{class=C,name=F2}|Ms2]) when F1>F2 ->
    %% Both lists of match fields have been sorted, so this actually works.
    overlaps(Ms1,Ms2);
overlaps(_V1,_V2) ->
    true.

delayed_add_new_flow(#ofp_message{body = #ofp_flow_mod{table_id = TableId,
                                                       idle_timeout=IdleTime,
                                                       hard_timeout=HardTime} = FlowMod},
                     Acc = #bundle_commit{inserts = Added, timers = Timers}) ->
    NewEntry = create_flow_entry(FlowMod),
    NewTimer = {TableId, NewEntry#flow_entry.id, IdleTime, HardTime},
    Acc#bundle_commit{inserts = [{TableId, NewEntry}] ++ Added,
                      timers = [NewTimer] ++ Timers}.

%% Add a new flow entry.
add_new_flow(SwitchId, TableId,
             #flow_entry{instructions = Instructions} = NewEntry,
             ResetCounters, MonitorData) ->
    %% Create counter before inserting flow in flow table to avoid race.
    ResetCounters andalso
        create_flow_entry_counter(SwitchId, NewEntry#flow_entry.id),
    ets:insert(flow_table_ets(SwitchId, TableId), NewEntry),
    increment_group_ref_count(SwitchId, Instructions),
    ?DEBUG("[FLOWMOD] Added new flow entry with id ~w: ~w",
           [NewEntry#flow_entry.id, NewEntry]),
    linc_us5_monitor:monitor(SwitchId, added, TableId, MonitorData, NewEntry),
    ok.

delayed_delete_flow(TableId,
                    #flow_entry{}=Flow,
                    Reason,
                    Acc = #bundle_commit{deletes = Deletes}) ->
    Acc#bundle_commit{deletes = [{TableId, Flow, Reason}] ++ Deletes}.

%% Delete a flow
delete_flow(SwitchId, TableId,
            #flow_entry{id=FlowId, instructions=Instructions, flags=Flags}=Flow,
            Reason, DeleteCounters, MonitorData) ->
    case lists:member(send_flow_rem, Flags) andalso Reason/=no_event of
        true ->
            send_flow_removed(SwitchId, TableId, Flow, Reason);
        false ->
            %% Do nothing
            ok
    end,
    ets:delete(flow_table_ets(SwitchId, TableId), FlowId),
    DeleteCounters andalso
        ets:delete(linc:lookup(SwitchId, flow_entry_counters), FlowId),
    delete_flow_timer(SwitchId, FlowId),
    decrement_group_ref_count(SwitchId, Instructions),
    ?DEBUG("[FLOWMOD] Deleted flow entry with id ~w: ~w",
           [FlowId, Flow]),
    linc_us5_monitor:monitor(SwitchId, removed, TableId, 
                             MonitorData#monitor_data{reason = Reason}, Flow),
    ok.

send_flow_removed(SwitchId, TableId,
                  #flow_entry{id = FlowId,
                              cookie = Cookie,
                              priority = Priority,
                              install_time = InstallTime,
                              match = Match},
                  Reason) ->
    DurationMs = timer:now_diff(os:timestamp(),InstallTime),
    [#flow_entry_counter{
        received_packets = Packets,
        received_bytes   = Bytes}] = ets:lookup(linc:lookup(SwitchId,
                                                            flow_entry_counters),
                                                FlowId),

    #flow_timer{idle_timeout = IdleTimeout,
                hard_timeout = HardTimeout} = get_flow_timer(SwitchId, FlowId),

    Body = #ofp_flow_removed{
              cookie = Cookie,
              priority =Priority,
              reason = Reason,
              table_id = TableId,
              duration_sec = DurationMs div 1000000,
              duration_nsec = DurationMs rem 1000000 * 1000,
              idle_timeout = IdleTimeout,
              hard_timeout = HardTimeout,
              packet_count = Packets,
              byte_count = Bytes,
              match = Match},
    Msg = #ofp_message{type = ofp_flow_removed,
                       body = Body
                      },
    linc_logic:send_to_controllers(SwitchId, Msg).

-spec create_flow_entry(ofp_flow_mod()) -> #flow_entry{}.
create_flow_entry(#ofp_flow_mod{priority = Priority,
                                cookie = Cookie,
                                flags = Flags,
                                match = Match,
                                instructions = Instructions}) ->
    #flow_entry{id = {Priority, make_ref()},
                priority = Priority,
                cookie = Cookie,
                flags = Flags,
                match = Match,
                install_time = erlang:now(),
                %% All record of type ofp_instruction() MUST have
                %% seq number as a first element.
                instructions = lists:keysort(2, Instructions)}.

validate_match_and_instructions(SwitchId, TableId, Match, Instructions) ->
    case validate_match(Match) of
        ok ->
            case validate_instructions(SwitchId, TableId,
                                       Instructions, Match) of
                ok ->
                    ok;
                Error ->
                    Error
            end;
        Error ->
            Error
    end.

%% Validate a match specification.
%% This consists of
%% - Are all fields supported
%% - There are no duplicated fields
%% - All prerequisite fields are present and with an apropiate value at an
%%   earlier position in the list of fields
%% - The values are within the allowed domains
%% - There's no 0 bit in a mask for the corresponding bit in a value set to 1
-spec validate_match(Match::[ofp_field()]) ->
                            ok | {error,{Type :: atom(), Code :: atom()}}.
validate_match(Fields) ->
    validate_match(Fields, []).

validate_match([#ofp_field{class = Class, name = Name} = Field | Fields],
               Previous) ->
    Validators
        = [{bad_field, fun is_supported_field/2, [Class, Name]},
           {dup_field, fun is_not_duplicated_field/3, [Class, Name, Previous]},
           {bad_prereq, fun are_prerequisites_met/2, [Field, Previous]},
           {bad_value, fun is_value_valid/1, [Field]},
           {bad_wildcards, fun is_mask_valid/1, [Field]}],

    case lists:dropwhile(fun({_, CheckFun, Args}) ->
                                 erlang:apply(CheckFun, Args)
                         end, Validators) of
        [] ->
            validate_match(Fields, [Field | Previous]);
        [{ErrorCode, _FaildedCheck, _} | _] ->
            {error, {bad_match, ErrorCode}}
    end;

validate_match([],_Previous) ->
    ok.

%% Check that a field is supported.
%% Currently all openflow_basic fields are assumed to be supported
%% No experimenter fields are supported
is_supported_field(openflow_basic,_Name) ->
    true;
is_supported_field(_Class, _Name) ->
    false.

%% Check that the field is not duplicated
is_not_duplicated_field(Class, Name, Previous) ->
    not([x] == [x|| #ofp_field{class=C,name=N} <- Previous, C==Class, N==Name]).

%% Check that all prerequisite fields are present and have apropiate values
are_prerequisites_met(#ofp_field{class=Class,name=Name},Previous) ->
    case prerequisite_for(Class, Name) of
        [] ->
            true;
        PreReqs ->
            lists:any(fun (Required) ->
                              test_prereq(Required,Previous)
                      end, PreReqs)
    end.

%% Get the prerequisite fields and values for a field
prerequisite_for(openflow_basic, in_phy_port) ->
    [in_port];
prerequisite_for(openflow_basic, vlan_pcp) ->
    %% this needs work
    [{{openflow_basic,vlan_vid},none}];
prerequisite_for(openflow_basic, ip_dscp) ->
    [{{openflow_basic,eth_type},<<16#800:16>>},
     {{openflow_basic,eth_type},<<16#86dd:16>>}];
prerequisite_for(openflow_basic, ip_ecn) ->
    [{{openflow_basic,eth_type},<<16#800:16>>},
     {{openflow_basic,eth_type},<<16#86dd:16>>}];
prerequisite_for(openflow_basic, ip_proto) ->
    [{{openflow_basic,eth_type},<<16#800:16>>},
     {{openflow_basic,eth_type},<<16#86dd:16>>}];
prerequisite_for(openflow_basic, ipv4_src) ->
    [{{openflow_basic,eth_type},<<16#800:16>>}];
prerequisite_for(openflow_basic, ipv4_dst) ->
    [{{openflow_basic,eth_type},<<16#800:16>>}];
prerequisite_for(openflow_basic, tcp_src) ->
    [{{openflow_basic,ip_proto},<<6:8>>}];
prerequisite_for(openflow_basic, tcp_dst) ->
    [{{openflow_basic,ip_proto},<<6:8>>}];
prerequisite_for(openflow_basic, udp_src) ->
    [{{openflow_basic,ip_proto},<<17:8>>}];
prerequisite_for(openflow_basic, udp_dst) ->
    [{{openflow_basic,ip_proto},<<17:8>>}];
prerequisite_for(openflow_basic, sctp_src) ->
    [{{openflow_basic,ip_proto},<<132:8>>}];
prerequisite_for(openflow_basic, sctp_dst) ->
    [{{openflow_basic,ip_proto},<<132:8>>}];
prerequisite_for(openflow_basic, icmpv4_type) ->
    [{{openflow_basic,ip_proto},<<1:8>>}];
prerequisite_for(openflow_basic, icmpv4_code) ->
    [{{openflow_basic,ip_proto},<<1:8>>}];
prerequisite_for(openflow_basic, arp_op) ->
    [{{openflow_basic,eth_type},<<16#806:16>>}];
prerequisite_for(openflow_basic, arp_spa) ->
    [{{openflow_basic,eth_type},<<16#806:16>>}];
prerequisite_for(openflow_basic, arp_tpa) ->
    [{{openflow_basic,eth_type},<<16#806:16>>}];
prerequisite_for(openflow_basic, arp_sha) ->
    [{{openflow_basic,eth_type},<<16#806:16>>}];
prerequisite_for(openflow_basic, arp_tha) ->
    [{{openflow_basic,eth_type},<<16#806:16>>}];
prerequisite_for(openflow_basic, ipv6_src) ->
    [{{openflow_basic,eth_type},<<16#86dd:16>>}];
prerequisite_for(openflow_basic, ipv6_dst) ->
    [{{openflow_basic,eth_type},<<16#86dd:16>>}];
prerequisite_for(openflow_basic, ipv6_flabel) ->
    [{{openflow_basic,eth_type},<<16#86dd:16>>}];
prerequisite_for(openflow_basic, icmpv6_type) ->
    [{{openflow_basic,ip_proto},<<58:8>>}];
prerequisite_for(openflow_basic, icmpv6_code) ->
    [{{openflow_basic,ip_proto},<<58:8>>}];
prerequisite_for(openflow_basic, ipv6_nd_target) ->
    [{{openflow_basic,icmpv6_type},<<135:8>>},
     {{openflow_basic,icmpv6_type},<<136:8>>}];
prerequisite_for(openflow_basic, ipv6_nd_sll) ->
    [{{openflow_basic,icmpv6_type},<<135:8>>}];
prerequisite_for(openflow_basic, ipv6_nd_tll) ->
    [{{openflow_basic,icmpv6_type},<<136:8>>}];
prerequisite_for(openflow_basic, mpls_label) ->
    [{{openflow_basic,eth_type},<<16#8847:16>>},
     {{openflow_basic,eth_type},<<16#8848:16>>}];
prerequisite_for(openflow_basic, mpls_tc) ->
    [{{openflow_basic,eth_type},<<16#8847:16>>},
     {{openflow_basic,eth_type},<<16#8848:16>>}];
prerequisite_for(openflow_basic, mpls_bos) ->
    [{{openflow_basic,eth_type},<<16#8847:16>>},
     {{openflow_basic,eth_type},<<16#8848:16>>}];
prerequisite_for(openflow_basic, pbb_isid) ->
    [{{openflow_basic,eth_type},<<16#88E7:16>>}];
prerequisite_for(openflow_basic, ipv6_exthdr) ->
    [{{openflow_basic,eth_type},<<16#86dd:16>>}];
prerequisite_for(openflow_basic, _) ->
    [].

test_prereq({{openflow_basic,vlan_pcp},_Value},Previous) ->
    case lists:keyfind(vlan_pcp, #ofp_field.name,Previous) of
        #ofp_field{value=Value} when Value/=none ->
            true;
        _ ->
            false
    end;
test_prereq({{Class,Name},Value},Previous) ->
    case [Field || #ofp_field{class=C,name=N}=Field <- Previous, C==Class, N==Name] of
        [#ofp_field{value=Value}] ->
            true;
        _ ->
            false
    end;
test_prereq(none, _Previous) ->
    true.

%% Validate instructions.
%% unknown instruction
%% unsupported instruction
%% goto-table with invalid next-table-id
%% invalid port
%% invalid group
%% invalid value in set-field
%% operation inconsistent with match,
validate_instructions(SwitchId, TableId, Instructions, Match) ->
    case check_occurances(Instructions) of
        ok ->
            do_validate_instructions(SwitchId, TableId, Instructions, Match);
        Error ->
            Error
    end.

check_occurances(Instructions) ->
    case lists:all(fun(Type) ->
                           check_occurrences(Type, Instructions)
                   end, ?INSTRUCTIONS) of
        true ->
            ok;
        false ->
            {error,{bad_instruction, dup_inst}}
    end.

check_occurrences(ofp_instruction_goto_table, Instructions) ->
    1 >= length([x || #ofp_instruction_goto_table{} <- Instructions]);
check_occurrences(ofp_instruction_write_metadata, Instructions) ->
    1 >= length([x || #ofp_instruction_write_metadata{} <- Instructions]);
check_occurrences(ofp_instruction_write_actions, Instructions) ->
    1 >= length([x || #ofp_instruction_write_actions{} <- Instructions]);
check_occurrences(ofp_instruction_apply_actions, Instructions) ->
    1 >= length([x || #ofp_instruction_apply_actions{} <- Instructions]);
check_occurrences(ofp_instruction_clear_actions, Instructions) ->
    1 >= length([x || #ofp_instruction_clear_actions{} <- Instructions]);
check_occurrences(ofp_instruction_experimenter, Instructions) ->
    1 >= length([x || #ofp_instruction_experimenter{} <- Instructions]).

do_validate_instructions(SwitchId, TableId,
                         [Instruction | Instructions], Match) ->
    case validate_instruction(SwitchId, TableId, Instruction, Match) of
        ok ->
            do_validate_instructions(SwitchId, TableId, Instructions, Match);
        Error ->
            Error
    end;
do_validate_instructions(_SwitchId, _TableId, [], _Match) ->
    ok.

validate_instruction(SwitchId, _TableId,
                     #ofp_instruction_meter{meter_id = MeterId}, _Match) ->
    case linc_us5_meter:is_valid(SwitchId, MeterId) of
        true ->
            ok;
        false ->
            %% There is not suitable error code
            {error,{bad_instruction,unsup_inst}}
    end;
validate_instruction(_SwitchId, TableId,
                     #ofp_instruction_goto_table{table_id=NextTable}, _Match)
  when is_integer(TableId), TableId < NextTable, TableId < ?OFPTT_MAX ->
    ok;
validate_instruction(_SwitchId, _TableId,
                     #ofp_instruction_goto_table{}, _Match) ->
    %% goto-table with invalid next-table-id
    {error,{bad_action,bad_table_id}};
validate_instruction(_SwitchId, _TableId,
                     #ofp_instruction_write_metadata{}, _Match) ->
    ok;
validate_instruction(SwitchId, _TableId,
                     #ofp_instruction_write_actions{actions = Actions},
                     Match) ->
    validate_actions(SwitchId, Actions, Match);
validate_instruction(SwitchId, _TableId,
                     #ofp_instruction_apply_actions{actions = Actions},
                     Match) ->
    validate_actions(SwitchId, Actions, Match);
validate_instruction(_SwitchId, _TableId,
                     #ofp_instruction_clear_actions{}, _Match) ->
    ok;
validate_instruction(_SwitchId, _TableId,
                     #ofp_instruction_experimenter{}, _Match) ->
    {error,{bad_instruction,unknown_inst}};
validate_instruction(_SwitchId, _TableId, _Unknown, _Match) ->
    %% unknown instruction
    {error,{bad_instruction,unknown_inst}}.

%% unsupported instruction {error,{bad_instruction,unsup_inst}},

validate_actions(SwitchId, [Action|Actions], Match) ->
    case validate_action(SwitchId, Action, Match) of
        ok ->
            validate_actions(SwitchId, Actions, Match);
        Error ->
            Error
    end;
validate_actions(_SwitchId, [], _Match) ->
    ok.

validate_action(_SwitchId,
                #ofp_action_output{port=controller,max_len=MaxLen}, _Match) ->
    %% no_buffer represents OFPCML_NO_BUFFER (0xFFFF)
    case MaxLen /= no_buffer andalso MaxLen > ?OFPCML_MAX of
        true ->
            {error,{bad_action,bad_argument}};
        false ->
            ok
    end;
validate_action(SwitchId, #ofp_action_output{port=Port}, _Match) ->
    case linc_us5_port:is_valid(SwitchId, Port) of
        true ->
            ok;
        false ->
            {error,{bad_action,bad_out_port}}
    end;
validate_action(SwitchId, #ofp_action_group{group_id=GroupId}, _Match) ->
    case linc_us5_groups:is_valid(SwitchId, GroupId) of
        true ->
            ok;
        false ->
            {error,{bad_action,bad_out_group}}
    end;
validate_action(_SwitchId, #ofp_action_set_queue{}, _Match) ->
    ok;
validate_action(_SwitchId, #ofp_action_set_mpls_ttl{}, _Match) ->
    ok;
validate_action(_SwitchId, #ofp_action_dec_mpls_ttl{}, _Match) ->
    ok;
validate_action(_SwitchId, #ofp_action_set_nw_ttl{}, _Match) ->
    ok;
validate_action(_SwitchId, #ofp_action_dec_nw_ttl{}, _Match) ->
    ok;
validate_action(_SwitchId, #ofp_action_copy_ttl_out{}, _Match) ->
    ok;
validate_action(_SwitchId, #ofp_action_copy_ttl_in{}, _Match) ->
    ok;
validate_action(_SwitchId, #ofp_action_push_vlan{ethertype=Ether}, _Match)
  when Ether == 16#8100; Ether==16#88A8 ->
    ok;
validate_action(_SwitchId, #ofp_action_push_vlan{}, _Match) ->
    {error,{bad_action,bad_argument}};
validate_action(_SwitchId, #ofp_action_pop_vlan{}, _Match) ->
    ok;
validate_action(_SwitchId, #ofp_action_push_mpls{ethertype=Ether}, _Match)
  when Ether==16#8847; Ether==16#8848 ->
    ok;
validate_action(_SwitchId, #ofp_action_push_mpls{}, _Match) ->
    {error,{bad_action,bad_argument}};
validate_action(_SwitchId, #ofp_action_pop_mpls{}, _Match) ->
    ok;
validate_action(_SwitchId, #ofp_action_set_field{field=Field}, Match) ->
    case are_prerequisites_met(Field,Match) of
        true ->
            ok;
        false ->
            {error,{bad_action,bad_argument}}
    end;
validate_action(_SwitchId, #ofp_action_experimenter{}, _Match) ->
    {error,{bad_action,bad_type}}.

%% Check that field value is in the allowed domain
%% TODO
is_value_valid(#ofp_field{name=_Name,value=_Value}) ->
    true.

%% @private Check that the mask is correct for the given value
is_mask_valid(#ofp_field{has_mask = true, value = Value, mask = Mask}) ->
    try is_mask_valid(Value, Mask) of
        _ -> true
    catch
        throw:bad_mask ->
            false
    end;
is_mask_valid(#ofp_field{has_mask = false}) ->
    true.

is_mask_valid(<<0:1, RestValue/bitstring>>, <<_:1, RestMask/bitstring>>) ->
    is_mask_valid(RestValue, RestMask);
is_mask_valid(<<1:1, RestValue/bitstring>>, <<1:1, RestMask/bitstring>>) ->
    is_mask_valid(RestValue, RestMask);
is_mask_valid(<<>>, <<>>) ->
    true;
is_mask_valid(_, _) ->
    throw(bad_mask).

delayed_replace_existing_flow(Msg = #ofp_message{
                                       body = #ofp_flow_mod{table_id = TableId,
                                                            flags = Flags} = FlowMod},
                              #flow_entry{id = Id} = Existing,
                              Acc = #bundle_commit{inserts = Added,
                                                   keep_flow_counters = KeepFlowCounters}) ->
    %% Check that this flow entry is not among the recently added or modified:
    case already_added(TableId, Id, Acc)
        orelse already_modified(TableId, Id, Acc) of
        true ->
            bundle_error(Msg, Acc, bundle_failed, msg_conflict);
        false ->
            case lists:member(reset_counts, Flags) of
                true ->
                    %% Reset flow counters
                    %% Store new flow and remove the previous one
                    Acc1 = delayed_add_new_flow(Msg, Acc),
                    delayed_delete_flow(TableId, Existing, no_event, Acc1);
                false ->
                    NewEntry = (create_flow_entry(FlowMod))#flow_entry{id = Id},
                    Acc1 = Acc#bundle_commit{inserts = [{TableId, NewEntry}] ++ Added,
                                             keep_flow_counters = [Id] ++ KeepFlowCounters},
                    %% We wouldn't strictly need to delete the entry, as it
                    %% would be overwritten by the new one, but we need to
                    %% make a note of it in the state.
                    delayed_delete_flow(TableId, Existing, no_event, Acc1)
            end
    end.

%% Modify an existing flow. This only modifies the instructions, leaving all other
%% fields unchanged.
delayed_modify_flow(TableId,
                    #flow_entry{id = Id} = Flow,
                    NewInstructions, Flags,
                    Acc = #bundle_commit{modifications = Modified,
                                         keep_flow_counters = KeepFlowCounters}) ->
    NewFlow = Flow#flow_entry{instructions = NewInstructions},
    Acc1 = Acc#bundle_commit{modifications = [{TableId, Flow, NewFlow}] ++ Modified},
    case lists:member(reset_counts, Flags) of
        true ->
            Acc1;
        false ->
            Acc1#bundle_commit{keep_flow_counters = [Id] ++ KeepFlowCounters}
    end.


modify_flow(SwitchId, TableId,
            #flow_entry{id = Id, instructions = PrevInstructions} = OldFlow,
            #flow_entry{instructions = NewInstructions}, ResetCounters, MonitorData) ->
    ets:update_element(flow_table_ets(SwitchId, TableId),
                       Id,
                       {#flow_entry.instructions, NewInstructions}),
    ?DEBUG("[FLOWMOD] New instructions for flow entry ~w: ~w",
           [Id, NewInstructions]),
    increment_group_ref_count(SwitchId, NewInstructions),
    decrement_group_ref_count(SwitchId, PrevInstructions),
    linc_us5_monitor:monitor(SwitchId, modified, TableId, MonitorData,
                             OldFlow#flow_entry{instructions = NewInstructions}),
    case ResetCounters of
        true ->
            true = ets:insert(linc:lookup(SwitchId, flow_entry_counters),
                              #flow_entry_counter{id = Id}),
            ok;
        false ->
            %% Do nothing
            ok
    end.

%%============================================================================
%% Various counter functions
create_flow_entry_counter(SwitchId, FlowId) ->
    true = ets:insert(linc:lookup(SwitchId, flow_entry_counters),
                      #flow_entry_counter{id = FlowId}).

get_flow_stats(SwitchId, TableId, Cookie, CookieMask,
               Match, OutPort, OutGroup) ->
    ets:foldl(fun (#flow_entry{id = FlowId,
                               cookie = MyCookie,
                               flags = Flags,
                               priority = Priority,
                               install_time = InstallTime,
                               match = MyMatch,
                               instructions = Instructions}=FlowEntry, Acc) ->
                      case cookie_match(MyCookie, Cookie, CookieMask)
                          andalso non_strict_match(FlowEntry, Match)
                          andalso port_and_group_match(OutPort,
                                                       OutGroup,
                                                       Instructions)
                      of
                          true ->
                              DurationMs = timer:now_diff(os:timestamp(),InstallTime),
                              Counters = ets:lookup(linc:lookup(SwitchId, flow_entry_counters), FlowId),
                              [#flow_entry_counter{
                                  received_packets = Packets,
                                  received_bytes   = Bytes}] = Counters,

                              #flow_timer{idle_timeout = IdleTimeout,
                                          hard_timeout = HardTimeout} = get_flow_timer(SwitchId, FlowId),
                              
                              Stats = #ofp_flow_stats{
                                         table_id = TableId,
                                         duration_sec = DurationMs div 1000000,
                                         duration_nsec = DurationMs rem 1000000 * 1000,
                                         idle_timeout = IdleTimeout,
                                         hard_timeout = HardTimeout,
                                         flags = Flags,
                                         packet_count = Packets,
                                         byte_count = Bytes,
                                         priority = Priority,
                                         cookie = MyCookie,
                                         match = MyMatch,
                                         instructions = Instructions},
                              [Stats|Acc];
                          false ->
                              Acc
                      end
              end, [], flow_table_ets(SwitchId, TableId)).

get_aggregate_stats(SwitchId, TableId,Cookie, CookieMask,
                    Match, OutPort, OutGroup) ->
    ets:foldl(fun (#flow_entry{id = FlowId,
                               cookie = MyCookie,
                               instructions = Instructions}=FlowEntry, 
                   {PacketsAcc,BytesAcc,FlowsAcc}=Acc) ->
                      case cookie_match(MyCookie, Cookie, CookieMask)
                          andalso non_strict_match(FlowEntry, Match)
                          andalso port_and_group_match(OutPort,
                                                       OutGroup,
                                                       Instructions)
                      of
                          true ->
                              FlowEntryCounters = linc:lookup(SwitchId,
                                                              flow_entry_counters),
                              Counters = ets:lookup(FlowEntryCounters, FlowId),
                              [#flow_entry_counter{
                                  received_packets = Packets,
                                  received_bytes   = Bytes}] = Counters,
                              {PacketsAcc+Packets,BytesAcc+Bytes,FlowsAcc+1};
                          false ->
                              Acc
                      end
              end, {0,0,0}, flow_table_ets(SwitchId, TableId)).

merge_aggregate_stats(Stats) ->
    lists:foldl(fun ({Packets,Bytes,Flows}, {PacketsAcc,BytesAcc,FlowsAcc}) ->
                        {PacketsAcc+Packets, BytesAcc+Bytes, FlowsAcc+Flows}
                end,{0,0,0},Stats).

get_table_stats(SwitchId) ->
    [get_table_stats1(SwitchId, TableId) || TableId <- lists:seq(0, ?OFPTT_MAX)].

get_table_stats1(SwitchId, TableId) ->
    [#flow_table_counter{packet_lookups = Lookups,
                         packet_matches = Matches}]
        = ets:lookup(linc:lookup(SwitchId, flow_table_counters), TableId),
    #ofp_table_stats{
       table_id = TableId,
       active_count = ets:info(flow_table_ets(SwitchId, TableId), size),
       lookup_count = Lookups,
       matched_count = Matches}.

%%============================================================================
%% Various timer functions

create_flow_timer(SwitchId, TableId, FlowId, IdleTime, HardTime) ->
    Now = os:timestamp(),
    true = ets:insert(linc:lookup(SwitchId, flow_timers),
                      #flow_timer{id = FlowId,
                                  table = TableId,
                                  idle_timeout = IdleTime,
                                  expire = calc_timeout(Now, IdleTime),
                                  hard_timeout = HardTime,
                                  remove = calc_timeout(Now, HardTime)
                                 }).

get_flow_timer(SwitchId, FlowId) ->
    case ets:lookup(linc:lookup(SwitchId, flow_timers), FlowId) of
        [Rec] ->
            Rec;
        [] ->
            undefined
    end.

delete_flow_timer(SwitchId, FlowId) ->
    ets:delete(linc:lookup(SwitchId, flow_timers), FlowId).

calc_timeout(_Now, 0) ->
    infinity;
calc_timeout({Mega,Secs,Micro},Time) ->
    case Secs+Time of
        S when S>999999 ->
            {Mega+1,S-999999,Micro};
        S ->
            {Mega,S,Micro}
    end.

check_timers(SwitchId) ->
    Now = os:timestamp(),
    ets:foldl(fun (Flow, ok) ->
                      case hard_timeout(SwitchId, Now, Flow) of
                          false ->
                              idle_timeout(SwitchId, Now, Flow),
                              ok;
                          true ->
                              ok
                      end
              end, ok, linc:lookup(SwitchId, flow_timers)).

hard_timeout(_SwitchId, _Now, #flow_timer{remove = infinity}) ->
    false;
hard_timeout(SwitchId, Now,
             #flow_timer{id = FlowId, table = TableId, remove = Remove})
  when Remove < Now ->
    delete_flow(SwitchId, TableId, get_flow(SwitchId, TableId, FlowId),
                hard_timeout, true, #monitor_data{}),
    true;
hard_timeout(_SwitchId, _Now, _Flow) ->
    false.

idle_timeout(_SwitchId, _Now, #flow_timer{expire = infinity}) ->
    false;
idle_timeout(SwitchId, Now,
             #flow_timer{id = FlowId, table = TableId, expire = Expire})
  when Expire < Now ->
    delete_flow(SwitchId, TableId, get_flow(SwitchId, TableId, FlowId),
                idle_timeout, true, #monitor_data{}),
    true;
idle_timeout(_SwitchId, _Now, _Flow) ->
    false.

%%============================================================================
%% Various lookup functions

get_flow(SwitchId, TableId, FlowId) ->
    hd(ets:lookup(flow_table_ets(SwitchId, TableId), FlowId)).

%% Get all flows with Priority.
get_flows_by_priority(SwitchId, TableId, Priority) ->
    Pattern = #flow_entry{id = {Priority,'_'},
                          priority = Priority,
                          _ = '_'
                         },
    ets:match_object(flow_table_ets(SwitchId, TableId), Pattern).

%% Find an existing flow with the same Priority and the exact same match expression.
-spec find_exact_match(integer(), ofp_table_id(),
                       non_neg_integer(), ofp_match(),
                       [{ofp_table_id(), #flow_entry{}}],
                       [{ofp_table_id(), #flow_entry{}}]) -> flow_id() | no_match.
find_exact_match(SwitchId, TableId, Priority, Match, Added, Deleted) ->
    Pattern = ets:fun2ms(fun (#flow_entry{id={Prio,_},
                                          match=#ofp_match{fields=Fields}}=Flow)
                               when Prio==Priority, Fields==Match ->
                                 Flow
                         end),
    FlowTable = flow_table_ets(SwitchId, TableId),
    SelectedFromTable = ets:select(FlowTable, Pattern),
    %% Exclude flow entries that have been deleted in this bundle.
    SelectedNotDeleted =
        case Deleted of
            [] -> SelectedFromTable;
            [_|_] ->
                lists:filter(
                  fun(#flow_entry{id = FlowId}) ->
                          not already_deleted(TableId, FlowId, Deleted)
                  end, SelectedFromTable)
        end,
    %% Include flow entries that are newly added
    SelectedAdded =
        lists:filter(
          fun({TheTableId, #flow_entry{id = {Prio,_},
                                       match = #ofp_match{fields = Fields}}}) ->
                  TheTableId =:= TableId andalso
                      Prio =:= Priority andalso
                      Fields =:= Match
          end, Added),
    Selected = SelectedAdded ++ SelectedNotDeleted,
    case Selected of
        [Flow|_] =_Match->
            Flow;
        [] ->
            no_match
    end.

%% Modify flows that are matching
delayed_modify_matching_flows(SwitchId, TableId, Cookie, CookieMask,
                              Match, Instructions, Flags, Msg, Acc) ->
    ets:foldl(fun (#flow_entry{id=FlowId, cookie=MyCookie}=FlowEntry, Acc1) ->
                          case cookie_match(MyCookie, Cookie, CookieMask)
                              andalso non_strict_match(FlowEntry, Match) of
                              true ->
                                  case already_added(TableId, FlowId, Acc) of
                                      true ->
                                          bundle_error(Msg, Acc1, bundle_failed, msg_conflict);
                                      false ->
                                          delayed_modify_flow(TableId, FlowEntry,
                                                              Instructions, Flags, Acc1)
                                      end;
                              false ->
                                  Acc1
                          end
              end, Acc, flow_table_ets(SwitchId, TableId)).

%% Delete flows that are matching 
delayed_delete_matching_flows(SwitchId, TableId, Cookie, CookieMask,
                              Match, OutPort, OutGroup, Msg,
                              Acc) ->
    ets:foldl(fun (#flow_entry{id=Id, cookie=MyCookie,
                               instructions=Instructions}=FlowEntry, Acc1) ->
                      case cookie_match(MyCookie, Cookie, CookieMask)
                          andalso non_strict_match(FlowEntry, Match)
                          andalso port_and_group_match(OutPort,
                                                       OutGroup,
                                                       Instructions)
                      of
                          true ->
                              case already_added(TableId, Id, Acc)
                                  orelse already_modified(TableId, Id, Acc) of
                                  true ->
                                      bundle_error(Msg, Acc1, bundle_failed, msg_conflict);
                                  false ->
                                      delayed_delete_flow(TableId, FlowEntry, delete, Acc1)
                              end;
                          false ->
                              Acc1
                      end
              end, Acc, flow_table_ets(SwitchId, TableId)).

non_strict_match(#flow_entry{match = #ofp_match{fields = EntryFields}},
                 FlowModFields) ->
    lists:all(fun(#ofp_field{name = Field} = FlowModField) ->
                      case lists:keyfind(Field, #ofp_field.name, EntryFields) of
                          #ofp_field{} = EntryField ->
                              is_more_specific(EntryField, FlowModField);
                          false ->
                              false
                      end
              end, FlowModFields);
non_strict_match(_FlowEntry, _Match) ->
    throw(#ofp_error_msg{type = bad_match, code = bad_type}).

cookie_match(Cookie1, Cookie2, CookieMask) ->
    mask_match(Cookie1, Cookie2, CookieMask).

mask_match(Bin1,Bin2,MaskBin) ->
    Bits = bit_size(Bin1),
    <<Val1:Bits>> = Bin1,
    <<Val2:Bits>> = Bin2,
    <<Mask:Bits>> = MaskBin,
    Val1 band Mask == Val2 band Mask.

is_more_specific(#ofp_field{class = Cls1}, #ofp_field{class = Cls2}) when
      Cls1 =/= openflow_basic; Cls2 =/= openflow_basic ->
    throw(#ofp_error_msg{type = bad_match, code = bad_field});
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
is_mask_more_specific(Bin1, Bin2) ->
    Bits = bit_size(Bin1),
    <<Mask1:Bits>> = Bin1,
    <<Mask2:Bits>> = Bin2,
    Mask1 bor Mask2 == Mask1.

port_and_group_match(any,any,_Instructions) ->
    true;
port_and_group_match(Port,Group,
                     [#ofp_instruction_write_actions{actions=Actions}|Instructions]) ->
    port_and_group_match_actions(Port,Group,Actions) 
        orelse port_and_group_match(Port,Group,Instructions);
port_and_group_match(Port,Group,
                     [#ofp_instruction_apply_actions{actions=Actions}|Instructions]) ->
    port_and_group_match_actions(Port,Group,Actions) 
        orelse port_and_group_match(Port,Group,Instructions);
port_and_group_match(Port,Group,[_|Instructions]) ->
    port_and_group_match(Port,Group,Instructions);
port_and_group_match(_Port,_Group,[]) ->
    false.

port_and_group_match_actions(OutPort,_OutGroup,
                             [#ofp_action_output{port=OutPort}|_]) ->
    true;
port_and_group_match_actions(_OutPort,OutGroup,
                             [#ofp_action_group{group_id=OutGroup}|_]) ->
    true;
port_and_group_match_actions(OutPort,OutGroup,[_|Instructions]) ->
    port_and_group_match_actions(OutPort,OutGroup,Instructions);
port_and_group_match_actions(_OutPort,_OutGroup,[]) ->
    false.

%% Remove all flows that have output to GroupId.
delete_where_group(SwitchId, GroupId, TableId, MonitorData) ->
    ets:foldl(fun (#flow_entry{instructions=Instructions}=FlowEntry, Acc) ->
                      case port_and_group_match(any, GroupId, Instructions) of
                          true ->
                              delete_flow(SwitchId, TableId,
                                          FlowEntry, group_delete, true, MonitorData);
                          false ->
                              Acc
                      end
              end, ok, flow_table_ets(SwitchId, TableId)).

%% Remove all flows that use MeterId.
delete_where_meter(SwitchId, MeterId, TableId, MonitorData) ->
    ets:foldl(fun (#flow_entry{instructions=Instructions}=FlowEntry, Acc) ->
                      case meter_match(MeterId, Instructions) of
                          true ->
                              delete_flow(SwitchId, TableId,
                                          FlowEntry, meter_delete, true, MonitorData);
                          false ->
                              Acc
                      end
              end, ok, flow_table_ets(SwitchId, TableId)).

meter_match(MeterId, Instructions) ->
    [MeterId] == [Id || #ofp_instruction_meter{meter_id=Id} <- Instructions, Id==MeterId].

increment_group_ref_count(SwitchId, Instructions) ->
    update_group_ref_count(SwitchId, Instructions, 1).

decrement_group_ref_count(SwitchId, Instructions) ->
    update_group_ref_count(SwitchId, Instructions, -1).

update_group_ref_count(SwitchId, Instructions, Incr) ->
    [linc_us5_groups:update_reference_count(SwitchId, Group,Incr)
     || Group <- get_groups(Instructions)].

%% Find all groups reference from the Instructions
get_groups(Instructions) ->
    get_groups(Instructions, []).

get_groups([#ofp_instruction_write_actions{actions=Actions}|Instructions], Acc) ->
    get_groups(Instructions, Acc++get_groups_in_actions(Actions));
get_groups([#ofp_instruction_apply_actions{actions=Actions}|Instructions], Acc) ->
    get_groups(Instructions, Acc++get_groups_in_actions(Actions));
get_groups([_|Instructions], Acc) ->
    get_groups(Instructions, Acc);
get_groups([], Acc) ->
    Acc.

get_groups_in_actions(Actions) ->
    [Group||#ofp_action_group{group_id=Group} <- Actions].
