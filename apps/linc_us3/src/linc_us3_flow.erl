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
-module(linc_us3_flow).

%% API
-export([initialize/1,
         terminate/1,
         table_mod/2,
         modify/2,
         get_flow_table/2,
         delete_where_group/2,
         get_stats/2,
         get_aggregate_stats/2,
         get_table_config/2,
         get_table_stats/2,
         update_lookup_counter/2,
         update_match_counters/4,
         reset_idle_timeout/2
        ]).

%% Internal exports
-export([check_timers/1]).

-include_lib("of_protocol/include/of_protocol.hrl").
-include_lib("of_protocol/include/ofp_v3.hrl").
-include_lib("linc/include/linc_logger.hrl").
-include_lib("stdlib/include/ms_transform.hrl").
-include("linc_us3.hrl").

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

    {ok,Tref} = timer:apply_interval(1000, linc_us3_flow,
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
-spec table_mod(integer(), #ofp_table_mod{}) -> ok.
table_mod(SwitchId, #ofp_table_mod{table_id = all, config = Config}) ->
    [set_table_config(SwitchId, Table,Config)||Table<-lists:seq(0, ?OFPTT_MAX)],
    ok;
table_mod(SwitchId, #ofp_table_mod{table_id = TableId, config = Config}) ->
    set_table_config(SwitchId, TableId,Config),
    ok.

set_table_config(SwitchId, Table,Config) ->
    ets:insert(linc:lookup(SwitchId, flow_table_config),
               #flow_table_config{id=Table,config=Config}).

-spec get_table_config(integer(), integer()) -> drop | controller | continue.
get_table_config(SwitchId, TableId) ->
    case ets:lookup(linc:lookup(SwitchId, flow_table_config), TableId) of
        [#flow_table_config{config=Config}] ->
            Config;
        [] ->
            controller
    end.

%% @doc Handle a flow_mod request from a controller. This may add/modify/delete one or
%% more flows.
-spec modify(integer(), #ofp_flow_mod{}) -> ok |
                                            {error, {Type :: atom(), Code :: atom()}}.
modify(_SwitchId, #ofp_flow_mod{command=Cmd, table_id=all})
  when Cmd==add;Cmd==modify;Cmd==modify_strict ->
    {error, {flow_mod_failed, bad_table_id}};
modify(SwitchId, #ofp_flow_mod{command=Cmd, buffer_id=BufferId}=FlowMod)
  when (Cmd==add orelse Cmd==modify orelse Cmd==modify_strict)
       andalso BufferId /= no_buffer ->
    %% A buffer_id is provided, we have to first do the flow_mod
    %% and then a packet_out to OFPP_TABLE. This actually means to first
    %% perform the flow_mod and then restart the processing of the buffered
    %% packet starting in flow_table=0.
    case modify(SwitchId, FlowMod#ofp_flow_mod{buffer_id=no_buffer}) of
        ok ->
            case linc_buffer:get_buffer(SwitchId, BufferId) of
                #linc_pkt{}=OfsPkt ->
                    linc_us3_actions:apply_list(OfsPkt,
                                                [#ofp_action_output{port=table}]);
                not_found ->
                    %% Buffer has been dropped, ignore
                    ok
            end;
        Error ->
            Error
    end;
modify(SwitchId, #ofp_flow_mod{command=add,
                               table_id=TableId,
                               priority=Priority,
                               flags=Flags,
                               match=#ofp_match{fields=Match},
                               instructions=Instructions}=FlowMod) ->
    case validate_match_and_instructions(SwitchId, TableId,
                                         Match, Instructions) of
        ok ->
            case lists:member(check_overlap,Flags) of
                true ->
                    %% Check that there are no overlapping flows.
                    case check_overlap(SwitchId, TableId, Priority, Match) of
                        true ->
                            {error, {flow_mod_failed,overlap}};
                        false ->
                            add_new_flow(SwitchId, TableId, FlowMod)
                    end;
                false ->
                    %% Check if there is any entry with the exact same 
                    %% priority and match
                    case find_exact_match(SwitchId, TableId,
                                          Priority, Match) of
                        #flow_entry{}=Matching ->
                            replace_existing_flow(SwitchId, TableId, FlowMod,
                                                  Matching, Flags);
                        no_match ->
                            add_new_flow(SwitchId, TableId, FlowMod)
                    end
            end;
        Error ->
            Error
    end;
modify(SwitchId, #ofp_flow_mod{command=modify,
                               cookie=Cookie,
                               cookie_mask=CookieMask,
                               table_id=TableId,
                               flags=Flags,
                               match=#ofp_match{fields=Match},
                               instructions=Instructions}) ->
    case validate_match_and_instructions(SwitchId, TableId,
                                         Match, Instructions) of
        ok ->
            modify_matching_flows(SwitchId, TableId, Cookie, CookieMask,
                                  Match, Instructions, Flags),
            ok;
        Error ->
            Error
    end;
modify(SwitchId, #ofp_flow_mod{command=modify_strict,
                               table_id=TableId,
                               priority=Priority,
                               flags=Flags,
                               match=#ofp_match{fields=Match},
                               instructions=Instructions}) ->
    case validate_match_and_instructions(SwitchId, TableId,
                                         Match, Instructions) of
        ok ->
            case find_exact_match(SwitchId, TableId, Priority, Match) of
                #flow_entry{}=Flow ->
                    modify_flow(SwitchId, TableId, Flow, Instructions, Flags);
                no_match ->
                    %% Do nothing
                    ok
            end;
        Error ->
            Error
    end;
modify(SwitchId, #ofp_flow_mod{command=Cmd,
                               table_id=all}=FlowMod)
  when Cmd==delete; Cmd==delete_strict ->
    [modify(SwitchId, FlowMod#ofp_flow_mod{table_id=Id})
     || Id <- lists:seq(0, ?OFPTT_MAX)],
    ok;
modify(SwitchId, #ofp_flow_mod{command=delete,
                               table_id=TableId,
                               cookie=Cookie,
                               cookie_mask=CookieMask,
                               out_port=OutPort,
                               out_group=OutGroup,
                               match=#ofp_match{fields=Match}}) ->
    delete_matching_flows(SwitchId, TableId, Cookie, CookieMask,
                          Match, OutPort, OutGroup),
    ok;
modify(SwitchId, #ofp_flow_mod{command=delete_strict,
                               table_id=TableId,
                               priority=Priority,
                               match=#ofp_match{fields=Match}}) ->
    case find_exact_match(SwitchId, TableId, Priority, Match) of
        #flow_entry{}=FlowEntry ->
            delete_flow(SwitchId, TableId, FlowEntry, delete);
        _ ->
            %% Do nothing
            ok
    end.

%% @doc Get all entries in one flow table.
-spec get_flow_table(integer(), integer()) -> [FlowTableEntryRepresentation :: term()].
get_flow_table(SwitchId, TableId) ->
    lists:reverse(ets:tab2list(flow_table_ets(SwitchId, TableId))).

%% @doc Delete all flow entries that are using a specific group.
-spec delete_where_group(integer(), integer()) -> ok.
delete_where_group(SwitchId, GroupId) ->
    [delete_where_group(SwitchId, GroupId, TableId)
     || TableId <- lists:seq(0, ?OFPTT_MAX)],
    ok.

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
    #ofp_flow_stats_reply{stats = lists:concat(Stats)};

get_stats(SwitchId, #ofp_flow_stats_request{table_id = TableId,
                                            out_port = OutPort,
                                            out_group = OutGroup,
                                            cookie = Cookie,
                                            cookie_mask = CookieMask,
                                            match = #ofp_match{fields=Match}}) ->
    %%TODO
    Stats = get_flow_stats(SwitchId, TableId,Cookie, CookieMask,
                           Match, OutPort, OutGroup),
    #ofp_flow_stats_reply{stats = Stats}.

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
                                 Match, OutPort,
                                 OutGroup) || TableId <- lists:seq(0, ?OFPTT_MAX)],
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
    #ofp_table_stats_reply{stats = get_table_stats(SwitchId)}.

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

%% Check if there exists a flowin flow table=TableId with priority=Priority with
%% a match that overlaps with Match.
check_overlap(SwitchId, TableId, Priority, NewMatch) ->
    ExistingMatches = lists:sort(get_matches_by_priority(SwitchId, TableId,
                                                         Priority)),
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

%% Add a new flow entry.
add_new_flow(SwitchId, TableId,
             #ofp_flow_mod{idle_timeout=IdleTime,
                           hard_timeout=HardTime,
                           instructions=Instructions}=FlowMod) ->
    NewEntry = create_flow_entry(FlowMod),
    %% Create counter before inserting flow in flow table to avoid race.
    create_flow_entry_counter(SwitchId, NewEntry#flow_entry.id),
    create_flow_timer(SwitchId, TableId, NewEntry#flow_entry.id,
                      IdleTime, HardTime),
    ets:insert(flow_table_ets(SwitchId, TableId), NewEntry),
    increment_group_ref_count(SwitchId, Instructions),
    ok.

%% Delete a flow
delete_flow(SwitchId, TableId,
            #flow_entry{id=FlowId,instructions=Instructions, flags=Flags}=Flow,
           Reason) ->
    case lists:member(send_flow_rem, Flags) andalso Reason/=no_event of
        true ->
            send_flow_removed(SwitchId, TableId,Flow,Reason);
        false ->
            %% Do nothing
            ok
    end,
    ets:delete(flow_table_ets(SwitchId, TableId), FlowId),
    ets:delete(linc:lookup(SwitchId, flow_entry_counters), FlowId),
    delete_flow_timer(SwitchId, FlowId),
    decrement_group_ref_count(SwitchId, Instructions),
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
                                       Instructions,Match) of
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
-spec validate_match(Match::[ofp_field()]) -> ok | {error,{Type :: atom(), Code :: atom()}}.
validate_match(Fields) ->
    validate_match(Fields, []).

validate_match([#ofp_field{name=Name}=Field|Fields], Previous) ->
    case is_supported_field(Name) of
        false ->
            {error,{bad_match,bad_field}};
        true ->
            case check_duplicate_fields(Name, Previous) of
                true ->
                    {error,{bad_match,dup_field}};
                false ->
                    case check_prerequisites(Field,Previous) of
                        false ->
                            {error,{bad_match,bad_prereq}};
                        true ->
                            case validate_value(Field) of
                                false ->
                                    {error,{bad_match,bad_value}};
                                true ->
                                    validate_match(Fields,[Field|Previous])
                            end
                    end
            end
    end;
validate_match([],_Previous) ->
    ok.

%% Check that a field is supported.
%% Currently all fields are assumed to be supported
%% TODO
is_supported_field(_Name) ->
    true.

%% Check that the field is not duplicated
check_duplicate_fields(Name, Previous) ->
    lists:keymember(Name, #ofp_field.name, Previous).

%% Check that all prerequisite fields are present and have apropiate values
check_prerequisites(#ofp_field{name=Name},Previous) ->
    case prerequisite_for(Name) of
        [] ->
            true;
        PreReqs ->
            lists:any(fun (Required) ->
                              test_prereq(Required,Previous)
                      end, PreReqs)
    end.

%% Get the prerequisite fields and values for a field
prerequisite_for(in_phy_port) ->
    [in_port];
prerequisite_for(vlan_pcp) ->
    %% this needs work
    [{vlan_vid,none}];
prerequisite_for(ip_dscp) ->
    [{eth_type,<<16#800:16>>},{eth_type,<<16#86dd:16>>}];
prerequisite_for(ip_ecn) ->
    [{eth_type,<<16#800:16>>},{eth_type,<<16#86dd:16>>}];
prerequisite_for(ip_proto) ->
    [{eth_type,<<16#800:16>>},{eth_type,<<16#86dd:16>>}];
prerequisite_for(ipv4_src) ->
    [{eth_type,<<16#800:16>>}];
prerequisite_for(ipv4_dst) ->
    [{eth_type,<<16#800:16>>}];
prerequisite_for(tcp_src) ->
    [{ip_proto,<<6:8>>}];
prerequisite_for(tcp_dst) ->
    [{ip_proto,<<6:8>>}];
prerequisite_for(udp_src) ->
    [{ip_proto,<<17:8>>}];
prerequisite_for(udp_dst) ->
    [{ip_proto,<<17:8>>}];
prerequisite_for(sctp_src) ->
    [{ip_proto,<<132:8>>}];
prerequisite_for(sctp_dst) ->
    [{ip_proto,<<132:8>>}];
prerequisite_for(icmpv4_type) ->
    [{ip_proto,<<1:8>>}];
prerequisite_for(icmpv4_code) ->
    [{ip_proto,<<1:8>>}];
prerequisite_for(arp_op) ->
    [{eth_type,<<16#806:16>>}];
prerequisite_for(arp_spa) ->
    [{eth_type,<<16#806:16>>}];
prerequisite_for(arp_tpa) ->
    [{eth_type,<<16#806:16>>}];
prerequisite_for(arp_sha) ->
    [{eth_type,<<16#806:16>>}];
prerequisite_for(arp_tha) ->
    [{eth_type,<<16#806:16>>}];
prerequisite_for(ipv6_src) ->
    [{eth_type,<<16#86dd:16>>}];
prerequisite_for(ipv6_dst) ->
    [{eth_type,<<16#86dd:16>>}];
prerequisite_for(ipv6_flabel) ->
    [{eth_type,<<16#86dd:16>>}];
prerequisite_for(icmpv6_type) ->
    [{ip_proto,<<58:8>>}];
prerequisite_for(icmpv6_code) ->
    [{ip_proto,<<58:8>>}];
prerequisite_for(ipv6_nd_target) ->
    [{icmpv6_type,<<135:8>>},{icmpv6_type,<<136:8>>}];
prerequisite_for(ipv6_nd_sll) ->
    [{icmpv6_type,<<135:8>>}];
prerequisite_for(ipv6_nd_tll) ->
    [{icmpv6_type,<<136:8>>}];
prerequisite_for(mpls_label) ->
    [{eth_type,<<16#8847:16>>},{eth_type,<<16#8848:16>>}];
prerequisite_for(mpls_tc) ->
    [{eth_type,<<16#8847:16>>},{eth_type,<<16#8848:16>>}];
prerequisite_for(mpls_bos) ->
    [{eth_type,<<16#8847:16>>},{eth_type,<<16#8848:16>>}];
prerequisite_for(pbb_isid) ->
    [{eth_type,<<16#88E7:16>>}];
prerequisite_for(ipv6_exthdr) ->
    [{eth_type,<<16#86dd:16>>}];
prerequisite_for(_) ->
    [].

test_prereq({vlan_pcp,_Value},Previous) ->
    case lists:keyfind(vlan_pcp, #ofp_field.name,Previous) of
        #ofp_field{value=Value} when Value/=none ->
            true;
        _ ->
            false
    end;
test_prereq({Field,Value},Previous) ->
    case lists:keyfind(Field, #ofp_field.name,Previous) of
        #ofp_field{value=Value} ->
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
    case lists:all(fun (Type) ->
                           check_occurrences(Type, Instructions)
                   end, ?INSTRUCTIONS) of
        true ->
            ok;
        false ->
            %% FIXME: The spec 1.2 does not specify an error for this case.
            %% So for now we return this.
            {error,{bad_instruction, unknown_inst}}
    end.

check_occurrences(ofp_instruction_goto_table, Instructions) ->
    1 >= length([x||#ofp_instruction_goto_table{}<-Instructions]);
check_occurrences(ofp_instruction_write_metadata, Instructions) ->
    1 >= length([x||#ofp_instruction_write_metadata{}<-Instructions]);
check_occurrences(ofp_instruction_write_actions, Instructions) ->
    1 >= length([x||#ofp_instruction_write_actions{}<-Instructions]);
check_occurrences(ofp_instruction_apply_actions, Instructions) ->
    1 >= length([x||#ofp_instruction_apply_actions{}<-Instructions]);
check_occurrences(ofp_instruction_clear_actions, Instructions) ->
    1 >= length([x||#ofp_instruction_clear_actions{}<-Instructions]);
check_occurrences(ofp_instruction_experimenter, Instructions) ->
    1 >= length([x||#ofp_instruction_experimenter{}<-Instructions]).

do_validate_instructions(SwitchId, TableId,
                         [Instruction|Instructions], Match) ->
    case validate_instruction(SwitchId, TableId, Instruction, Match) of
        ok ->
            do_validate_instructions(SwitchId, TableId, Instructions, Match);
        Error ->
            Error
    end;
do_validate_instructions(_SwitchId, _TableId, [], _Match) ->
    ok.

validate_instruction(_SwitchId, TableId,
                     #ofp_instruction_goto_table{table_id=NextTable}, _Match)
  when is_integer(TableId), TableId<NextTable, TableId<?OFPTT_MAX ->
    ok;
validate_instruction(_SwitchId, _TableId,
                     #ofp_instruction_goto_table{}, _Match) ->
    %% goto-table with invalid next-table-id
    {error,{bad_action,bad_table_id}};
validate_instruction(_SwitchId, _TableId,
                     #ofp_instruction_write_metadata{}, _Match) ->
    ok;
validate_instruction(SwitchId, _TableId,
                     #ofp_instruction_write_actions{actions=Actions}, Match) ->
    validate_actions(SwitchId, Actions, Match);
validate_instruction(SwitchId, _TableId,
                     #ofp_instruction_apply_actions{actions=Actions}, Match) ->
    validate_actions(SwitchId, Actions, Match);
validate_instruction(_SwitchId, _TableId, #ofp_instruction_clear_actions{}, _Match) ->
    ok;
validate_instruction(_SwitchId, _TableId, #ofp_instruction_experimenter{}, _Match) ->
    ok;
validate_instruction(_SwitchId, _TableId, _Unknown, _Match) ->
    %% unknown instruction
    {error,{bad_instruction,unknown_inst,_Unknown}}.

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
    OFPCMLNoBuffer = 16#ffff,
    case MaxLen /= OFPCMLNoBuffer andalso MaxLen > ?OFPCML_MAX of
        true ->
            {error,{bad_action,bad_argument}};
        false ->
            ok
    end;
validate_action(SwitchId, #ofp_action_output{port=Port}, _Match) ->
    case linc_us3_port:is_valid(SwitchId, Port) of
        true ->
            ok;
        false ->
            {error,{bad_action,bad_out_port}}
    end;
validate_action(SwitchId, #ofp_action_group{group_id=GroupId}, _Match) ->
    case linc_us3_groups:is_valid(SwitchId, GroupId) of
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
  when Ether == 16#8100; Ether==16#88A8 ->
    ok;
validate_action(_SwitchId, #ofp_action_push_mpls{}, _Match) ->
    {error,{bad_action,bad_argument}};
validate_action(_SwitchId, #ofp_action_pop_mpls{}, _Match) ->
    ok;
validate_action(_SwitchId, #ofp_action_set_field{field=Field}, Match) ->
    case check_prerequisites(Field,Match) of
        true ->
            ok;
        false ->
            {error,{bad_action,bad_argument}}
    end;
validate_action(_SwitchId, #ofp_action_experimenter{}, _Match) ->
    {error,{bad_action,bad_experimenter}}.

%% Check that field value is in the allowed domain
%% TODO
validate_value(#ofp_field{name=_Name,value=_Value}) ->
    true.

%% Replace a flow with a new one, possibly keeping the counters
%% from the old one. This is used when adding a flow with exactly
%% the same match as an existing one.
replace_existing_flow(SwitchId, TableId,
                      #ofp_flow_mod{instructions=NewInstructions}=FlowMod,
                      #flow_entry{id=Id,instructions=PrevInstructions}=Existing,
                      Flags) ->
    case lists:member(reset_counts, Flags) of
        true ->
            %% Reset flow counters
            %% Store new flow and remove the previous one
            add_new_flow(SwitchId, TableId, FlowMod),
            delete_flow(SwitchId, TableId, Existing, no_event);
        false ->
            %% Do not reset the flow counters
            %% Just store the new flow with the previous FlowId
            increment_group_ref_count(SwitchId, NewInstructions),
            decrement_group_ref_count(SwitchId, PrevInstructions),
            NewEntry = create_flow_entry(FlowMod),
            ets:insert(flow_table_ets(SwitchId, TableId),
                       NewEntry#flow_entry{id=Id}),
            ok
    end.

%% Modify an existing flow. This only modifies the instructions, leaving all other
%% fields unchanged.
modify_flow(SwitchId, TableId, #flow_entry{id=Id,instructions=PrevInstructions},
            NewInstructions, Flags) ->
    ets:update_element(flow_table_ets(SwitchId, TableId),
                       Id,
                       {#flow_entry.instructions, NewInstructions}),
    increment_group_ref_count(SwitchId, NewInstructions),
    decrement_group_ref_count(SwitchId, PrevInstructions),
    case lists:member(reset_counts, Flags) of
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
       name = list_to_binary(io_lib:format("Flow Table 0x~2.16.0b", [TableId])),
       match = ?SUPPORTED_MATCH_FIELDS,
       wildcards = ?SUPPORTED_WILDCARDS,
       write_actions = ?SUPPORTED_WRITE_ACTIONS,
       apply_actions = ?SUPPORTED_APPLY_ACTIONS,
       write_setfields = ?SUPPORTED_WRITE_SETFIELDS,
       apply_setfields = ?SUPPORTED_APPLY_SETFIELDS,
       metadata_match = ?SUPPORTED_METADATA_MATCH, %<<-1:64>>,
       metadata_write = ?SUPPORTED_METADATA_WRITE, %<<-1:64>>,
       instructions = ?SUPPORTED_INSTRUCTIONS,
       config = get_table_config(SwitchId, TableId),
       max_entries = ?MAX_FLOW_TABLE_ENTRIES,
       active_count = ets:info(flow_table_ets(SwitchId, TableId),size),
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
                hard_timeout),
    true;
hard_timeout(_SwitchId, _Now, _Flow) ->
    false.

idle_timeout(_SwitchId, _Now, #flow_timer{expire = infinity}) ->
    false;
idle_timeout(SwitchId, Now, #flow_timer{id = FlowId, table = TableId, expire = Expire})
  when Expire < Now ->
    delete_flow(SwitchId, TableId, get_flow(SwitchId, TableId, FlowId),
                idle_timeout),
    true;
idle_timeout(_SwitchId, _Now, _Flow) ->
    false.

%%============================================================================
%% Various lookup functions

get_flow(SwitchId, TableId, FlowId) ->
    hd(ets:lookup(flow_table_ets(SwitchId, TableId), FlowId)).

%% Get the match pattern from all flows with Priority.
get_matches_by_priority(SwitchId, TableId, Priority) ->
    Pattern = #flow_entry{id = {Priority,'_'},
                          priority = Priority,
                          match = #ofp_match{fields='$1'},
                          _ = '_'
                         },
    [M || [M] <- ets:match(flow_table_ets(SwitchId, TableId), Pattern)].

%% Find an existing flow with the same Priority and the exact same match expression.
-spec find_exact_match(integer(), ofp_table_id(),
                       non_neg_integer(), ofp_match()) -> flow_id()|no_match.
find_exact_match(SwitchId, TableId, Priority, Match) ->
    Pattern = ets:fun2ms(fun (#flow_entry{id={Prio,_},
                                          match=#ofp_match{fields=Fields}}=Flow)
                               when Prio==Priority, Fields==Match ->
                                 Flow
                         end),
    FlowTable = flow_table_ets(SwitchId, TableId),
    case ets:select(FlowTable, Pattern) of
        [Flow|_] =_Match->
            Flow;
        [] ->
            no_match
    end.

%% Modify flows that are matching 
modify_matching_flows(SwitchId, TableId, Cookie, CookieMask,
                      Match, Instructions, Flags) ->
    ets:foldl(fun (#flow_entry{cookie=MyCookie}=FlowEntry, Acc) ->
                      case cookie_match(MyCookie, Cookie, CookieMask)
                          andalso non_strict_match(FlowEntry, Match) of
                          true ->
                              modify_flow(SwitchId, TableId, FlowEntry,
                                          Instructions, Flags);
                          false ->
                              Acc
                      end
              end, [], flow_table_ets(SwitchId, TableId)).

%% Delete flows that are matching 
delete_matching_flows(SwitchId, TableId, Cookie, CookieMask,
                      Match, OutPort, OutGroup) ->
    ets:foldl(fun (#flow_entry{cookie=MyCookie,
                               instructions=Instructions}=FlowEntry, Acc) ->
                      case cookie_match(MyCookie, Cookie, CookieMask)
                          andalso non_strict_match(FlowEntry, Match)
                          andalso port_and_group_match(OutPort,
                                                       OutGroup,
                                                       Instructions)
                      of
                          true ->
                              delete_flow(SwitchId, TableId, FlowEntry, delete);
                          false ->
                              Acc
                      end
              end, [], flow_table_ets(SwitchId, TableId)).

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
delete_where_group(SwitchId, GroupId, TableId) ->
    ets:foldl(fun (#flow_entry{instructions=Instructions}=FlowEntry, Acc) ->
                      case port_and_group_match(any, GroupId, Instructions) of
                          true ->
                              delete_flow(SwitchId, TableId,
                                          FlowEntry, group_delete);
                          false ->
                              Acc
                      end
              end, ok, flow_table_ets(SwitchId, TableId)).

increment_group_ref_count(SwitchId, Instructions) ->
    update_group_ref_count(SwitchId, Instructions, 1).

decrement_group_ref_count(SwitchId, Instructions) ->
    update_group_ref_count(SwitchId, Instructions, -1).

update_group_ref_count(SwitchId, Instructions, Incr) ->
    [linc_us3_groups:update_reference_count(SwitchId, Group,Incr)
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
