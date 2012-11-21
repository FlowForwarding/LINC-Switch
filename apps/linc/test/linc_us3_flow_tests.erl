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

-define(MOCKED, [group,port]).

%% Tests -----------------------------------------------------------------------

flow_mod_test_() ->
    {foreach,
     fun setup/0,
     fun teardown/1,
     [{"Bad table_id", fun bad_table_id/0}
      ,{"Duplicate fields", fun duplicate_field/0}
      ,{"Prerequisite field present", fun prerequisite_field_present/0}
      ,{"Prerequisite field present bad val", fun prerequisite_field_present_bad_val/0}
      ,{"Prerequisite field missing", fun prerequisite_field_missing/0}
      ,{"Goto table with smaller table_id", fun goto_backwards/0}
      ,{"Valid out port", fun valid_out_port/0}
      ,{"Invalid out port", fun invalid_out_port/0}
      ,{"Valid out group", fun valid_out_group/0}
      ,{"Invalid out group", fun invalid_out_group/0}
      ,{"Set field incompatible with match", fun incompatible_set_field/0}
      ,{"Add 1 flow, no check_overlap", fun () -> add_flow(0, []) end}
      ,{"Add 1 flow, check_overlap", fun () -> add_flow(1, [check_overlap]) end}
      ,{"Add 2 non overlapping flows, no check_overlap", fun () -> add_non_overlapping_flows([]) end}
      ,{"Add 2 non overlapping flows, check_overlap", fun () -> add_non_overlapping_flows([check_overlap]) end}
      ,{"Add 2 overlapping flows, no check_overlap", fun add_overlapping_flows/0}
      ,{"Add 2 with overlapping flow, check_overlap", fun add_overlapping_flow_check_overlap/0}
      ,{"Add 2 with exact match, reset_counters", fun () -> add_exact_flow([reset_counts]) end}
      ,{"Add 2 with exact match, no reset_counters", fun () -> add_exact_flow([]) end}
      ,{"Modify flow, strict, no reset_counts", fun () -> modify_strict([]) end}
      ,{"Modify flow, strict, reset_counts", fun () -> modify_strict([reset_counts]) end}
      ,{"Modify flow, non-strict, cookie no match", fun modify_cookie_no_match/0}
      ,{"Modify flow, non-strict, cookie match", fun modify_cookie_match/0}
      ,{"Delete flow, strict", fun delete_strict/0}
      ,{"Delete flow, non-strict, cookie no match", fun delete_cookie_no_match/0}
      ,{"Delete flow, non-strict, cookie match", fun delete_cookie_match/0}
      ,{"Delete flow, outport no match", fun delete_outport_no_match/0}
      ,{"Delete flow, outport match", fun delete_outport_match/0}
      ,{"Delete flow, outgroup no match", fun delete_outgroup_no_match/0}
      ,{"Delete flow, outgroup match", fun delete_outgroup_match/0}
      ,{"Delete flow, all tables", fun delete_all_tables/0}
     ]}.

bad_table_id() ->
    %% Create flow_mod record
    FlowModAdd = ofp_v3_utils:flow_add(
                   [{table_id,all},
                    {priority,5},
                    {flags,[]}],
                   [{in_port,6},{in_port,6}],
                   [{write_actions,[{output,15,1400}]}]),
    %% Add flow
    ?assertEqual({error,{flow_mod_failed,bad_table_id}},
                 linc_us3_flow:modify(FlowModAdd)).

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

valid_out_port() ->
    %% Create flow_mod record
    FlowModAdd = ofp_v3_utils:flow_add(
                   [{table_id,0},
                    {priority,5},
                    {flags,[]}],
                   [{in_port,6}],
                   [{write_actions,[{output,15,1400}]}]),
    ?assertEqual(ok, linc_us3_flow:modify(FlowModAdd)).

invalid_out_port() ->
    %% Create flow_mod record
    FlowModAdd = ofp_v3_utils:flow_add(
                   [{table_id,0},
                    {priority,5},
                    {flags,[]}],
                   [{in_port,6}],
                   [{write_actions,[{output,33,1400}]}]),
    ?assertEqual({error,{bad_action,bad_out_port}},
                 linc_us3_flow:modify(FlowModAdd)).

valid_out_group() ->
    %% Create flow_mod record
    FlowModAdd = ofp_v3_utils:flow_add(
                   [{table_id,0},
                    {priority,5},
                    {flags,[]}],
                   [{in_port,6}],
                   [{write_actions,[{group,1}]}]),
    ?assertEqual(ok,
                 linc_us3_flow:modify(FlowModAdd)).

