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

-export([initialize/0,
         terminate/0,
         table_mod/1,
         modify/1,
         get_flow_table/1,
         delete_where_group/1,
         get_stats/1,
         get_aggregate_stats/1,
         get_table_stats/1,
         update_lookup_counter/1,
         update_match_counters/2,
         reset_idle_timeout/2
        ]).

-include("linc_us3.hrl").
-include_lib("stdlib/include/ms_transform.hrl").

%% @doc Initialize the flow tables module. Only to be called on system startup.
-spec initialize() -> ok.
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

    ets:new(flow_entry_counters,
            [named_table, public,
             {keypos, #flow_entry_counter.id},
             {write_concurrency, true}]),
    ok.

%% @doc Terminate the flow table module. Only to be called on system shutdown.
-spec terminate() -> ok.
terminate() ->
    [ets:delete(flow_table_name(Id)) || Id <- lists:seq(0, ?OFPTT_MAX)],
    ets:delete(flow_table_config),
    ets:delete(flow_table_counters),
    ets:delete(flow_entry_counters).

%% @doc Handle ofp_table_mod request
table_mod(#ofp_table_mod{table_id = TableId, config = Config}) ->
    %% TODO
    ok.

%% @doc Handle a flow_mod request from a controller. This may add/modify/delete one or
%% more flows.
-spec modify(#ofp_flow_mod{}) -> ok | {error, {Type :: atom(), Code :: atom()}}.
modify(#ofp_flow_mod{command=Cmd, table_id=all})
  when Cmd==add;Cmd==modify;Cmd==modify_strict ->
    {error, {flow_mod_failed, bad_table_id}};
modify(#ofp_flow_mod{command=add,
                     table_id=TableId,
                     priority=Priority,
                     flags=Flags,
                     match=#ofp_match{fields=Match},
                     instructions=Instructions}=FlowMod) ->
    case validate_match(Match) of
        ok ->
            case validate_instructions(TableId,Instructions,Match) of
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
                                    modify_existing_flow(TableId, FlowMod,
                                                         Matching, Flags);
                                no_match ->
                                    add_new_flow(TableId, FlowMod)
                            end
                    end;
                Error ->
                    Error
            end;
        Error ->
            Error
    end;
    
modify(#ofp_flow_mod{command=modify}) ->
    ok;
modify(#ofp_flow_mod{command=modify_strict}) ->
    ok;
modify(#ofp_flow_mod{command=delete}) ->
    ok;
modify(#ofp_flow_mod{command=delete_strict}) ->
    ok.

%% @doc Get all entries in one flow table.
-spec get_flow_table(TableId :: integer()) -> [FlowTableEntryRepresentation :: term()].
get_flow_table(TableId) ->
    ets:tab2list(flow_table_name(TableId)).

%% @doc Delete all flow entries that are using a specific group.
-spec delete_where_group(GroupId :: integer()) -> ok.
delete_where_group(GroupId) ->
    ok.

%% @doc Get flow statistics.
-spec get_stats(#ofp_flow_stats_request{}) -> #ofp_flow_stats_reply{}.
get_stats(#ofp_flow_stats_request{}) ->
    #ofp_flow_stats_reply{}.

%% @doc Get aggregate statistics.
-spec get_aggregate_stats(#ofp_aggregate_stats_request{}) -> #ofp_aggregate_stats_reply{}.
get_aggregate_stats(#ofp_aggregate_stats_request{}) ->
    #ofp_aggregate_stats_reply{}.

%% @doc Get table statistics.
-spec get_table_stats(#ofp_table_stats_request{}) -> #ofp_table_stats_reply{}.
get_table_stats(#ofp_table_stats_request{}) ->
    #ofp_table_stats_reply{}.

%% @doc Update the table lookup statistics counters for a table.
-spec update_lookup_counter(TableId :: integer()) -> ok.
update_lookup_counter(TableId) ->
    ok.

%% @doc Update the match lookup statistics counters for a specific flow.
-spec update_match_counters(FlowId :: integer(), PktByteSize :: integer()) -> ok.
update_match_counters(FlowId, PktByteSize) ->
    try
        ets:update_counter(flow_entry_counters,
                           FlowId,[{#flow_entry_counter.received_packets, 1},
                                   {#flow_entry_counter.received_bytes, PktByteSize}]),
        ok
    catch
        _:_ ->
            ok
    end.

%% @doc Reset the idle timeout timer for a specific flow.
-spec reset_idle_timeout(TableId :: integer(), FlowId :: integer()) -> ok.
reset_idle_timeout(TableId, FlowId) ->
    ok.

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
    %% io:format("check overlap ~p ~n~p~n",[NewMatch,ExistingMatches]),
    SortedNewMatch = lists:sort(NewMatch),
    lists:any(fun (ExistingMatch) ->
                      overlaps(SortedNewMatch, lists:sort(ExistingMatch))
              end, ExistingMatches).

overlaps([#ofp_field{class=C,name=F,has_mask=false,value=V}|Ms1],
         [#ofp_field{class=C,name=F,has_mask=false,value=V}|Ms2]) ->
    %% io:format("overlaps5~n"),
    overlaps(Ms1,Ms2);
overlaps([#ofp_field{class=C,name=F,has_mask=false,value=V1}|_Fields1],
         [#ofp_field{class=C,name=F,has_mask=false,value=V2}|_Fields2])
  when V1=/=V2 ->
    %% io:format("overlaps1 ~p ~p~n",[V1,V2]),
    false;
overlaps([#ofp_field{class=C,name=F,has_mask=true,value=V1,mask=MaskBin}|_Fields1],
         [#ofp_field{class=C,name=F,has_mask=false,value=V2}|_Fields2]) ->
    Bits = bit_size(MaskBin),
    <<Val1:Bits>> = V1,
    <<Val2:Bits>> = V2,
    <<Mask:Bits>> = MaskBin,
    %% io:format("overlaps2 ~p ~p~n",[V1,V2]),
    Val1 band Mask == Val2 band Mask;
overlaps([#ofp_field{class=C,name=F,has_mask=true,value=V1}|_Fields1],
         [#ofp_field{class=C,name=F,has_mask=false,value=V2,mask=MaskBin}|_Fields2]) ->
    Bits = bit_size(MaskBin),
    <<Val1:Bits>> = V1,
    <<Val2:Bits>> = V2,
    <<Mask:Bits>> = MaskBin,
    %% io:format("overlaps3 ~p ~p~n",[V1,V2]),
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
    io:format("overlaps4 vals ~p ~p~nmasks ~p ~p~ncommonbits ~p~n",[V1,V2,Mask1,Mask2,CommonBits]),
    case (Val1 band CommonBits)==(Val2 band CommonBits) of
        false ->
            false;
        true ->
            overlaps(Ms1,Ms2)
    end;
overlaps([#ofp_field{class=C,name=F1}|Ms1],
         [#ofp_field{class=C,name=F2}|_]=Ms2) when F1<F2 ->
    %% Both lists of match fields have been sorted, so this actually works.
    %% io:format("overlaps6~n"),
    overlaps(Ms1,Ms2);
overlaps([#ofp_field{class=C,name=F1}|_]=Ms1,
         [#ofp_field{class=C,name=F2}|Ms2]) when F1>F2 ->
    %% Both lists of match fields have been sorted, so this actually works.
    %% io:format("overlaps7 ~p ~p~n",[F1,F2]),
    overlaps(Ms1,Ms2);
overlaps(_V1,_V2) ->
    %% io:format("overlaps8 ~p ~p~n",[_V1,_V2]),
    true.

%% Add a new flow entry.
add_new_flow(TableId, FlowMod) ->
    NewEntry = create_flow_entry(FlowMod),
    %% Create counter before inserting flow in flow table to avoid race.
    create_flow_entry_counter(NewEntry#flow_entry.id),
    ets:insert(flow_table_name(TableId), NewEntry),
    ok.

%% Delete a flow
delete_flow(TableId, FlowId) ->
    ets:delete(flow_table_name(TableId), FlowId),
    ets:delete(flow_entry_counters, FlowId),
    ok.

-spec create_flow_entry(ofp_flow_mod()) -> #flow_entry{}.
create_flow_entry(#ofp_flow_mod{priority = Priority,
                                cookie = Cookie,
                                match = Match,
                                instructions = Instructions}) ->
    #flow_entry{id = {Priority, make_ref()},
                priority = Priority,
                cookie = Cookie,
                match = Match,
                install_time = erlang:now(),
                %% TODO: Add timers
                
                %% All record of type ofp_instruction() MUST have
                %% seq number as a first element.
                instructions = lists:keysort(2, Instructions)}.

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
check_prerequisites(#ofp_field{name=Name,value=Value}=Field,Previous) ->
    case prerequisite_for(Name) of
        [] ->
            true;
        PreReqs ->
            io:format("prereqs ~p ~p~n",[Field,Previous]),
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
validate_instructions(TableId, [Instruction|Instructions], Match) ->
    case validate_instruction(TableId, Instruction, Match) of
        ok ->
            validate_instructions(TableId, Instructions, Match);
        Error ->
            Error
    end;
validate_instructions(_TableId, [], _Match) ->
    ok.

validate_instruction(TableId, #ofp_instruction_goto_table{table_id=NextTable}, _Match)
  when is_integer(TableId), TableId<NextTable->
    ok;
validate_instruction(_TableId, #ofp_instruction_goto_table{}, _Match) ->
    %% goto-table with invalid next-table-id
    {error,{bad_action,bad_table_id}};

validate_instruction(_TableId, #ofp_instruction_write_metadata{}, _Match) ->
    ok;
validate_instruction(TableId, #ofp_instruction_write_actions{actions=Actions}, Match) ->
    validate_actions(Actions, Match);
validate_instruction(TableId, #ofp_instruction_apply_actions{actions=Actions}, Match) ->
    validate_actions(Actions, Match);
validate_instruction(TableId, #ofp_instruction_clear_actions{}, Match) ->
    ok;
validate_instruction(TableId, #ofp_instruction_experimenter{}, Match) ->
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

validate_action(#ofp_action_output{port=Port}, _Match) ->
    case linc_us3_port:is_valid(Port) of
        true ->
            ok;
        false ->
            {error,{bad_action,bad_out_port}}
    end;
validate_action(#ofp_action_group{group_id=GroupId}, _Match) ->
    case linc_us3_groups:is_valid(GroupId) of
        true ->
            ok;
        false ->
            {error,{bad_action,bad_out_group}}
    end;
validate_action(#ofp_action_set_queue{queue_id=QueueId}, _Match) ->
    ok;
validate_action(#ofp_action_set_mpls_ttl{mpls_ttl=TTL}, _Match) ->
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
validate_action(#ofp_action_push_vlan{}, _Match) ->
    ok;
validate_action(#ofp_action_pop_vlan{}, _Match) ->
    ok;
validate_action(#ofp_action_push_mpls{}, _Match) ->
    ok;
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
    ok.

%% Check that field value is in the allowed domain
%% TODO
validate_value(#ofp_field{name=Name,value=Value}) ->
    true.


modify_existing_flow(TableId, FlowMod, #flow_entry{id=Existing}, Flags) ->
    case lists:member(reset_counts, Flags) of
        true ->
            %% Reset flow counters
            %% Store new flow and remove the previous one
            add_new_flow(TableId, FlowMod),
            delete_flow(TableId, Existing);
        false ->
            %% Do not reset the flow counters
            %% Just store the new flow with the previous FlowId
            NewEntry = create_flow_entry(FlowMod),
            ets:insert(flow_table_name(TableId), NewEntry#flow_entry{id=Existing}),
            ok
    end.

%%============================================================================
%% Various counter functions
create_flow_entry_counter(FlowId) ->
    true = ets:insert(flow_entry_counters,
                      #flow_entry_counter{id = FlowId}).


%%============================================================================
%% Various lookup functions

%% Get the match pattern from all flows with Priority.
get_matches_by_priority(TableId, Priority) ->
    Pattern = #flow_entry{id = {Priority,'_'},
                          priority = Priority,
                          match = #ofp_match{fields='$1'},
                          cookie = '_',
                          install_time = '_',
                          expires = '_',
                          idle = '_',
                          instructions = '_'},
    [M || [M] <- ets:match(flow_table_name(TableId), Pattern)].

%% Find an existing flow with the same Priority and the exact same match expression.
-spec find_exact_match(ofp_table_id(),non_neg_integer(),ofp_match()) -> flow_id()|no_match.
find_exact_match(TableId, Priority, Match) ->
    Pattern = ets:fun2ms(fun (#flow_entry{id={Prio,_},
                                          priority=Prio,
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

