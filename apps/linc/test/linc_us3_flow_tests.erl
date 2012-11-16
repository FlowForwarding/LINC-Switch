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
-module(linc_us3_flow_tests).

-include_lib("eunit/include/eunit.hrl").
%% -include_lib("of_protocol/include/of_protocol.hrl").
%% -include_lib("of_protocol/include/ofp_v3.hrl").
-include("linc_us3.hrl").

%% Tests -----------------------------------------------------------------------

flow_mod_test_() ->
    {foreach,
     fun setup/0,
     fun teardown/1,
     [ {"Duplicate fields", fun duplicate_field/0}
      ,{"Prerequisite field present", fun prerequisite_field_present/0}
      ,{"Prerequisite field present bad val", fun prerequisite_field_present_bad_val/0}
      ,{"Prerequisite field missing", fun prerequisite_field_missing/0}
      ,{"Goto table with smaller table_id", fun goto_backwards/0}
      ,{"Set field incompatible with match", fun incompatible_set_field/0}
      ,{"Add 1 flow, no check_overlap", fun () -> add_flow(0, []) end}
      ,{"Add 1 flow, check_overlap", fun () -> add_flow(1, [check_overlap]) end}
      ,{"Add 2 non overlapping flows, no check_overlap", fun () -> add_non_overlapping_flows([]) end}
      ,{"Add 2 non overlapping flows, check_overlap", fun () -> add_non_overlapping_flows([check_overlap]) end}
      ,{"Add 2 overlapping flows, no check_overlap", fun add_overlapping_flows/0}
      ,{"Add 2 with overlapping flow, check_overlap", fun add_overlapping_flow_check_overlap/0}
      ,{"Add 2 with exact match, no reset_counters", fun () -> add_exact_flow([reset_counts]) end}
      ,{"Add 2 with exact match, reset_counters", fun () -> add_exact_flow([]) end}
     ]}.

duplicate_field() ->
    %% Create flow_mod record
    FlowModAdd = ofp_v3_utils:flow_add(
                   [{table_id,0},
                    {priority,5},
                    {flags,[]}],
                   [{in_port,6},{in_port,6}],
                   [{write_actions,[{output,15,1400}]}]),
    %% Add flow
    ?assertEqual({error,{bad_match,dup_field}}, linc_us3_flow:modify(FlowModAdd)).
 
prerequisite_field_present() ->
    FlowModAdd = #ofp_flow_mod{
                    cookie = <<0,0,0,0,0,0,0,0>>,
                    cookie_mask = <<0,0,0,0,0,0,0,0>>,
                    table_id = 0,command = add,idle_timeout = 0,
                    hard_timeout = 0,priority = 5,buffer_id = no_buffer,
                    out_port = any,out_group = any,flags = [],
                    match = 
                        #ofp_match{
                           fields = 
                               [#ofp_field{
                                   name = eth_type,
                                   value = <<8,0>>},
                                #ofp_field{
                                   name = ip_proto,
                                   value = <<8>>}]},
                    instructions = 
                        [#ofp_instruction_write_actions{
                            seq = 3,
                            actions = 
                                [#ofp_action_output{port = 15,
                                                    max_len = 1400}]}]},
    %% Add flow
    ?assertEqual(ok, linc_us3_flow:modify(FlowModAdd)).

prerequisite_field_present_bad_val() ->
    FlowModAdd = #ofp_flow_mod{
                    cookie = <<0,0,0,0,0,0,0,0>>,
                    cookie_mask = <<0,0,0,0,0,0,0,0>>,
                    table_id = 0,command = add,idle_timeout = 0,
                    hard_timeout = 0,priority = 5,buffer_id = no_buffer,
                    out_port = any,out_group = any,flags = [],
                    match = 
                        #ofp_match{
                           fields = 
                               [#ofp_field{
                                   name = eth_type,
                                   value = <<8,8>>},
                                #ofp_field{
                                   name = ip_proto,
                                   value = <<8>>}]},
                    instructions = 
                        [#ofp_instruction_write_actions{
                            seq = 3,
                            actions = 
                                [#ofp_action_output{port = 15,
                                                    max_len = 1400}]}]},
    ?assertEqual({error,{bad_match,bad_prereq}}, linc_us3_flow:modify(FlowModAdd)).

prerequisite_field_missing() ->
    FlowModAdd = #ofp_flow_mod{
                    cookie = <<0,0,0,0,0,0,0,0>>,
                    cookie_mask = <<0,0,0,0,0,0,0,0>>,
                    table_id = 0,command = add,idle_timeout = 0,
                    hard_timeout = 0,priority = 5,buffer_id = no_buffer,
                    out_port = any,out_group = any,flags = [],
                    match = 
                        #ofp_match{
                           fields = 
                               [#ofp_field{
                                   name = ip_proto,
                                   value = <<8>>}]},
                    instructions = 
                        [#ofp_instruction_write_actions{
                            actions = 
                                [#ofp_action_output{port = 15,
                                                    max_len = 1400}]}]},
    ?assertEqual({error,{bad_match,bad_prereq}}, linc_us3_flow:modify(FlowModAdd)).

