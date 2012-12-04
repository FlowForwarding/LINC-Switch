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
-module(linc_us4_flow).

%% API
-export([initialize/0,
         terminate/1,
         table_mod/1,
         modify/1,
         get_flow_table/1,
         delete_where_group/1,
         delete_where_meter/1,
         get_stats/1,
         get_aggregate_stats/1,
         get_table_config/1,
         get_table_stats/1,
         update_lookup_counter/1,
         update_match_counters/3,
         reset_idle_timeout/2
        ]).

%% Internal exports
-export([check_timers/0]).

-include_lib("of_protocol/include/of_protocol.hrl").
-include_lib("of_protocol/include/ofp_v3.hrl").
-include_lib("linc/include/linc.hrl").
-include_lib("stdlib/include/ms_transform.hrl").
-include("linc_us4.hrl").

-define(MAX64, 16#FFFFFFFF). % Max countervalue for 64 bit counters
-define(INSTRUCTIONS, [ofp_instruction_goto_table, ofp_instruction_write_metadata,
                       ofp_instruction_write_actions, ofp_instruction_apply_actions,
                       ofp_instruction_clear_actions, ofp_instruction_experimenter]).

-record(state,{tref}).

%% @doc Initialize the flow tables module. Only to be called on system startup.
-spec initialize() -> State::term().
initialize() ->
    %% Flows
    ets:new(flow_table_counters,
            [named_table, public,
             {keypos, #flow_table_counter.id},
             {write_concurrency, true}]),

    ets:new(flow_table_config,
            [named_table, public,
             {keypos, #flow_table_config.id},
             {read_concurrency, true}]),

    [create_flow_table(Id) || Id <- lists:seq(0, ?OFPTT_MAX)],

    ets:new(flow_timers,
            [named_table, public,
             {keypos, #flow_timer.id},
             {write_concurrency, true}]),

    {ok,Tref} = timer:apply_interval(1000, linc_us4_flow, check_timers, []),

    ets:new(flow_entry_counters,
            [named_table, public,
             {keypos, #flow_entry_counter.id},
             {write_concurrency, true}]),
    #state{tref=Tref}.

%% @doc Terminate the flow table module. Only to be called on system shutdown.
-spec terminate(#state{}) -> ok.
terminate(#state{tref=Tref}) ->
    timer:cancel(Tref),
    [ets:delete(flow_table_name(Id)) || Id <- lists:seq(0, ?OFPTT_MAX)],
    ets:delete(flow_table_config),
    ets:delete(flow_table_counters),
    ets:delete(flow_timers),
    ets:delete(flow_entry_counters),
    ok.

%% @doc Handle ofp_table_mod request
-spec table_mod(#ofp_table_mod{}) -> ok.
table_mod(#ofp_table_mod{table_id = all, config = Config}) ->
    [set_table_config(Table,Config)||Table<-lists:seq(0, ?OFPTT_MAX)],
    ok;
table_mod(#ofp_table_mod{table_id = TableId, config = Config}) ->
    set_table_config(TableId,Config),
    ok.

set_table_config(Table,Config) ->
    ets:insert(flow_table_config,#flow_table_config{id=Table,config=Config}).

-spec get_table_config(TableId :: integer()) -> drop | controller | continue.
get_table_config(TableId) ->
    case ets:lookup(flow_table_config,TableId) of
        [#flow_table_config{config=Config}] ->
            Config;
        [] ->
            controller
    end.

%% @doc Handle a flow_mod request from a controller. This may add/modify/delete one or
%% more flows.
-spec modify(#ofp_flow_mod{}) -> ok | {error, {Type :: atom(), Code :: atom()}}.
modify(#ofp_flow_mod{command=Cmd, table_id=all})
  when Cmd==add;Cmd==modify;Cmd==modify_strict ->
    {error, {flow_mod_failed, bad_table_id}};

modify(#ofp_flow_mod{command=Cmd, buffer_id=BufferId}=FlowMod)
  when (Cmd==add orelse Cmd==modify orelse Cmd==modify_strict)
       andalso BufferId /= no_buffer ->
    %% A buffer_id is provided, we have to first do the flow_mod
    %% and then a packet_out to OFPP_TABLE. This actually means to first
    %% perform the flow_mod and then restart the processing of the buffered
    %% packet starting in flow_table=0.
    case modify(FlowMod#ofp_flow_mod{buffer_id=no_buffer}) of
        ok ->
            %% TODO: packet_out
            case linc_us4_buffer:get_buffer(BufferId) of
                #ofs_pkt{}=OfsPkt ->
                    linc_us4_actions:apply_list(OfsPkt,
                                                [#ofp_action_output{port=table}]);
                not_found ->
                    %% Buffer has been dropped, ignore
                    ok
            end;
        Error ->
            Error
    end;

modify(#ofp_flow_mod{command=add,
                     table_id=TableId,
                     priority=Priority,
                     flags=Flags,
                     match=#ofp_match{fields=Match},
                     instructions=Instructions}=FlowMod) ->
    case validate_match_and_instructions(TableId, Match, Instructions) of
        ok ->
            case lists:member(check_overlap,Flags) of
                true ->
                    %% Check that there are no overlapping flows.
                    case check_overlap(TableId, Priority, Match) of
                        true ->
                            {error, {flow_mod_failed,overlap}};
                        false ->
                            add_new_flow(TableId, FlowMod)
                    end;
                false ->
                    %% Check if there is any entry with the exact same 
                    %% priority and match
                    case find_exact_match(TableId, Priority, Match) of
                        #flow_entry{}=Matching ->
                            replace_existing_flow(TableId, FlowMod,
                                                  Matching, Flags);
                        no_match ->
                            add_new_flow(TableId, FlowMod)
                    end
            end;
        Error ->
            Error
    end;
    
modify(#ofp_flow_mod{command=modify,
                     cookie=Cookie,
                     cookie_mask=CookieMask,
                     table_id=TableId,
                     flags=Flags,
                     match=#ofp_match{fields=Match},
                     instructions=Instructions}) ->
    case validate_match_and_instructions(TableId, Match, Instructions) of
        ok ->
            modify_matching_flows(TableId, Cookie, CookieMask, Match, Instructions, Flags),
            ok;
        Error ->
            Error
    end;

modify(#ofp_flow_mod{command=modify_strict,
                     table_id=TableId,
                     priority=Priority,
                     flags=Flags,
                     match=#ofp_match{fields=Match},
                     instructions=Instructions}) ->
    case validate_match_and_instructions(TableId, Match, Instructions) of
        ok ->
            case find_exact_match(TableId, Priority, Match) of
                #flow_entry{}=Flow ->
                    modify_flow(TableId, Flow, Instructions, Flags);
                no_match ->
                    %% Do nothing
                    ok
            end;
        Error ->
            Error
    end;

modify(#ofp_flow_mod{command=Cmd,
                     table_id=all}=FlowMod)
  when Cmd==delete; Cmd==delete_strict ->
    [modify(FlowMod#ofp_flow_mod{table_id=Id}) || Id <- lists:seq(0, ?OFPTT_MAX)],
    ok;

modify(#ofp_flow_mod{command=delete,
                     table_id=TableId,
                     cookie=Cookie,
                     cookie_mask=CookieMask,
                     out_port=OutPort,
                     out_group=OutGroup,
                     match=#ofp_match{fields=Match}}) ->
    delete_matching_flows(TableId, Cookie, CookieMask, Match, OutPort, OutGroup),
    ok;

modify(#ofp_flow_mod{command=delete_strict,
                     table_id=TableId,
                     priority=Priority,
                     match=#ofp_match{fields=Match}}) ->
            case find_exact_match(TableId, Priority, Match) of
                #flow_entry{}=FlowEntry ->
                    delete_flow(TableId, FlowEntry, delete);
                _ ->
                    %% Do nothing
                    ok
            end.

%% @doc Get all entries in one flow table.
-spec get_flow_table(TableId :: integer()) -> [FlowTableEntryRepresentation :: term()].
get_flow_table(TableId) ->
    ets:tab2list(flow_table_name(TableId)).

%% @doc Delete all flow entries that are using a specific group.
-spec delete_where_group(GroupId :: integer()) -> ok.
delete_where_group(GroupId) ->
    [delete_where_group(GroupId, TableId) || TableId <- lists:seq(0, ?OFPTT_MAX)],
    ok.

%% @doc Delete all flow entries that are pointing to a given meter.
-spec delete_where_meter(integer()) -> ok.
delete_where_meter(_MeterId) ->
    %% TODO: Implement!
    ok.

%% @doc Get flow statistics.
-spec get_stats(#ofp_flow_stats_request{}) -> #ofp_flow_stats_reply{}.
get_stats(#ofp_flow_stats_request{table_id = all,
                                  out_port = OutPort,
                                  out_group = OutGroup,
                                  cookie = Cookie,
                                  cookie_mask = CookieMask,
                                  match = #ofp_match{fields=Match}}) ->
    Stats = [get_flow_stats(TableId,
                            Cookie,
                            CookieMask,
                            Match,
                            OutPort,
                            OutGroup) || TableId <- lists:seq(0, ?OFPTT_MAX)],
    #ofp_flow_stats_reply{stats = lists:concat(Stats)};    

get_stats(#ofp_flow_stats_request{table_id = TableId,
                                  out_port = OutPort,
                                  out_group = OutGroup,
                                  cookie = Cookie,
                                  cookie_mask = CookieMask,
                                  match = #ofp_match{fields=Match}}) ->
    %%TODO
    Stats = get_flow_stats(TableId,Cookie, CookieMask, Match, OutPort, OutGroup),
    #ofp_flow_stats_reply{stats = Stats}.

%% @doc Get aggregate statistics.
-spec get_aggregate_stats(#ofp_aggregate_stats_request{}) -> #ofp_aggregate_stats_reply{}.
get_aggregate_stats(#ofp_aggregate_stats_request{
                       table_id = all,
                       out_port = OutPort,
                       out_group = OutGroup,
                       cookie = Cookie,
                       cookie_mask = CookieMask,
                       match = #ofp_match{fields=Match}}) ->
    %%TODO
    Stats = [get_aggregate_stats(TableId,
                                 Cookie,
                                 CookieMask,
                                 Match,
                                 OutPort,
                                 OutGroup) || TableId <- lists:seq(0, ?OFPTT_MAX)],
    %% TODO: merge results
    {PacketCount,ByteCount,FlowCount} = merge_aggregate_stats(Stats),
    #ofp_aggregate_stats_reply{packet_count = PacketCount,
                               byte_count = ByteCount,
                               flow_count = FlowCount};
get_aggregate_stats(#ofp_aggregate_stats_request{
                       table_id = TableId,
                       out_port = OutPort,
                       out_group = OutGroup,
                       cookie = Cookie,
                       cookie_mask = CookieMask,
                       match = #ofp_match{fields=Match}}) ->
    {PacketCount,ByteCount,FlowCount} = get_aggregate_stats(TableId,
                                                            Cookie,
                                                            CookieMask,
                                                            Match,
                                                            OutPort,
                                                            OutGroup),
    #ofp_aggregate_stats_reply{packet_count = PacketCount,
                               byte_count = ByteCount,
                               flow_count = FlowCount}.
%% @doc Get table statistics.
-spec get_table_stats(#ofp_table_stats_request{}) -> #ofp_table_stats_reply{}.
get_table_stats(#ofp_table_stats_request{}) ->
    #ofp_table_stats_reply{stats=get_table_stats()}.

%% @doc Update the table lookup statistics counters for a table.
-spec update_lookup_counter(TableId :: integer()) -> ok.
update_lookup_counter(TableId) ->
    ets:update_counter(flow_table_counters, TableId,
                       [{#flow_table_counter.packet_lookups, 1, ?MAX64, 0}]),
    ok.

%% @doc Update the match lookup statistics counters for a specific flow.
-spec update_match_counters(TableId :: integer(), FlowId :: integer(),
                            PktByteSize :: integer()) -> ok.
update_match_counters(TableId, FlowId, PktByteSize) ->
    try
        ets:update_counter(flow_table_counters, TableId,
                           [{#flow_table_counter.packet_lookups, 1, ?MAX64, 0},
                            {#flow_table_counter.packet_matches, 1, ?MAX64, 0}]),
        ets:update_counter(flow_entry_counters,
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
-spec reset_idle_timeout(TableId :: integer(), FlowId :: integer()) -> ok.
reset_idle_timeout(_TableId, FlowId) ->
    case get_flow_timer(FlowId) of
        #flow_timer{idle_timeout = 0} ->
            ok;
        #flow_timer{idle_timeout = IdleTimeout}=_R ->
            Now = os:timestamp(),
            Next = calc_timeout(Now, IdleTimeout),
            true = ets:update_element(flow_timers,FlowId,
                                      {#flow_timer.expire, Next}),
            ok
    end.

%%=============================================================================

%% Return flow table name for table Id.
flow_table_name(Id) ->
    list_to_atom(lists:concat([flow_table_,Id])).

%% Create an ETS table for flow table Id, also initialize flow table counters
%% for the table.
create_flow_table(Id) ->
    Tid = ets:new(flow_table_name(Id), [ordered_set, named_table, public,
                                        {keypos, #flow_entry.id},
                                        {read_concurrency, true}]),
    ets:insert(flow_table_counters, #flow_table_counter{id = Id}),
    Tid.

%% Check if there exists a flowin flow table=TableId with priority=Priority with
%% a match that overlaps with Match.
check_overlap(TableId, Priority, NewMatch) ->
    ExistingMatches = lists:sort(get_matches_by_priority(TableId, Priority)),
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
add_new_flow(TableId, #ofp_flow_mod{idle_timeout=IdleTime,
                                    hard_timeout=HardTime,
                                    instructions=Instructions}=FlowMod) ->
    NewEntry = create_flow_entry(FlowMod),
    %% Create counter before inserting flow in flow table to avoid race.
    create_flow_entry_counter(NewEntry#flow_entry.id),
    create_flow_timer(TableId, NewEntry#flow_entry.id, IdleTime, HardTime),
    ets:insert(flow_table_name(TableId), NewEntry),
    increment_group_ref_count(Instructions),
    ok.

%% Delete a flow
delete_flow(TableId,
            #flow_entry{id=FlowId,instructions=Instructions, flags=Flags}=Flow,
           Reason) ->
    case lists:member(send_flow_rem, Flags) andalso Reason/=no_event of
        true ->
            send_flow_removed(TableId,Flow,Reason);
        false ->
            %% Do nothing
            ok
    end,
    ets:delete(flow_table_name(TableId), FlowId),
    ets:delete(flow_entry_counters, FlowId),
    delete_flow_timer(FlowId),
    decrement_group_ref_count(Instructions),
    ok.

send_flow_removed(TableId,
                  #flow_entry{id = FlowId,
                              cookie = Cookie,
                              priority = Priority,
                              install_time = InstallTime,
                              match = Match},
                  Reason) ->
    DurationMs = timer:now_diff(os:timestamp(),InstallTime),
    [#flow_entry_counter{
       received_packets = Packets,
       received_bytes   = Bytes}] = ets:lookup(flow_entry_counters,FlowId),

    #flow_timer{idle_timeout = IdleTimeout,
                hard_timeout = HardTimeout} = get_flow_timer(FlowId),

    Body = #ofp_flow_removed{
              cookie = Cookie,
              priority =Priority,
              reason = Reason,
              table_id = TableId,
              duration_sec = DurationMs div 1000000,
              duration_nsec = DurationMs * 1000,
              idle_timeout = IdleTimeout,
              hard_timeout = HardTimeout,
              packet_count = Packets,
              byte_count = Bytes,
              match = Match},
    Msg = #ofp_message{type = ofp_flow_removed,
                       body = Body
                      },
    linc_logic:send_to_controllers(Msg).

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

validate_match_and_instructions(TableId, Match, Instructions) ->
    case validate_match(Match) of
        ok ->
            case validate_instructions(TableId,Instructions,Match) of
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
    [{eth_type,16#800},{eth_type,16#86dd}];
prerequisite_for(ip_ecn) ->
    [{eth_type,16#800},{eth_type,16#86dd}];
prerequisite_for(ip_proto) ->
    [{eth_type,<<16#800:16>>},{eth_type,<<16#86dd:16>>}];
prerequisite_for(ipv4_src) ->
    [{eth_type,16#800}];
prerequisite_for(ipv4_dst) ->
    [{eth_type,16#800}];
prerequisite_for(tcp_src) ->
    [{ip_proto,6}];
prerequisite_for(tcp_dst) ->
    [{ip_proto,6}];
prerequisite_for(udp_src) ->
    [{ip_proto,17}];
prerequisite_for(udp_dst) ->
    [{ip_proto,17}];
prerequisite_for(sctp_src) ->
    [{ip_proto,132}];
prerequisite_for(sctp_dst) ->
    [{ip_proto,132}];
prerequisite_for(icmpv4_type) ->
    [{ip_proto,1}];
prerequisite_for(icmpv4_code) ->
    [{ip_proto,1}];
prerequisite_for(arp_op) ->
    [{eth_type,16#806}];
prerequisite_for(arp_spa) ->
    [{eth_type,16#806}];
prerequisite_for(arp_tpa) ->
    [{eth_type,16#806}];
prerequisite_for(arp_sha) ->
    [{eth_type,16#806}];
prerequisite_for(arp_tha) ->
    [{eth_type,16#806}];
prerequisite_for(ipv6_src) ->
    [{eth_type,16#86dd}];
prerequisite_for(ipv6_dst) ->
    [{eth_type,16#86dd}];
prerequisite_for(ipv6_flabel) ->
    [{eth_type,16#86dd}];
prerequisite_for(icmpv6_type) ->
    [{ip_proto,58}];
prerequisite_for(icmpv6_code) ->
    [{ip_proto,58}];
prerequisite_for(ipv6_nd_target) ->
    [{icmpv6_type,135},{icmpv6_type,136}];
prerequisite_for(ipv6_nd_sll) ->
    [{icmpv6_type,135}];
prerequisite_for(ipv6_nd_tll) ->
    [{icmpv6_type,136}];
prerequisite_for(mpls_label) ->
    [{eth_type,16#8847},{eth_type,16#8848}];
prerequisite_for(mpls_tc) ->
    [{eth_type,16#8847},{eth_type,16#8848}];
prerequisite_for(mpls_bos) ->
    [{eth_type,16#8847},{eth_type,16#8848}];
prerequisite_for(pbb_isid) ->
    [{eth_type,16#88E7}];
prerequisite_for(ipv6_exthdr) ->
    [{eth_type,16#86dd}];
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
validate_instructions(TableId, Instructions, Match) ->
    case check_occurances(Instructions) of
        ok ->
            do_validate_instructions(TableId, Instructions, Match);
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
                
do_validate_instructions(TableId, [Instruction|Instructions], Match) ->
    case validate_instruction(TableId, Instruction, Match) of
        ok ->
            do_validate_instructions(TableId, Instructions, Match);
        Error ->
            Error
    end;
do_validate_instructions(_TableId, [], _Match) ->
    ok.

validate_instruction(TableId, #ofp_instruction_goto_table{table_id=NextTable}, _Match)
  when is_integer(TableId), TableId<NextTable, TableId<?OFPTT_MAX ->
    ok;
validate_instruction(_TableId, #ofp_instruction_goto_table{}, _Match) ->
    %% goto-table with invalid next-table-id
    {error,{bad_action,bad_table_id}};

validate_instruction(_TableId, #ofp_instruction_write_metadata{}, _Match) ->
    ok;
validate_instruction(_TableId, #ofp_instruction_write_actions{actions=Actions}, Match) ->
    validate_actions(Actions, Match);
validate_instruction(_TableId, #ofp_instruction_apply_actions{actions=Actions}, Match) ->
    validate_actions(Actions, Match);
validate_instruction(_TableId, #ofp_instruction_clear_actions{}, _Match) ->
    ok;
validate_instruction(_TableId, #ofp_instruction_experimenter{}, _Match) ->
    ok;
validate_instruction(_TableId, _Unknown, _Match) ->
    %% unknown instruction
    {error,{bad_instruction,unknown_inst,_Unknown}}.

%% unsupported instruction {error,{bad_instruction,unsup_inst}},

validate_actions([Action|Actions], Match) ->
    case validate_action(Action, Match) of
        ok ->
            validate_actions(Actions, Match);
        Error ->
            Error
    end;
validate_actions([], _Match) ->
    ok.

validate_action(#ofp_action_output{port=controller,max_len=MaxLen}, _Match) ->
    case MaxLen>?OFPCML_MAX of
        true ->
            {error,{bad_action,bad_argument}};
        false ->
            ok
    end;
validate_action(#ofp_action_output{port=Port}, _Match) ->
    case linc_us4_port:is_valid(Port) of
        true ->
            ok;
        false ->
            {error,{bad_action,bad_out_port}}
    end;
validate_action(#ofp_action_group{group_id=GroupId}, _Match) ->
    case linc_us4_groups:is_valid(GroupId) of
        true ->
            ok;
        false ->
            {error,{bad_action,bad_out_group}}
    end;
validate_action(#ofp_action_set_queue{}, _Match) ->
    ok;
validate_action(#ofp_action_set_mpls_ttl{}, _Match) ->
    ok;
validate_action(#ofp_action_dec_mpls_ttl{}, _Match) ->
    ok;
validate_action(#ofp_action_set_nw_ttl{}, _Match) ->
    ok;
validate_action(#ofp_action_dec_nw_ttl{}, _Match) ->
    ok;
validate_action(#ofp_action_copy_ttl_out{}, _Match) ->
    ok;
validate_action(#ofp_action_copy_ttl_in{}, _Match) ->
    ok;
validate_action(#ofp_action_push_vlan{ethertype=Ether}, _Match)
  when Ether == 16#8100; Ether==16#88A8 ->
    ok;
validate_action(#ofp_action_push_vlan{}, _Match) ->
    {error,{bad_action,bad_argument}};
validate_action(#ofp_action_pop_vlan{}, _Match) ->
    ok;
validate_action(#ofp_action_push_mpls{ethertype=Ether}, _Match)
  when Ether == 16#8100; Ether==16#88A8 ->
    ok;
validate_action(#ofp_action_push_mpls{}, _Match) ->
    {error,{bad_action,bad_argument}};
validate_action(#ofp_action_pop_mpls{}, _Match) ->
    ok;
validate_action(#ofp_action_set_field{field=Field}, Match) ->
    case check_prerequisites(Field,Match) of
        true ->
            ok;
        false ->
            {error,{bad_action,bad_argument}}
    end;
validate_action(#ofp_action_experimenter{}, _Match) ->
    {error,{bad_action,bad_experimenter}}.

%% Check that field value is in the allowed domain
%% TODO
validate_value(#ofp_field{name=_Name,value=_Value}) ->
    true.

%% Replace a flow with a new one, possibly keeping the counters
%% from the old one. This is used when adding a flow with exactly
%% the same match as an existing one.
replace_existing_flow(TableId,
                      #ofp_flow_mod{instructions=NewInstructions}=FlowMod,
                      #flow_entry{id=Id,instructions=PrevInstructions}=Existing,
                      Flags) ->
    case lists:member(reset_counts, Flags) of
        true ->
            %% Reset flow counters
            %% Store new flow and remove the previous one
            add_new_flow(TableId, FlowMod),
            delete_flow(TableId, Existing, no_event);
        false ->
            %% Do not reset the flow counters
            %% Just store the new flow with the previous FlowId
            increment_group_ref_count(NewInstructions),
            decrement_group_ref_count(PrevInstructions),
            NewEntry = create_flow_entry(FlowMod),
            ets:insert(flow_table_name(TableId), NewEntry#flow_entry{id=Id}),
            ok
    end.

%% Modify an existing flow. This only modifies the instructions, leaving all other
%% fields unchanged.
modify_flow(TableId, #flow_entry{id=Id,instructions=PrevInstructions},
            NewInstructions, Flags) ->
    ets:update_element(flow_table_name(TableId),
                       Id, 
                       {#flow_entry.instructions, NewInstructions}),
    increment_group_ref_count(NewInstructions),
    decrement_group_ref_count(PrevInstructions),
    case lists:member(reset_counts, Flags) of
        true ->
            true = ets:insert(flow_entry_counters,
                              #flow_entry_counter{id = Id}),
            ok;
        false ->
            %% Do nothing
            ok
    end.


%%============================================================================
%% Various counter functions
create_flow_entry_counter(FlowId) ->
    true = ets:insert(flow_entry_counters,
                      #flow_entry_counter{id = FlowId}).

get_flow_stats(TableId, Cookie, CookieMask, Match, OutPort, OutGroup) ->
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
                              Counters = ets:lookup(flow_entry_counters,FlowId),
                              [#flow_entry_counter{
                                  received_packets = Packets,
                                  received_bytes   = Bytes}] = Counters,

                              #flow_timer{idle_timeout = IdleTimeout,
                                          hard_timeout = HardTimeout} = get_flow_timer(FlowId),
                                  
                              Stats = #ofp_flow_stats{
                                         table_id = TableId,
                                         duration_sec = DurationMs div 1000000,
                                         duration_nsec = DurationMs * 1000,
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
              end, [], flow_table_name(TableId)).

get_aggregate_stats(TableId,Cookie, CookieMask, Match, OutPort, OutGroup) ->
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
                              Counters = ets:lookup(flow_entry_counters,FlowId),
                              [#flow_entry_counter{
                                  received_packets = Packets,
                                  received_bytes   = Bytes}] = Counters,
                              {PacketsAcc+Packets,BytesAcc+Bytes,FlowsAcc+1};
                          false ->
                              Acc
                      end
              end, {0,0,0}, flow_table_name(TableId)).

merge_aggregate_stats(Stats) ->
    lists:foldl(fun ({Packets,Bytes,Flows}, {PacketsAcc,BytesAcc,FlowsAcc}) ->
                        {PacketsAcc+Packets, BytesAcc+Bytes, FlowsAcc+Flows}
                end,{0,0,0},Stats).

get_table_stats() ->
    [get_table_stats1(TableId) || TableId <- lists:seq(0, ?OFPTT_MAX)].

get_table_stats1(TableId) ->
    [#flow_table_counter{packet_lookups = Lookups,
                         packet_matches = Matches}]
        = ets:lookup(flow_table_counters, TableId),
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
       config = get_table_config(TableId),
       max_entries = ?MAX_FLOW_TABLE_ENTRIES,
       active_count = ets:info(flow_table_name(TableId),size),
       lookup_count = Lookups,
       matched_count = Matches}.

%%============================================================================
%% Various timer functions

create_flow_timer(TableId, FlowId, IdleTime, HardTime) ->
    Now = os:timestamp(),
    true = ets:insert(flow_timers,
                      #flow_timer{id = FlowId,
                                  table = TableId,
                                  idle_timeout = IdleTime,
                                  expire = calc_timeout(Now, IdleTime),
                                  hard_timeout = HardTime,
                                  remove = calc_timeout(Now, HardTime)
                                 }).

get_flow_timer(FlowId) ->
    case ets:lookup(flow_timers,FlowId) of
        [Rec] ->
            Rec;
        [] ->
            undefined
    end.

delete_flow_timer(FlowId) ->
    ets:delete(flow_timers,FlowId).

calc_timeout(_Now, 0) ->
    infinity;
calc_timeout({Mega,Secs,Micro},Time) ->
    case Secs+Time of
        S when S>999999 ->
            {Mega+1,S-999999,Micro};
        S ->
            {Mega,S,Micro}
    end.

check_timers() ->
    Now = os:timestamp(),
    ets:foldl(fun (Flow, ok) ->
                      case hard_timeout(Now, Flow) of
                          false ->
                              idle_timeout(Now, Flow),
                              ok;
                          true ->
                              ok
                      end
              end, ok, flow_timers).

hard_timeout(_Now, #flow_timer{remove = infinity}) ->
    false;
hard_timeout(Now, #flow_timer{id = FlowId, table = TableId, remove = Remove})
  when Remove<Now ->
    delete_flow(TableId, get_flow(TableId, FlowId), hard_timeout),
    true;
hard_timeout(_Now, _Flow) ->
    false.

idle_timeout(_Now, #flow_timer{expire = infinity}) ->
    false;
idle_timeout(Now, #flow_timer{id = FlowId, table = TableId, expire = Expire})
  when Expire<Now ->
    delete_flow(TableId, get_flow(TableId, FlowId), idle_timeout),
    true;
idle_timeout(_Now, _Flow) ->
    false.

%%============================================================================
%% Various lookup functions

get_flow(TableId, FlowId) ->
    [Flow] = ets:lookup(flow_table_name(TableId), FlowId),
    Flow.

%% Get the match pattern from all flows with Priority.
get_matches_by_priority(TableId, Priority) ->
    Pattern = #flow_entry{id = {Priority,'_'},
                          priority = Priority,
                          match = #ofp_match{fields='$1'},
                          _ = '_'
                         },
    [M || [M] <- ets:match(flow_table_name(TableId), Pattern)].

%% Find an existing flow with the same Priority and the exact same match expression.
-spec find_exact_match(ofp_table_id(),non_neg_integer(),ofp_match()) -> flow_id()|no_match.
find_exact_match(TableId, Priority, Match) ->
    Pattern = ets:fun2ms(fun (#flow_entry{id={Prio,_},
                                          match=#ofp_match{fields=Fields}}=Flow)
                               when Prio==Priority, Fields==Match ->
                                 Flow
                         end),
    case ets:select(flow_table_name(TableId), Pattern) of
        [Flow|_] =_Match->
            Flow;
        [] ->
            no_match
    end.

%% Modify flows that are matching 
modify_matching_flows(TableId, Cookie, CookieMask, Match, Instructions, Flags) ->
    ets:foldl(fun (#flow_entry{cookie=MyCookie}=FlowEntry, Acc) ->
                      case cookie_match(MyCookie, Cookie, CookieMask)
                          andalso non_strict_match(FlowEntry, Match) of
                          true ->
                              modify_flow(TableId, FlowEntry, Instructions, Flags);
                          false ->
                              Acc
                      end
              end, [], flow_table_name(TableId)).

%% Delete flows that are matching 
delete_matching_flows(TableId, Cookie, CookieMask, Match, OutPort, OutGroup) ->
    ets:foldl(fun (#flow_entry{cookie=MyCookie,
                               instructions=Instructions}=FlowEntry, Acc) ->
                      case cookie_match(MyCookie, Cookie, CookieMask)
                          andalso non_strict_match(FlowEntry, Match)
                          andalso port_and_group_match(OutPort,
                                                       OutGroup,
                                                       Instructions)
                      of
                          true ->
                              delete_flow(TableId, FlowEntry, delete);
                          false ->
                              Acc
                      end
              end, [], flow_table_name(TableId)).

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
delete_where_group(GroupId, TableId) ->
    ets:foldl(fun (#flow_entry{instructions=Instructions}=FlowEntry, Acc) ->
                      case port_and_group_match(any, GroupId, Instructions) of
                          true ->
                              delete_flow(TableId, FlowEntry, group_delete);
                          false ->
                              Acc
                      end
              end, ok, flow_table_name(TableId)).


increment_group_ref_count(Instructions) ->
    update_group_ref_count(Instructions, 1).

decrement_group_ref_count(Instructions) ->
    update_group_ref_count(Instructions, -1).

update_group_ref_count(Instructions, Incr) ->
    [linc_us4_groups:update_reference_count(Group,Incr) || Group<-get_groups(Instructions)].

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