invalid_out_group() ->
    %% Create flow_mod record
    FlowModAdd = ofp_v3_utils:flow_add(
                   [{table_id,0},
                    {priority,5},
                    {flags,[]}],
                   [{in_port,6}],
                   [{write_actions,[{group,33}]}]),
    ?assertEqual({error,{bad_action,bad_out_group}},
                 linc_us3_flow:modify(FlowModAdd)).

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
    
modify_strict(Flags) ->
    TableId = 4,
    Priority = 6,
    Match = [{in_port,6}, {eth_dst,<<0,0,0,0,0,16#7>>}],

    Instructions1 = [{write_actions,[{output,15,1400}]}],
    %% Create flow_mod record
    FlowModAdd1 = ofp_v3_utils:flow_add(
                    [{table_id,TableId},
                     {priority,Priority},
                     {flags,[]}],
                    Match,
                    Instructions1
                   ),

    Instructions2 = [{write_actions,[{output,32,1400}]}],
    FlowModAdd2 = ofp_v3_utils:flow_modify(
                    modify_strict,
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

    %% Modify flow
    ?assertEqual(ok, linc_us3_flow:modify(FlowModAdd2)),
 
    %% Check that the the new flow has replaced the previous one
    #ofp_flow_mod{match=M1,
                  instructions=I1} = FlowModAdd2,

    [#flow_entry{id=FlowId,
                 match = M2,
                 instructions = I2}] = linc_us3_flow:get_flow_table(TableId),

    ?assertEqual(M1,M2),
    ?assertEqual(I1,I2),

    %% Check that counters entry is correct
    case Flags of
        [reset_counts] ->
            [Stats] = ets:lookup(flow_entry_counters,FlowId),
            ?assertMatch(#flow_entry_counter{received_packets=0,
                                             received_bytes=0},
                         Stats);
        [] ->
            [Stats] = ets:lookup(flow_entry_counters,FlowId),
            ?assertMatch(#flow_entry_counter{received_packets=1,
                                             received_bytes=PacketSize},
                         Stats)
    end.