%% Goto a table with smaller table_id
goto_backwards() ->
    FlowModAdd = ofp_v3_utils:flow_add(
                   [{table_id,5},
                    {priority,5},
                    {flags,[]}],
                   [{in_port,6}],
                   [{goto_table,2}]),
    ?assertEqual({error,{bad_action,bad_table_id}}, linc_us3_flow:modify(FlowModAdd)).

%% Match un UDP, but action tries to change a TCP field
incompatible_set_field() ->
    FlowModAdd = ofp_v3_utils:flow_add(
                   [{table_id,5},
                    {priority,5},
                    {flags,[]}],
                   [{in_port,6},{eth_type,<<8,0>>},{udp_src,<<8,0>>}],
                   [{write_actions,[{set_field,tcp_dst,<<8,0>>}]}]),
    ?assertEqual({error,{bad_action,bad_argument}}, linc_us3_flow:modify(FlowModAdd)).

%% Add one flow, in an empty table, this should always succeed.
add_flow(TableId, Flags) ->
    Priority=5,
    %% Create flow_mod record
    FlowModAdd = ofp_v3_utils:flow_add(
                   [{table_id,TableId},
                    {priority,Priority},
                    {flags,Flags}],
                   [{in_port,6}, {eth_dst,<<0,0,0,0,0,8>>,<<0,0,0,0,0,15>>}],
                   [{write_actions,[{output,15,1400}]}]),
    ?assertEqual(ok, linc_us3_flow:modify(FlowModAdd)),
 
   %% Check if the flow was added correctly...
    #ofp_flow_mod{match=Match,
                  instructions=Instructions} = FlowModAdd,

    [#flow_entry{id=Id,
                 match=Match1,
                 instructions=Instructions1}] = linc_us3_flow:get_flow_table(TableId),

    ?assertEqual(Match, Match1),
    ?assertEqual(Instructions, Instructions1),

    %% Check that counters entry has been created
    ?assertMatch([#flow_entry_counter{}], ets:lookup(flow_entry_counters,Id)).

%% Add two non overlapping flows, this should always succeed, independent of
%% if the check_overlap flag is set
add_non_overlapping_flows(Flags) ->
    TableId = 2,
    Priority=5,
    %% Create flow_mod record
    FlowModAdd1 = ofp_v3_utils:flow_add(
                   [{table_id,TableId},
                    {priority,Priority},
                    {flags,Flags}],
                   [{in_port,6}, {eth_dst,<<0,0,0,0,0,8>>}],
                   [{write_actions,[{output,15,1400}]}]),

    FlowModAdd2 = ofp_v3_utils:flow_add(
                   [{table_id,TableId},
                    {priority,Priority},
                    {flags,Flags}],
                   [{in_port,6}, {eth_dst,<<0,0,0,0,0,9>>}],
                   [{write_actions,[{output,15,1400}]}]),
    %% Add flows
    ?assertEqual(ok, linc_us3_flow:modify(FlowModAdd1)),
    ?assertEqual(ok, linc_us3_flow:modify(FlowModAdd2)),
 
    %% Check if the flows were added correctly...
    #ofp_flow_mod{match=Match1,
                  instructions=Instructions1} = FlowModAdd1,
    #ofp_flow_mod{match=Match2,
                  instructions=Instructions2} = FlowModAdd2,

    ?assertMatch([#flow_entry{match=Match1,
                              instructions=Instructions1},
                  #flow_entry{match=Match2,
                              instructions=Instructions2}],
                 linc_us3_flow:get_flow_table(TableId)).

%% Add two overlapping, but not exact, flows, without the check_overlap flag set,
%% this should succeed.
add_overlapping_flows() ->
    TableId = 2,
    Priority=5,
    Flags = [],
    %% Create flow_mod record
    FlowModAdd1 = ofp_v3_utils:flow_add(
                   [{table_id,TableId},
                    {priority,Priority},
                    {flags,Flags}],
                   [{in_port,6}, {eth_dst,<<0,0,0,0,0,7>>,<<0,0,0,0,0,15>>}],
                   [{write_actions,[{output,15,1400}]}]),

    FlowModAdd2 = ofp_v3_utils:flow_add(
                   [{table_id,TableId},
                    {priority,Priority},
                    {flags,Flags}],
                   [{in_port,6}, {eth_dst,<<0,0,0,0,0,9>>,<<0,0,0,0,0,31>>}],
                   [{write_actions,[{output,15,1400}]}]),
    %% Add flows
    ?assertEqual(ok, linc_us3_flow:modify(FlowModAdd1)),
    ?assertEqual(ok, linc_us3_flow:modify(FlowModAdd2)),
 
    %% Check if the flows were added correctly...
    #ofp_flow_mod{match=Match1,
                  instructions=Instructions1} = FlowModAdd1,
    #ofp_flow_mod{match=Match2,
                  instructions=Instructions2} = FlowModAdd2,

    ?assertMatch([#flow_entry{match=Match1,
                              instructions=Instructions1},
                  #flow_entry{match=Match2,
                              instructions=Instructions2}],
                 linc_us3_flow:get_flow_table(TableId)).