modify_cookie_no_match() ->    
    TableId = 4,
    Priority = 6,
    Match = [{in_port,6}, {eth_dst,<<0,0,0,0,0,16#7>>}],

    Instructions1 = [{write_actions,[{output,15,1400}]}],
    %% Create flow_mod record
    FlowModAdd1 = ofp_v3_utils:flow_add(
                    [{table_id,TableId},
                     {cookie,<<2:64>>},
                     {priority,Priority},
                     {flags,[]}],
                    Match,
                    Instructions1
                   ),

    Instructions2 = [{write_actions,[{output,32,1400}]}],
    FlowModAdd2 = ofp_v3_utils:flow_modify(
                    modify,
                    [{table_id,TableId},
                     {cookie,<<4:64>>},
                     {cookie_mask,<<4:64>>},
                     {priority,Priority},
                     {flags,[]}],
                    Match,
                    Instructions2),

    %% Add first flow
    ?assertEqual(ok, linc_us3_flow:modify(FlowModAdd1)),
    %% Get FlowId
    [#flow_entry{id=FlowId1}] = linc_us3_flow:get_flow_table(TableId),

    %% Modify flow
    ?assertEqual(ok, linc_us3_flow:modify(FlowModAdd2)),
 
    %% Check that the the flow was not modified
    #ofp_flow_mod{match=M1,
                  instructions=I1} = FlowModAdd1,

    [#flow_entry{match = M2,
                 instructions = I2}] = linc_us3_flow:get_flow_table(TableId),

    ?assertEqual(M1,M2),
    ?assertEqual(I1,I2).
    
modify_cookie_match() ->    
    TableId = 4,
    Priority = 6,
    Match = [{in_port,6}, {eth_dst,<<0,0,0,0,0,16#7>>}],

    Instructions1 = [{write_actions,[{output,15,1400}]}],
    %% Create flow_mod record
    FlowModAdd1 = ofp_v3_utils:flow_add(
                    [{table_id,TableId},
                     {cookie,<<4:64>>},
                     {priority,Priority},
                     {flags,[]}],
                    Match,
                    Instructions1
                   ),

    Instructions2 = [{write_actions,[{output,32,1400}]}],
    FlowModAdd2 = ofp_v3_utils:flow_modify(
                    modify,
                    [{table_id,TableId},
                     {cookie,<<4:64>>},
                     {cookie_mask,<<4:64>>},
                     {priority,Priority},
                     {flags,[]}],
                    Match,
                    Instructions2),

    %% Add first flow
    ?assertEqual(ok, linc_us3_flow:modify(FlowModAdd1)),
    %% Get FlowId
    [#flow_entry{id=FlowId1}] = linc_us3_flow:get_flow_table(TableId),

    %% Modify flow
    ?assertEqual(ok, linc_us3_flow:modify(FlowModAdd2)),
 
    %% Check that the the flow was modified
    #ofp_flow_mod{match=M,
                  instructions=I} = FlowModAdd2,

    [#flow_entry{match = NowMatch,
                 instructions = NowInstr}] = linc_us3_flow:get_flow_table(TableId),

    ?assertEqual(M,NowMatch),
    ?assertEqual(I,NowInstr).

delete_strict() ->    
    TableId = 4,
    Priority = 6,
    Match = [{in_port,6}, {eth_dst,<<0,0,0,0,0,16#7>>}],

    Instructions1 = [{write_actions,[{output,15,1400}]}],
    %% Create flow_mod record
    FlowModAdd1 = ofp_v3_utils:flow_add(
                    [{table_id,TableId},
                     {priority,Priority},
                     {flags,[]}],
                    Match,
                    Instructions1
                   ),

    Instructions2 = [{write_actions,[{output,32,1400}]}],
    FlowModAdd2 = ofp_v3_utils:flow_delete(
                    delete_strict,
                    [{table_id,TableId},
                     {priority,Priority},
                     {flags,[]}],
                    Match),
    
    %% Add flow
    ?assertEqual(ok, linc_us3_flow:modify(FlowModAdd1)),
    %% Check that flow was added
    [#flow_entry{}] = linc_us3_flow:get_flow_table(TableId),
    %% Delete flow
    ?assertEqual(ok, linc_us3_flow:modify(FlowModAdd2)),
    %% Check that flow was deleted
    ?assertEqual([], linc_us3_flow:get_flow_table(TableId)).

delete_cookie_no_match() ->    
    TableId = 4,
    Priority = 6,
    Match = [{in_port,6}, {eth_dst,<<0,0,0,0,0,16#7>>}],

    Instructions1 = [{write_actions,[{output,15,1400}]}],
    %% Create flow_mod record
    FlowModAdd1 = ofp_v3_utils:flow_add(
                    [{table_id,TableId},
                     {cookie,<<2:64>>},
                     {priority,Priority},
                     {flags,[]}],
                    Match,
                    Instructions1
                   ),

    FlowModAdd2 = ofp_v3_utils:flow_delete(
                    delete,
                    [{table_id,TableId},
                     {cookie,<<4:64>>},
                     {cookie_mask,<<4:64>>},
                     {priority,Priority},
                     {flags,[]}],
                    Match),

    %% Add first flow
    ?assertEqual(ok, linc_us3_flow:modify(FlowModAdd1)),
    %% Get FlowId
    [#flow_entry{id=FlowId1}] = linc_us3_flow:get_flow_table(TableId),

    %% Delete flow
    ?assertEqual(ok, linc_us3_flow:modify(FlowModAdd2)),
 
    %% Check that the the flow was not deleted
    #ofp_flow_mod{match=M1,
                  instructions=I1} = FlowModAdd1,

    [#flow_entry{match = M2,
                 instructions = I2}] = linc_us3_flow:get_flow_table(TableId),

    ?assertEqual(M1,M2),
    ?assertEqual(I1,I2).
    
delete_cookie_match() ->    
    TableId = 4,
    Priority = 6,
    Match = [{in_port,6}, {eth_dst,<<0,0,0,0,0,16#7>>}],

    Instructions1 = [{write_actions,[{output,15,1400}]}],
    %% Create flow_mod record
    FlowModAdd1 = ofp_v3_utils:flow_add(
                    [{table_id,TableId},
                     {cookie,<<4:64>>},
                     {priority,Priority},
                     {flags,[]}],
                    Match,
                    Instructions1
                   ),

    FlowModAdd2 = ofp_v3_utils:flow_delete(
                    delete,
                    [{table_id,TableId},
                     {cookie,<<4:64>>},
                     {cookie_mask,<<4:64>>},
                     {priority,Priority},
                     {flags,[]}],
                    Match),

    %% Add first flow
    ?assertEqual(ok, linc_us3_flow:modify(FlowModAdd1)),
    %% Get FlowId
    [#flow_entry{id=FlowId1}] = linc_us3_flow:get_flow_table(TableId),

    %% Delete flow
    ?assertEqual(ok, linc_us3_flow:modify(FlowModAdd2)),
 
    %% Check that the the flow was deleted
    ?assertEqual([], linc_us3_flow:get_flow_table(TableId)).

delete_outport_no_match() ->
    TableId = 4,
    Priority = 6,
    Match = [{in_port,6}, {eth_dst,<<0,0,0,0,0,16#7>>}],

    Instructions1 = [{write_actions,[{output,15,1400}]}],
    %% Create flow_mod record
    FlowModAdd1 = ofp_v3_utils:flow_add(
                    [{table_id,TableId},
                     {priority,Priority},
                     {flags,[]}],
                    Match,
                    Instructions1
                   ),

    FlowModAdd2 = ofp_v3_utils:flow_delete(
                    delete,
                    [{table_id,TableId},
                     {priority,Priority},
                     {out_port,10},
                     {flags,[]}],
                    Match),

    %% Add first flow
    ?assertEqual(ok, linc_us3_flow:modify(FlowModAdd1)),
    %% Get FlowId
    [#flow_entry{id=FlowId1}] = linc_us3_flow:get_flow_table(TableId),

    %% Delete flow
    ?assertEqual(ok, linc_us3_flow:modify(FlowModAdd2)),
 
    %% Check that the the flow was not deleted
    #ofp_flow_mod{match=M1,
                  instructions=I1} = FlowModAdd1,

    [#flow_entry{match = M2,
                 instructions = I2}] = linc_us3_flow:get_flow_table(TableId),

    ?assertEqual(M1,M2),
    ?assertEqual(I1,I2).
    
delete_outport_match() ->
    TableId = 4,
    Priority = 6,
    Match = [{in_port,6}, {eth_dst,<<0,0,0,0,0,16#7>>}],

    Instructions1 = [{write_actions,[{output,15,1400}]}],
    %% Create flow_mod record
    FlowModAdd1 = ofp_v3_utils:flow_add(
                    [{table_id,TableId},
                     {priority,Priority},
                     {flags,[]}],
                    Match,
                    Instructions1
                   ),

    FlowModAdd2 = ofp_v3_utils:flow_delete(
                    delete,
                    [{table_id,TableId},
                     {priority,Priority},
                     {out_port,15},
                     {flags,[]}],
                    Match),

    %% Add first flow
    ?assertEqual(ok, linc_us3_flow:modify(FlowModAdd1)),
    %% Get FlowId
    [#flow_entry{id=FlowId1}] = linc_us3_flow:get_flow_table(TableId),

    %% Delete flow
    ?assertEqual(ok, linc_us3_flow:modify(FlowModAdd2)),
 
    %% Check that the the flow was deleted
    ?assertEqual([], linc_us3_flow:get_flow_table(TableId)).

delete_outgroup_no_match() ->
    TableId = 4,
    Priority = 6,
    Match = [{in_port,6}, {eth_dst,<<0,0,0,0,0,16#7>>}],

    Instructions1 = [{write_actions,[{group,3}]}],
    %% Create flow_mod record
    FlowModAdd1 = ofp_v3_utils:flow_add(
                    [{table_id,TableId},
                     {priority,Priority},
                     {flags,[]}],
                    Match,
                    Instructions1
                   ),

    FlowModAdd2 = ofp_v3_utils:flow_delete(
                    delete,
                    [{table_id,TableId},
                     {priority,Priority},
                     {out_group,10},
                     {flags,[]}],
                    Match),

    %% Add first flow
    ?assertEqual(ok, linc_us3_flow:modify(FlowModAdd1)),
    %% Get FlowId
    [#flow_entry{id=FlowId1}] = linc_us3_flow:get_flow_table(TableId),

    %% Delete flow
    ?assertEqual(ok, linc_us3_flow:modify(FlowModAdd2)),
 
    %% Check that the the flow was not deleted
    #ofp_flow_mod{match=M1,
                  instructions=I1} = FlowModAdd1,

    [#flow_entry{match = M2,
                 instructions = I2}] = linc_us3_flow:get_flow_table(TableId),

    ?assertEqual(M1,M2),
    ?assertEqual(I1,I2).
    
delete_outgroup_match() ->
    TableId = 4,
    Priority = 6,
    Match = [{in_port,6}, {eth_dst,<<0,0,0,0,0,16#7>>}],

    Instructions1 = [{write_actions,[{group,3}]}],
    %% Create flow_mod record
    FlowModAdd1 = ofp_v3_utils:flow_add(
                    [{table_id,TableId},
                     {priority,Priority},
                     {flags,[]}],
                    Match,
                    Instructions1
                   ),

    FlowModAdd2 = ofp_v3_utils:flow_delete(
                    delete,
                    [{table_id,TableId},
                     {priority,Priority},
                     {out_group,3},
                     {flags,[]}],
                    Match),

    %% Add first flow
    ?assertEqual(ok, linc_us3_flow:modify(FlowModAdd1)),
    %% Get FlowId
    [#flow_entry{id=FlowId1}] = linc_us3_flow:get_flow_table(TableId),

    %% Delete flow
    ?assertEqual(ok, linc_us3_flow:modify(FlowModAdd2)),
 
    %% Check that the the flow was deleted
    ?assertEqual([], linc_us3_flow:get_flow_table(TableId)).

delete_all_tables() ->
    %% Create flow_mod record
    FlowModAdd1 = ofp_v3_utils:flow_add(
                   [{table_id,1}],
                   [{in_port,6}, {eth_dst,<<0,0,0,0,0,8>>}],
                   [{write_actions,[{output,15,1400}]}]),

    FlowModAdd2 = ofp_v3_utils:flow_add(
                   [{table_id,2}],
                   [{in_port,6}, {eth_dst,<<0,0,0,0,0,8>>}],
                   [{write_actions,[{output,15,1400}]}]),

    %% Add flows
    ?assertEqual(ok, linc_us3_flow:modify(FlowModAdd1)),
    ?assertEqual(ok, linc_us3_flow:modify(FlowModAdd2)),
 
    %% Check if the flows were added correctly...
    #ofp_flow_mod{match=Match1,
                  instructions=Instructions1} = FlowModAdd1,
    #ofp_flow_mod{match=Match2,
                  instructions=Instructions2} = FlowModAdd2,

    %% Delete all flows
    FlowModDel = ofp_v3_utils:flow_delete(
                   delete,
                   [{table_id,all},
                    {flags,[]}],
                   []),
    ?assertEqual(ok, linc_us3_flow:modify(FlowModDel)),

    ?assertEqual([],linc_us3_flow:get_flow_table(1)),
    ?assertEqual([],linc_us3_flow:get_flow_table(2)).
    
statistics_test_() ->
    {foreach,
     fun setup/0,
     fun teardown/1,
     [{"Update match counter", fun update_match_counter/0}
      ,{"Update match counter, bad flow_id", fun update_bad_match_counter/0}
     ]}.

update_match_counter() ->
    TableId = 5,
    FlowModAdd = ofp_v3_utils:flow_add(
                   [{table_id,TableId},
                    {priority,4},
                    {flags,[]}],
                   [{in_port,6}, {eth_dst,<<0,0,0,0,0,8>>,<<0,0,0,0,0,15>>}],
                   [{write_actions,[{output,15,1400}]}]),

    ?assertEqual(ok, linc_us3_flow:modify(FlowModAdd)),
 
    [#flow_entry{id=FlowId}] = linc_us3_flow:get_flow_table(TableId),

    %% Increments flow counters
    PacketSize = 1024,
    ?assertEqual(ok, linc_us3_flow:update_match_counters(FlowId,PacketSize)),

    [Stats] = ets:lookup(flow_entry_counters,FlowId),
    ?assertMatch(#flow_entry_counter{received_packets=1,
                                     received_bytes=PacketSize},
                 Stats).

update_bad_match_counter() ->
    FlowId = undefined,
    PacketSize = 1024,
    ?assertEqual(ok, linc_us3_flow:update_match_counters(FlowId,PacketSize)),

    ?assertEqual([], ets:lookup(flow_entry_counters,FlowId)).
    
%% Fixtures --------------------------------------------------------------------
setup() ->
    linc_test_utils:mock(?MOCKED),
    ok=linc_us3_flow:initialize().

teardown(ok) ->
    linc_test_utils:unmock(?MOCKED),
    linc_us3_flow:terminate().

%% Helpers ---------------------------------------------------------------------