%% Add two overlapping, but not exact, flows, with the check_overlap flag set,
%% this should fail.
add_overlapping_flow_check_overlap() ->
    TableId = 2,
    Priority=5,
    Flags = [check_overlap],
    %% Create flow_mod record
    FlowModAdd1 = ofp_v3_utils:flow_add(
                   [{table_id,TableId},
                    {priority,Priority},
                    {flags,Flags}],
                   [{in_port,6}, {eth_dst,<<0,0,0,0,0,16#7>>,<<0,0,0,0,0,16#0F>>}],
                   [{write_actions,[{output,15,1400}]}]),

    FlowModAdd2 = ofp_v3_utils:flow_add(
                   [{table_id,TableId},
                    {priority,Priority},
                    {flags,Flags}],
                   [{in_port,6}, {eth_dst,<<0,0,0,0,0,16#17>>,<<0,0,0,0,0,16#1F>>}],
                   [{write_actions,[{output,15,1400}]}]),
    %% Add flows
    ?assertEqual(ok, linc_us3_flow:modify(FlowModAdd1)),
    ?assertEqual({error,{flow_mod_failed,overlap}},
                 linc_us3_flow:modify(FlowModAdd2)),
 
    %% Check that the the overlapping flow was not added
    #ofp_flow_mod{match=Match1,
                  instructions=Instructions1} = FlowModAdd1,

    ?assertMatch([#flow_entry{match=Match1,
                              instructions=Instructions1}],
                 linc_us3_flow:get_flow_table(TableId)).

add_exact_flow(Flags) ->    
    TableId = 4,
    Priority = 6,
    Match = [{in_port,6}, {eth_dst,<<0,0,0,0,0,16#7>>}],

    Instructions1 = [{write_actions,[{output,15,1400}]}],
    %% Create flow_mod record
    FlowModAdd1 = ofp_v3_utils:flow_add(
                    [{table_id,TableId},
                     {priority,Priority},
                     {flags,Flags}],
                    Match,
                    Instructions1
                   ),

    Instructions2 = [{write_actions,[{output,32,1400}]}],
    FlowModAdd2 = ofp_v3_utils:flow_add(
                    [{table_id,TableId},
                     {priority,Priority},
                     {flags,Flags}],
                    Match,
                    Instructions2),

    %% Add first flow
    ?assertEqual(ok, linc_us3_flow:modify(FlowModAdd1)),
    %% Get FlowId
    [#flow_entry{id=FlowId1}] = linc_us3_flow:get_flow_table(TableId),

    %% Increments flow counters
    PacketSize = 1024,
    linc_us3_flow:update_match_counters(FlowId1,PacketSize),

    %% Check that counters are updated
    [#flow_entry_counter{
        id=FlowId1,
        received_packets=1,
        received_bytes=PacketSize}] = ets:lookup(flow_entry_counters,FlowId1),

    %% Add second flow
    ?assertEqual(ok, linc_us3_flow:modify(FlowModAdd2)),
 
    %% Check that the the new flow has replaced the previous one
    #ofp_flow_mod{match=M1,
                  instructions=I1} = FlowModAdd2,

    [#flow_entry{id = FlowId2,
                 match = M2,
                 instructions = I2}] = linc_us3_flow:get_flow_table(TableId),

    ?assertEqual(M1,M2),
    ?assertEqual(I1,I2),

    %% Check that counters entry is correct
    case Flags of
        [reset_counts] ->
            [Stats] = ets:lookup(flow_entry_counters,FlowId2),
            ?assertMatch(#flow_entry_counter{received_packets=0,
                                             received_bytes=0},
                         Stats);
        [] ->
            [Stats] = ets:lookup(flow_entry_counters,FlowId1),
            ?assertMatch(#flow_entry_counter{received_packets=1,
                                             received_bytes=PacketSize},
                         Stats)
    end.
    
%% modify_flow() ->
%%     ?_assert(true).

%% Fixtures --------------------------------------------------------------------
setup() ->
    ok=linc_us3_flow:initialize().

teardown(ok) ->
    linc_us3_flow:terminate().

%% Helpers ---------------------------------------------------------------------
