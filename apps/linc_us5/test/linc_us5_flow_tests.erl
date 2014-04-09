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
-module(linc_us5_flow_tests).

-ifdef(EQC).
-include_lib("eqc/include/eqc.hrl").
-endif.

-include_lib("eunit/include/eunit.hrl").
-include_lib("of_protocol/include/of_protocol.hrl").
-include_lib("of_protocol/include/ofp_v5.hrl").
-include_lib("linc_us5/include/linc_us5.hrl").

-define(MOCKED, [logic,group,port,meter,monitor]).
-define(SWITCH_ID, 0).

%% Tests -----------------------------------------------------------------------

flow_mod_test_() ->
    {setup, fun setup/0, fun teardown/1,
     {foreach, fun foreach_setup/0, fun foreach_teardown/1,
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
       ,{"Invalid meter", fun invalid_meter/0}
       ,{"Valid meter", fun valid_meter/0}
       ,{"Duplicate instruction type", fun dupl_instruction/0}
       ,{"Set field incompatible with match", fun incompatible_set_field/0}
       ,{"Add 1 flow, no check_overlap", fun () -> add_flow(0, []) end}
       ,{"Add 1 flow, check_overlap", fun () -> add_flow(1, [check_overlap]) end}
       ,{"Add 2 non overlapping flows, no check_overlap", fun () -> add_non_overlapping_flows([]) end}
       ,{"Add 2 non overlapping flows, check_overlap", fun () -> add_non_overlapping_flows([check_overlap]) end}
       ,{"Add 2 overlapping flows, no check_overlap", fun add_overlapping_flows/0}
       ,{"Add 2 with overlapping flow, check_overlap", fun add_overlapping_flow_check_overlap/0}
       ,{"Add 2 with exact match, reset_counters", fun () -> add_exact_flow([reset_counts]) end}
       ,{"Add 2 with exact match, no reset_counters", fun () -> add_exact_flow([]) end}
       ,{"Flow entry priority order", fun flow_priority_order/0}
       ,{"Modify flow, strict, no reset_counts", fun () -> modify_strict([]) end}
       ,{"Modify flow, strict, reset_counts", fun () -> modify_strict([reset_counts]) end}
       ,{"Modify flow, non-strict, cookie no match", fun modify_cookie_no_match/0}
       ,{"Modify flow, non-strict, cookie match", fun modify_cookie_match/0}
       ,{"Delete flow, strict", fun delete_strict/0}
       ,{"Delete flow, non-strict, cookie no match", fun delete_cookie_no_match/0}
       ,{"Delete flow, non-strict, cookie match", fun delete_cookie_match/0}
       ,{"Delete flow, non-strict, send flow rem", fun delete_send_flow_rem/0}
       ,{"Delete flow, outport no match", fun delete_outport_no_match/0}
       ,{"Delete flow, outport match", fun delete_outport_match/0}
       ,{"Delete flow, outgroup no match", fun delete_outgroup_no_match/0}
       ,{"Delete flow, outgroup match", fun delete_outgroup_match/0}
       ,{"Delete flow, all tables", fun delete_all_tables/0}
       ,{"Delete where group", fun delete_where_group/0}
       ,{"Delete where meter", fun delete_where_meter/0}
       ,{"Delete where meter, check reason", fun delete_where_meter_reason/0}
       ,{"Add flow with an incompatible value/mask pair in the match",
         fun incompatible_value_mask_pair_in_match/0}
      ]}}.

bad_table_id() ->
    %% Create flow_mod record
    FlowModAdd = ofp_v5_utils:flow_add(
                   [{table_id,all},
                    {priority,5},
                    {flags,[]}],
                   [{in_port,6},{in_port,6}],
                   [{write_actions,[{output,15,1400}]}]),
    %% Add flow
    ?assertEqual({error,{flow_mod_failed,bad_table_id}},
                 linc_us5_flow:modify(?SWITCH_ID, FlowModAdd, #monitor_data{})).

duplicate_field() ->
    %% Create flow_mod record
    FlowModAdd = ofp_v5_utils:flow_add(
                   [{table_id,0},
                    {priority,5},
                    {flags,[]}],
                   [{in_port,6},{in_port,6}],
                   [{write_actions,[{output,15,1400}]}]),
    %% Add flow
    ?assertEqual({error,{bad_match,dup_field}},
                 linc_us5_flow:modify(?SWITCH_ID, FlowModAdd, #monitor_data{})).

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
    ?assertEqual(ok, linc_us5_flow:modify(?SWITCH_ID, FlowModAdd, #monitor_data{})).

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
    ?assertEqual({error,{bad_match,bad_prereq}},
                 linc_us5_flow:modify(?SWITCH_ID, FlowModAdd, #monitor_data{})).

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
    ?assertEqual({error,{bad_match,bad_prereq}},
                 linc_us5_flow:modify(?SWITCH_ID, FlowModAdd, #monitor_data{})).

%% Goto a table with smaller table_id
goto_backwards() ->
    FlowModAdd = ofp_v5_utils:flow_add(
                   [{table_id,5},
                    {priority,5},
                    {flags,[]}],
                   [{in_port,6}],
                   [{goto_table,2}]),
    ?assertEqual({error,{bad_action,bad_table_id}},
                 linc_us5_flow:modify(?SWITCH_ID, FlowModAdd, #monitor_data{})).

valid_out_port() ->
    %% Create flow_mod record
    FlowModAdd = ofp_v5_utils:flow_add(
                   [{table_id,0},
                    {priority,5},
                    {flags,[]}],
                   [{in_port,6}],
                   [{write_actions,[{output,15,1400}]}]),
    ?assertEqual(ok, linc_us5_flow:modify(?SWITCH_ID, FlowModAdd, #monitor_data{})).

invalid_out_port() ->
    %% Create flow_mod record
    FlowModAdd = ofp_v5_utils:flow_add(
                   [{table_id,0},
                    {priority,5},
                    {flags,[]}],
                   [{in_port,6}],
                   [{write_actions,[{output,33,1400}]}]),
    ?assertEqual({error,{bad_action,bad_out_port}},
                 linc_us5_flow:modify(?SWITCH_ID, FlowModAdd, #monitor_data{})).

valid_out_group() ->
    %% Create flow_mod record
    FlowModAdd = ofp_v5_utils:flow_add(
                   [{table_id,0},
                    {priority,5},
                    {flags,[]}],
                   [{in_port,6}],
                   [{write_actions,[{group,1}]}]),
    ?assertEqual(ok,
                 linc_us5_flow:modify(?SWITCH_ID, FlowModAdd, #monitor_data{})).

invalid_out_group() ->
    %% Create flow_mod record
    FlowModAdd = ofp_v5_utils:flow_add(
                   [{table_id,0},
                    {priority,5},
                    {flags,[]}],
                   [{in_port,6}],
                   [{write_actions,[{group,33}]}]),
    ?assertEqual({error,{bad_action,bad_out_group}},
                 linc_us5_flow:modify(?SWITCH_ID, FlowModAdd, #monitor_data{})).

invalid_meter() ->
    %% Create flow_mod record
    FlowModAdd = ofp_v5_utils:flow_add(
                   [{table_id,0},
                    {priority,5},
                    {flags,[]}],
                   [{in_port,6}],
                   [{meter,9}]),
    ?assertEqual({error,{bad_instruction,unsup_inst}},
                 linc_us5_flow:modify(?SWITCH_ID, FlowModAdd, #monitor_data{})).

valid_meter() ->
    %% Create flow_mod record
    FlowModAdd = ofp_v5_utils:flow_add(
                   [{table_id,0},
                    {priority,5},
                    {flags,[]}],
                   [{in_port,6}],
                   [{meter,4}]),
    ?assertEqual(ok,
                 linc_us5_flow:modify(?SWITCH_ID, FlowModAdd, #monitor_data{})).

dupl_instruction() ->
    %% As of version 1.4 of the spec, a duplicate instruction causes a
    %% dup_inst error.
    FlowModAdd = ofp_v5_utils:flow_add(
                   [{table_id,5},
                    {priority,5},
                    {flags,[]}],
                   [{in_port,6},{eth_type,<<8,0>>},{udp_src,<<8,0>>}],
                   [{write_actions,[{set_field,tcp_dst,<<8,0>>}]},
                    {write_actions,[{set_field,tcp_dst,<<8,0>>}]}]),
    ?assertEqual({error,{bad_instruction, dup_inst}},
                 linc_us5_flow:modify(?SWITCH_ID, FlowModAdd, #monitor_data{})).

%% Match un UDP, but action tries to change a TCP field
incompatible_set_field() ->
    FlowModAdd = ofp_v5_utils:flow_add(
                   [{table_id,5},
                    {priority,5},
                    {flags,[]}],
                   [{in_port,6},{eth_type,<<8,0>>},{udp_src,<<8,0>>}],
                   [{write_actions,[{set_field,tcp_dst,<<8,0>>}]}]),
    ?assertEqual({error,{bad_action,bad_argument}},
                 linc_us5_flow:modify(?SWITCH_ID, FlowModAdd, #monitor_data{})).

%% Add one flow, in an empty table, this should always succeed.
add_flow(TableId, Flags) ->
    Priority=5,
    %% Create flow_mod record
    FlowModAdd = ofp_v5_utils:flow_add(
                   [{table_id,TableId},
                    {priority,Priority},
                    {flags,Flags}],
                   [{in_port,6}, {eth_dst,<<0,0,0,0,0,8>>,<<0,0,0,0,0,15>>}],
                   [{write_actions,[{output,15,1400}]}]),
    ?assertEqual(ok, linc_us5_flow:modify(?SWITCH_ID, FlowModAdd, #monitor_data{})),

    %% Check if the flow was added correctly...
    #ofp_flow_mod{match=Match,
                  instructions=Instructions} = FlowModAdd,

    [#flow_entry{id=Id,
                 match=Match1,
                 instructions=Instructions1}] =
        linc_us5_flow:get_flow_table(?SWITCH_ID, TableId),

    ?assertEqual(Match, Match1),
    ?assertEqual(Instructions, Instructions1),

    %% Check that counters entry has been created
    FlowEntryCounters = linc:lookup(?SWITCH_ID, flow_entry_counters),
    ?assertMatch([#flow_entry_counter{}], ets:lookup(FlowEntryCounters, Id)).

%% Add two non overlapping flows, this should always succeed, independent of
%% if the check_overlap flag is set
add_non_overlapping_flows(Flags) ->
    TableId = 2,
    Priority=5,
    %% Create flow_mod record
    FlowModAdd1 = ofp_v5_utils:flow_add(
                    [{table_id,TableId},
                     {priority,Priority},
                     {flags,Flags}],
                    [{in_port,6}, {eth_dst,<<0,0,0,0,0,8>>}],
                    [{write_actions,[{output,15,1400}]}]),

    FlowModAdd2 = ofp_v5_utils:flow_add(
                    [{table_id,TableId},
                     {priority,Priority},
                     {flags,Flags}],
                    [{in_port,6}, {eth_dst,<<0,0,0,0,0,9>>}],
                    [{write_actions,[{output,15,1400}]}]),
    %% Add flows
    ?assertEqual(ok, linc_us5_flow:modify(?SWITCH_ID, FlowModAdd1, #monitor_data{})),
    ?assertEqual(ok, linc_us5_flow:modify(?SWITCH_ID, FlowModAdd2, #monitor_data{})),

    %% Check if the flows were added correctly...
    #ofp_flow_mod{match=Match1,
                  instructions=Instructions1} = FlowModAdd1,
    #ofp_flow_mod{match=Match2,
                  instructions=Instructions2} = FlowModAdd2,

    [#flow_entry{match=GotMatch1, instructions=GotInstructions1},
     #flow_entry{match=GotMatch2, instructions=GotInstructions2}] =
        linc_us5_flow:get_flow_table(?SWITCH_ID, TableId),
    ?assertEqual(lists:sort([{Match1,Instructions1},{Match2, Instructions2}]),
                 lists:sort([{GotMatch1,GotInstructions1},{GotMatch2, GotInstructions2}])).

%% Add two overlapping, but not exact, flows, without the check_overlap flag set,
%% this should succeed.
add_overlapping_flows() ->
    TableId = 2,
    Priority=5,
    Flags = [],
    %% Create flow_mod record
    FlowModAdd1 = ofp_v5_utils:flow_add(
                    [{table_id,TableId},
                     {priority,Priority},
                     {flags,Flags}],
                    [{in_port,6}, {eth_dst,<<0,0,0,0,0,7>>,<<0,0,0,0,0,15>>}],
                    [{write_actions,[{output,15,1400}]}]),

    FlowModAdd2 = ofp_v5_utils:flow_add(
                    [{table_id,TableId},
                     {priority,Priority},
                     {flags,Flags}],
                    [{in_port,6}, {eth_dst,<<0,0,0,0,0,9>>,<<0,0,0,0,0,31>>}],
                    [{write_actions,[{output,15,1400}]}]),
    %% Add flows
    ?assertEqual(ok, linc_us5_flow:modify(?SWITCH_ID, FlowModAdd1, #monitor_data{})),
    ?assertEqual(ok, linc_us5_flow:modify(?SWITCH_ID, FlowModAdd2, #monitor_data{})),

    %% Check if the flows were added correctly...
    #ofp_flow_mod{match=Match1,
                  instructions=Instructions1} = FlowModAdd1,
    #ofp_flow_mod{match=Match2,
                  instructions=Instructions2} = FlowModAdd2,

    [#flow_entry{match=GotMatch1,
                 instructions=GotInstructions1},
     #flow_entry{match=GotMatch2,
                 instructions=GotInstructions2}]
        = linc_us5_flow:get_flow_table(?SWITCH_ID, TableId),
    ?assertEqual(lists:sort([{Match1,Instructions1},
                             {Match2, Instructions2}]),
                 lists:sort([{GotMatch1,GotInstructions1},
                             {GotMatch2, GotInstructions2}])).

%% Add two overlapping, but not exact, flows, with the check_overlap flag set,
%% this should fail.
add_overlapping_flow_check_overlap() ->
    TableId = 2,
    Priority=5,
    Flags = [check_overlap,send_flow_rem],
    %% Create flow_mod record
    FlowModAdd1 = ofp_v5_utils:flow_add(
                    [{table_id,TableId},
                     {priority,Priority},
                     {flags,Flags}],
                    [{in_port,6}, {eth_dst,<<0,0,0,0,0,16#7>>,<<0,0,0,0,0,16#0F>>}],
                    [{write_actions,[{output,15,1400}]}]),

    FlowModAdd2 = ofp_v5_utils:flow_add(
                    [{table_id,TableId},
                     {priority,Priority},
                     {flags,Flags}],
                    [{in_port,6}, {eth_dst,<<0,0,0,0,0,16#17>>,<<0,0,0,0,0,16#1F>>}],
                    [{write_actions,[{output,15,1400}]}]),
    %% Add flows
    ?assertEqual(ok, linc_us5_flow:modify(?SWITCH_ID, FlowModAdd1, #monitor_data{})),
    ?assertEqual({error,{flow_mod_failed,overlap}},
                 linc_us5_flow:modify(?SWITCH_ID, FlowModAdd2, #monitor_data{})),

    %% Check that flow_removed has not been sent
    %% FIXME: Cannot mock linc_logic module that belongs to another application
    %% ?assertEqual(false,linc_us5_test_utils:check_if_called({linc_logic,send_to_controllers,1})),
    %% Check that the the overlapping flow was not added
    #ofp_flow_mod{match=Match1,
                  instructions=Instructions1} = FlowModAdd1,

    ?assertMatch([#flow_entry{match=Match1,
                              instructions=Instructions1}],
                 linc_us5_flow:get_flow_table(?SWITCH_ID, TableId)).

add_exact_flow(Flags) ->
    TableId = 4,
    Priority = 6,
    Match = [{in_port,6}, {eth_dst,<<0,0,0,0,0,16#7>>}],

    Instructions1 = [{write_actions,[{output,15,1400}]}],
    %% Create flow_mod record
    FlowModAdd1 = ofp_v5_utils:flow_add(
                    [{table_id,TableId},
                     {priority,Priority},
                     {flags,Flags}],
                    Match,
                    Instructions1
                   ),

    Instructions2 = [{write_actions,[{output,32,1400}]}],
    FlowModAdd2 = ofp_v5_utils:flow_add(
                    [{table_id,TableId},
                     {priority,Priority},
                     {flags,Flags}],
                    Match,
                    Instructions2),

    %% Add first flow
    ?assertEqual(ok, linc_us5_flow:modify(?SWITCH_ID, FlowModAdd1, #monitor_data{})),
    %% Get FlowId
    [#flow_entry{id=FlowId1}] = linc_us5_flow:get_flow_table(?SWITCH_ID,
                                                             TableId),

    %% Increments flow counters
    PacketSize = 1024,
    linc_us5_flow:update_match_counters(?SWITCH_ID, TableId,
                                        FlowId1, PacketSize),

    %% Check that counters are updated
    FlowEntryCounters = linc:lookup(?SWITCH_ID, flow_entry_counters),
    [#flow_entry_counter{
        id=FlowId1,
        received_packets=1,
        received_bytes=PacketSize}] = ets:lookup(FlowEntryCounters, FlowId1),

    %% Add second flow
    ?assertEqual(ok, linc_us5_flow:modify(?SWITCH_ID, FlowModAdd2, #monitor_data{})),

    %% Check that the the new flow has replaced the previous one
    #ofp_flow_mod{match=M1,
                  instructions=I1} = FlowModAdd2,

    [#flow_entry{id = FlowId2,
                 match = M2,
                 instructions = I2}] = linc_us5_flow:get_flow_table(?SWITCH_ID,
                                                                    TableId),

    ?assertEqual(M1,M2),
    ?assertEqual(I1,I2),

    %% Check that counters entry is correct
    case Flags of
        [reset_counts] ->
            [Stats] = ets:lookup(FlowEntryCounters, FlowId2),
            ?assertMatch(#flow_entry_counter{received_packets=0,
                                             received_bytes=0},
                         Stats);
        [] ->
            [Stats] = ets:lookup(FlowEntryCounters, FlowId1),
            ?assertMatch(#flow_entry_counter{received_packets=1,
                                             received_bytes=PacketSize},
                         Stats)
    end.

flow_priority_order() ->
    TableId = 0,
    %% Create flow_mod record
    FlowModAdd1 = ofp_v5_utils:flow_add(
                    [{table_id,TableId},
                     {priority,100},
                     {flags,[]}],
                    [{in_port,6}, {eth_dst,<<0,0,0,0,0,8>>}],
                    [{write_actions,[{output,15,1400}]}]),

    FlowModAdd2 = ofp_v5_utils:flow_add(
                    [{table_id,TableId},
                     {priority,200},
                     {flags,[]}],
                    [{in_port,6}, {eth_dst,<<0,0,0,0,0,9>>}],
                    [{write_actions,[{output,5,1400}]}]),
    %% Add flows
    ?assertEqual(ok, linc_us5_flow:modify(?SWITCH_ID, FlowModAdd1, #monitor_data{})),
    ?assertEqual(ok, linc_us5_flow:modify(?SWITCH_ID, FlowModAdd2, #monitor_data{})),

    %% Check if the flows were added correctly...
    #ofp_flow_mod{match=Match1,
                  instructions=Instructions1} = FlowModAdd1,
    #ofp_flow_mod{match=Match2,
                  instructions=Instructions2} = FlowModAdd2,

    ?assertMatch([#flow_entry{priority=200,
                              match=Match2,
                              instructions=Instructions2},
                  #flow_entry{priority=100,
                              match=Match1,
                              instructions=Instructions1}],
                 linc_us5_flow:get_flow_table(?SWITCH_ID, TableId)).

modify_strict(Flags) ->
    TableId = 4,
    Priority = 6,
    Match = [{in_port,6}, {eth_dst,<<0,0,0,0,0,16#7>>}],

    Instructions1 = [{write_actions,[{output,15,1400}]}],
    %% Create flow_mod record
    FlowModAdd1 = ofp_v5_utils:flow_add(
                    [{table_id,TableId},
                     {priority,Priority},
                     {flags,[]}],
                    Match,
                    Instructions1
                   ),

    Instructions2 = [{write_actions,[{output,32,1400}]}],
    FlowMod = ofp_v5_utils:flow_modify(modify_strict,
                                       [{table_id,TableId},
                                        {priority,Priority},
                                        {flags,Flags}],
                                       Match,
                                       Instructions2),

    %% Add first flow
    ?assertEqual(ok, linc_us5_flow:modify(?SWITCH_ID, FlowModAdd1, #monitor_data{})),
    %% Get FlowId
    [#flow_entry{id=FlowId}] = linc_us5_flow:get_flow_table(?SWITCH_ID,
                                                            TableId),

    %% Increments flow counters
    PacketSize = 1024,
    linc_us5_flow:update_match_counters(?SWITCH_ID, TableId,
                                        FlowId, PacketSize),

    %% Check that counters are updated
    FlowEntryCounters = linc:lookup(?SWITCH_ID, flow_entry_counters),
    ?assertMatch([#flow_entry_counter{
                     id=FlowId,
                     received_packets=1,
                     received_bytes=PacketSize}],
                 ets:lookup(FlowEntryCounters, FlowId)),

    %% Modify flow
    ?assertEqual(ok, linc_us5_flow:modify(?SWITCH_ID, FlowMod, #monitor_data{})),

    %% Check that the the new flow has replaced the previous one
    #ofp_flow_mod{match=M1, instructions=I1} = FlowMod,

    ?assertMatch([#flow_entry{id=FlowId, match = M1, instructions = I1}],
                 linc_us5_flow:get_flow_table(?SWITCH_ID, TableId)),

    %% Check that counters entry is correct
    case Flags of
        [reset_counts] ->
            ?assertMatch([#flow_entry_counter{received_packets=0,
                                              received_bytes=0}],
                         ets:lookup(FlowEntryCounters, FlowId));
        [] ->
            ?assertMatch([#flow_entry_counter{received_packets=1,
                                              received_bytes=PacketSize}],
                         ets:lookup(FlowEntryCounters, FlowId))
    end.

modify_cookie_no_match() ->
    TableId = 4,
    Priority = 6,
    Match = [{in_port,6}, {eth_dst,<<0,0,0,0,0,16#7>>}],
    %% Create flow_mod record
    FlowModAdd1 = ofp_v5_utils:flow_add([{table_id,TableId},
                                         {cookie,<<2:64>>},
                                         {priority,Priority},
                                         {flags,[]}],
                                        Match,
                                        [{write_actions,[{output,15,1400}]}]
                                       ),
    FlowMod = ofp_v5_utils:flow_modify(modify,
                                       [{table_id,TableId},
                                        {cookie,<<4:64>>},
                                        {cookie_mask,<<4:64>>},
                                        {priority,Priority},
                                        {flags,[]}],
                                       Match,
                                       [{write_actions,[{output,32,1400}]}]),

    %% Add first flow
    ?assertEqual(ok, linc_us5_flow:modify(?SWITCH_ID, FlowModAdd1, #monitor_data{})),
    ?assertMatch([#flow_entry{}], linc_us5_flow:get_flow_table(?SWITCH_ID,
                                                               TableId)),

    %% Modify flow
    ?assertEqual(ok, linc_us5_flow:modify(?SWITCH_ID, FlowMod, #monitor_data{})),

    %% Check that the the flow was not modified
    #ofp_flow_mod{match=M1,
                  instructions=I1} = FlowModAdd1,

    ?assertMatch([#flow_entry{match = M1,
                              instructions = I1}],
                 linc_us5_flow:get_flow_table(?SWITCH_ID, TableId)).

modify_cookie_match() ->
    TableId = 4,
    Priority = 6,
    Match = [{in_port,6}, {eth_dst,<<0,0,0,0,0,16#7>>}],

    Instructions1 = [{write_actions,[{output,15,1400}]}],
    %% Create flow_mod record
    FlowModAdd1 = ofp_v5_utils:flow_add(
                    [{table_id,TableId},
                     {cookie,<<4:64>>},
                     {priority,Priority},
                     {flags,[]}],
                    Match,
                    Instructions1
                   ),

    Instructions2 = [{write_actions,[{output,32,1400}]}],
    FlowModAdd2 = ofp_v5_utils:flow_modify(
                    modify,
                    [{table_id,TableId},
                     {cookie,<<4:64>>},
                     {cookie_mask,<<4:64>>},
                     {priority,Priority},
                     {flags,[]}],
                    Match,
                    Instructions2),

    %% Add first flow
    ?assertEqual(ok, linc_us5_flow:modify(?SWITCH_ID, FlowModAdd1, #monitor_data{})),

    ?assertMatch([#flow_entry{}], linc_us5_flow:get_flow_table(?SWITCH_ID,
                                                               TableId)),

    %% Modify flow
    ?assertEqual(ok, linc_us5_flow:modify(?SWITCH_ID, FlowModAdd2, #monitor_data{})),

    %% Check that the the flow was modified
    #ofp_flow_mod{match=M,
                  instructions=I} = FlowModAdd2,

    ?assertMatch([#flow_entry{match = M,
                              instructions = I}],
                 linc_us5_flow:get_flow_table(?SWITCH_ID, TableId)).

delete_strict() ->
    TableId = 4,
    Priority = 6,
    Match = [{in_port,6}, {eth_dst,<<0,0,0,0,0,16#7>>}],
    %% Create flow_mod record
    FlowModAdd1 = ofp_v5_utils:flow_add(
                    [{table_id,TableId},
                     {priority,Priority},
                     {flags,[]}],
                    Match,
                    [{write_actions,[{output,15,1400}]}]
                   ),

    FlowDel = ofp_v5_utils:flow_delete(
                delete_strict,
                [{table_id,TableId},
                 {priority,Priority},
                 {flags,[]}],
                Match),

    %% Add flow
    ?assertEqual(ok, linc_us5_flow:modify(?SWITCH_ID, FlowModAdd1, #monitor_data{})),
    %% Check that flow was added
    [#flow_entry{}] = linc_us5_flow:get_flow_table(?SWITCH_ID, TableId),
    %% Delete flow
    ?assertEqual(ok, linc_us5_flow:modify(?SWITCH_ID, FlowDel, #monitor_data{})),
    %% Check that flow was deleted
    ?assertEqual([], linc_us5_flow:get_flow_table(?SWITCH_ID, TableId)).

delete_cookie_no_match() ->
    TableId = 4,
    Priority = 6,
    Match = [{in_port,6}, {eth_dst,<<0,0,0,0,0,16#7>>}],

    Instructions1 = [{write_actions,[{output,15,1400}]}],
    %% Create flow_mod record
    FlowModAdd1 = ofp_v5_utils:flow_add(
                    [{table_id,TableId},
                     {cookie,<<2:64>>},
                     {priority,Priority},
                     {flags,[]}],
                    Match,
                    Instructions1
                   ),

    FlowDel = ofp_v5_utils:flow_delete(
                delete,
                [{table_id,TableId},
                 {cookie,<<4:64>>},
                 {cookie_mask,<<4:64>>},
                 {priority,Priority},
                 {flags,[]}],
                Match),

    %% Add first flow
    ?assertEqual(ok, linc_us5_flow:modify(?SWITCH_ID, FlowModAdd1, #monitor_data{})),
    %% Get FlowId
    ?assertMatch([#flow_entry{}], linc_us5_flow:get_flow_table(?SWITCH_ID,
                                                               TableId)),

    %% Delete flow
    ?assertEqual(ok, linc_us5_flow:modify(?SWITCH_ID, FlowDel, #monitor_data{})),

    %% Check that the the flow was not deleted
    #ofp_flow_mod{match=M1,
                  instructions=I1} = FlowModAdd1,

    ?assertMatch([#flow_entry{match = M1,
                              instructions = I1}],
                 linc_us5_flow:get_flow_table(?SWITCH_ID, TableId)).

delete_cookie_match() ->
    TableId = 4,
    Priority = 6,
    Match = [{in_port,6}, {eth_dst,<<0,0,0,0,0,16#7>>}],

    Instructions1 = [{write_actions,[{output,15,1400}]}],
    %% Create flow_mod record
    FlowModAdd1 = ofp_v5_utils:flow_add(
                    [{table_id,TableId},
                     {cookie,<<4:64>>},
                     {priority,Priority},
                     {flags,[]}],
                    Match,
                    Instructions1
                   ),

    FlowDel = ofp_v5_utils:flow_delete(
                    delete,
                    [{table_id,TableId},
                     {cookie,<<4:64>>},
                     {cookie_mask,<<4:64>>},
                     {priority,Priority},
                     {flags,[]}],
                    Match),

    %% Add first flow
    ?assertEqual(ok, linc_us5_flow:modify(?SWITCH_ID, FlowModAdd1, #monitor_data{})),
    %% Get FlowId
    ?assertMatch([#flow_entry{}], linc_us5_flow:get_flow_table(?SWITCH_ID,
                                                               TableId)),

    %% Delete flow
    ?assertEqual(ok, linc_us5_flow:modify(?SWITCH_ID, FlowDel, #monitor_data{})),

    %% Check that the the flow was deleted
    ?assertEqual([], linc_us5_flow:get_flow_table(?SWITCH_ID, TableId)).

delete_send_flow_rem() ->
    TableId = 4,
    Priority = 6,
    Match = [{in_port,6}, {eth_dst,<<0,0,0,0,0,16#7>>}],

    Instructions1 = [{write_actions,[{output,15,1400}]}],
    %% Create flow_mod record
    FlowModAdd1 = ofp_v5_utils:flow_add(
                    [{table_id,TableId},
                     {cookie,<<4:64>>},
                     {priority,Priority},
                     {flags,[send_flow_rem]}],
                    Match,
                    Instructions1
                   ),

    FlowDel = ofp_v5_utils:flow_delete(
                    delete,
                    [{table_id,TableId},
                     {cookie,<<4:64>>},
                     {cookie_mask,<<4:64>>},
                     {priority,Priority},
                     {flags,[]}],
                    Match),

    %% Add first flow
    ?assertEqual(ok, linc_us5_flow:modify(?SWITCH_ID, FlowModAdd1, #monitor_data{})),
    %% Get FlowId
    ?assertMatch([#flow_entry{}], linc_us5_flow:get_flow_table(?SWITCH_ID,
                                                               TableId)),

    %% Delete flow
    ?assertEqual(ok, linc_us5_flow:modify(?SWITCH_ID, FlowDel, #monitor_data{})),

    %% Check that the the flow was deleted
    ?assertEqual([], linc_us5_flow:get_flow_table(?SWITCH_ID, TableId)).
    %% FIXME: Cannot mock linc_logic module that belongs to another application
    %% ?assertEqual(true,linc_us5_test_utils:check_if_called({linc_logic,send_to_controllers,1})).


delete_outport_no_match() ->
    TableId = 4,
    Priority = 6,
    Match = [{in_port,6}, {eth_dst,<<0,0,0,0,0,16#7>>}],

    Instructions1 = [{write_actions,[{output,15,1400}]}],
    %% Create flow_mod record
    FlowModAdd1 = ofp_v5_utils:flow_add(
                    [{table_id,TableId},
                     {priority,Priority},
                     {flags,[]}],
                    Match,
                    Instructions1
                   ),

    FlowDel = ofp_v5_utils:flow_delete(
                delete,
                [{table_id,TableId},
                 {priority,Priority},
                 {out_port,10},
                 {flags,[]}],
                Match),

    %% Add first flow
    ?assertEqual(ok, linc_us5_flow:modify(?SWITCH_ID, FlowModAdd1, #monitor_data{})),
    ?assertMatch([#flow_entry{}], linc_us5_flow:get_flow_table(?SWITCH_ID,
                                                               TableId)),

    %% Delete flow
    ?assertEqual(ok, linc_us5_flow:modify(?SWITCH_ID, FlowDel, #monitor_data{})),

    %% Check that the the flow was not deleted
    #ofp_flow_mod{match=M1,
                  instructions=I1} = FlowModAdd1,

    ?assertMatch([#flow_entry{match = M1, instructions = I1}],
                 linc_us5_flow:get_flow_table(?SWITCH_ID, TableId)).

delete_outport_match() ->
    TableId = 4,
    Priority = 6,
    Match = [{in_port,6}, {eth_dst,<<0,0,0,0,0,16#7>>}],

    Instructions1 = [{write_actions,[{output,15,1400}]}],
    %% Create flow_mod record
    FlowModAdd1 = ofp_v5_utils:flow_add(
                    [{table_id,TableId},
                     {priority,Priority},
                     {flags,[]}],
                    Match,
                    Instructions1
                   ),

    FlowDel = ofp_v5_utils:flow_delete(
                    delete,
                    [{table_id,TableId},
                     {priority,Priority},
                     {out_port,15},
                     {flags,[]}],
                    Match),

    %% Add first flow
    ?assertEqual(ok, linc_us5_flow:modify(?SWITCH_ID, FlowModAdd1, #monitor_data{})),
    ?assertMatch([#flow_entry{}], linc_us5_flow:get_flow_table(?SWITCH_ID,
                                                               TableId)),

    %% Delete flow
    ?assertEqual(ok, linc_us5_flow:modify(?SWITCH_ID, FlowDel, #monitor_data{})),

    %% Check that the the flow was deleted
    ?assertEqual([], linc_us5_flow:get_flow_table(?SWITCH_ID, TableId)).

delete_outgroup_no_match() ->
    TableId = 4,
    Priority = 6,
    Match = [{in_port,6}, {eth_dst,<<0,0,0,0,0,16#7>>}],

    Instructions1 = [{write_actions,[{group,3}]}],
    %% Create flow_mod record
    FlowModAdd1 = ofp_v5_utils:flow_add(
                    [{table_id,TableId},
                     {priority,Priority},
                     {flags,[]}],
                    Match,
                    Instructions1
                   ),

    FlowDel = ofp_v5_utils:flow_delete(
                delete,
                [{table_id,TableId},
                 {priority,Priority},
                 {out_group,10},
                 {flags,[]}],
                Match),

    %% Add first flow
    ?assertEqual(ok, linc_us5_flow:modify(?SWITCH_ID, FlowModAdd1, #monitor_data{})),
    %% Get FlowId
    ?assertMatch([#flow_entry{}], linc_us5_flow:get_flow_table(?SWITCH_ID,
                                                               TableId)),

    %% Delete flow
    ?assertEqual(ok, linc_us5_flow:modify(?SWITCH_ID, FlowDel, #monitor_data{})),

    %% Check that the the flow was not deleted
    #ofp_flow_mod{match=M1, instructions=I1} = FlowModAdd1,

    ?assertMatch([#flow_entry{match = M1, instructions = I1}],
                 linc_us5_flow:get_flow_table(?SWITCH_ID, TableId)).

delete_outgroup_match() ->
    TableId = 4,
    Priority = 6,
    Match = [{in_port,6}, {eth_dst,<<0,0,0,0,0,16#7>>}],

    Instructions1 = [{write_actions,[{group,3}]}],
    %% Create flow_mod record
    FlowModAdd1 = ofp_v5_utils:flow_add(
                    [{table_id,TableId},
                     {priority,Priority},
                     {flags,[]}],
                    Match,
                    Instructions1
                   ),

    FlowDel = ofp_v5_utils:flow_delete(
                delete,
                [{table_id,TableId},
                 {priority,Priority},
                 {out_group,3},
                 {flags,[]}],
                Match),

    %% Add first flow
    ?assertEqual(ok, linc_us5_flow:modify(?SWITCH_ID, FlowModAdd1, #monitor_data{})),
    %% Get FlowId
    ?assertMatch([#flow_entry{}], linc_us5_flow:get_flow_table(?SWITCH_ID,
                                                               TableId)),

    %% Delete flow
    ?assertEqual(ok, linc_us5_flow:modify(?SWITCH_ID, FlowDel, #monitor_data{})),

    %% Check that the the flow was deleted
    ?assertEqual([], linc_us5_flow:get_flow_table(?SWITCH_ID, TableId)).

delete_all_tables() ->
    %% Create flow_mod record
    FlowModAdd1 = ofp_v5_utils:flow_add(
                    [{table_id,1}],
                    [{in_port,6}, {eth_dst,<<0,0,0,0,0,8>>}],
                    [{write_actions,[{output,15,1400}]}]),

    FlowModAdd2 = ofp_v5_utils:flow_add(
                    [{table_id,2}],
                    [{in_port,6}, {eth_dst,<<0,0,0,0,0,8>>}],
                    [{write_actions,[{output,15,1400}]}]),

    %% Add flows
    ?assertEqual(ok, linc_us5_flow:modify(?SWITCH_ID, FlowModAdd1, #monitor_data{})),
    ?assertEqual(ok, linc_us5_flow:modify(?SWITCH_ID, FlowModAdd2, #monitor_data{})),

    %% Check if the flows were added correctly...
    ?assertMatch([#flow_entry{}], linc_us5_flow:get_flow_table(?SWITCH_ID, 1)),
    ?assertMatch([#flow_entry{}], linc_us5_flow:get_flow_table(?SWITCH_ID, 2)),

    %% Delete all flows
    FlowDel = ofp_v5_utils:flow_delete(
                delete,
                [{table_id,all},
                 {flags,[]}],
                []),
    ?assertEqual(ok, linc_us5_flow:modify(?SWITCH_ID, FlowDel, #monitor_data{})),

    ?assertEqual([],linc_us5_flow:get_flow_table(?SWITCH_ID, 1)),
    ?assertEqual([],linc_us5_flow:get_flow_table(?SWITCH_ID, 2)).

delete_where_group() ->
    %% Create flow_mod record
    FlowModAdd1 = ofp_v5_utils:flow_add(
                    [{table_id,1}],
                    [{in_port,6}, {eth_dst,<<0,0,0,0,0,8>>}],
                    [{write_actions,[{group,3}]}]),
    FlowModAdd2 = ofp_v5_utils:flow_add(
                    [{table_id,1}],
                    [{in_port,6}, {eth_dst,<<0,0,0,0,0,8>>}],
                    [{write_actions,[{group,4}]}]),

    %% Add flows
    ?assertEqual(ok, linc_us5_flow:modify(?SWITCH_ID, FlowModAdd1, #monitor_data{})),
    ?assertEqual(ok, linc_us5_flow:modify(?SWITCH_ID, FlowModAdd2, #monitor_data{})),

    #ofp_flow_mod{match=Match2,
                  instructions=Instructions2} = FlowModAdd2,

    %% Delete all referencing group 3
    ?assertEqual(ok, linc_us5_flow:delete_where_group(?SWITCH_ID, 3, #monitor_data{})),

    ?assertMatch([#flow_entry{match=Match2,
                              instructions=Instructions2}],
                 linc_us5_flow:get_flow_table(?SWITCH_ID, 1)).

delete_where_meter() ->
    %% Create flow_mod record
    FlowModAdd1 = ofp_v5_utils:flow_add(
                    [{table_id,1}],
                    [{in_port,6}, {eth_dst,<<0,0,0,0,0,8>>}],
                    [{meter,4}]),
    FlowModAdd2 = ofp_v5_utils:flow_add(
                    [{table_id,1}],
                    [{in_port,6}, {eth_dst,<<0,0,0,0,0,8>>}],
                    [{meter,5}]),

    %% Add flows
    ?assertEqual(ok, linc_us5_flow:modify(?SWITCH_ID, FlowModAdd1, #monitor_data{})),
    ?assertEqual(ok, linc_us5_flow:modify(?SWITCH_ID, FlowModAdd2, #monitor_data{})),

    #ofp_flow_mod{match=Match2,
                  instructions=Instructions2} = FlowModAdd2,

    %% Delete all referencing meter 4
    ?assertEqual(ok, linc_us5_flow:delete_where_meter(?SWITCH_ID, 4, #monitor_data{})),

    ?assertMatch([#flow_entry{match=Match2,
                              instructions=Instructions2}],
                 linc_us5_flow:get_flow_table(?SWITCH_ID, 1)).

delete_where_meter_reason() ->
    %% Add flow with with a send_flow_rem flag
    FlowModAdd = ofp_v5_utils:flow_add(
                    [{table_id,1}, {flags, [send_flow_rem]}],
                    [{in_port,6}, {eth_dst,<<0,0,0,0,0,9>>}],
                    [{meter,4}]),

    ?assertEqual(ok, linc_us5_flow:modify(?SWITCH_ID, FlowModAdd, #monitor_data{})),
    %% Delete flows referencing meter 5
    ?assertEqual(ok, linc_us5_flow:delete_where_meter(?SWITCH_ID, 4, #monitor_data{})),

    %%timer:sleep(1000),
    Msgs = linc_us5_test_utils:check_output_to_controllers(),
    Msg = lists:last([M || {?SWITCH_ID, ofp_flow_removed, M} <- Msgs, 
                           is_record(M, ofp_flow_removed)]),
    ?assertMatch(meter_delete, Msg#ofp_flow_removed.reason).

incompatible_value_mask_pair_in_match() ->
    FlowModAdd = ofp_v5_utils:flow_add(
                   [],
                   %% In the last octet in the address to be matched there's
                   %% a binary value of 00000111 while in the mask 00000110.
                   %% This is an error as all bits set to 1 in a value demand
                   %% a corresponding bit in the mask set to 1.
                   [{eth_type, <<16#800:16>>},
                    {ipv4_src, <<10,0,0,7>>, <<10,0,0,6>>}],
                   [{write_actions,[{output,15,no_buffer}]}]),
    ?assertEqual({error, {bad_match, bad_wildcards}},
                 linc_us5_flow:modify(?SWITCH_ID, FlowModAdd, #monitor_data{})).

statistics_test_() ->
    {setup, fun setup/0, fun teardown/1,
     {foreach, fun foreach_setup/0, fun foreach_teardown/1,
      [{"Update lookup counter", fun update_lookup_counter/0}
       ,{"Update match counter", fun update_match_counter/0}
       ,{"Update match counter, bad flow_id", fun update_bad_match_counter/0}
       ,{"Empty flow stats", fun empty_flow_stats/0}
       ,{"Flow stats 1 table", fun flow_stats_1_table/0}
       ,{"Flow stats all tables", fun flow_stats_all_tables/0}
       ,{"Empty aggregate stats", fun empty_aggr_stats/0}
       ,{"Aggregate stats 1 table", fun aggr_stats_1_table/0}
       ,{"Aggregate stats all tables", fun aggr_stats_all_tables/0}
       ,{"Empty table stats", fun empty_table_stats/0}
      ]}}.

update_lookup_counter() ->
    TableId = 1,
    FlowTableCounters = linc:lookup(?SWITCH_ID, flow_table_counters),
    ?assertEqual(ok, linc_us5_flow:update_lookup_counter(?SWITCH_ID, TableId)),
    ?assertMatch([#flow_table_counter{packet_lookups=1}],
                 ets:lookup(FlowTableCounters, TableId)).


update_match_counter() ->
    TableId = 5,
    FlowModAdd = ofp_v5_utils:flow_add(
                   [{table_id,TableId},
                    {priority,4},
                    {flags,[]}],
                   [{in_port,6}, {eth_dst,<<0,0,0,0,0,8>>,<<0,0,0,0,0,15>>}],
                   [{write_actions,[{output,15,1400}]}]),

    ?assertEqual(ok, linc_us5_flow:modify(?SWITCH_ID, FlowModAdd, #monitor_data{})),

    [#flow_entry{id=FlowId}] = linc_us5_flow:get_flow_table(?SWITCH_ID,
                                                            TableId),

    %% Increments flow counters
    PacketSize = 1024,
    ?assertEqual(ok, linc_us5_flow:update_match_counters(?SWITCH_ID,
                                                         TableId,
                                                         FlowId,
                                                         PacketSize)),

    FlowEntryCounters = linc:lookup(?SWITCH_ID, flow_entry_counters),
    [Stats] = ets:lookup(FlowEntryCounters, FlowId),
    ?assertMatch(#flow_entry_counter{received_packets=1,
                                     received_bytes=PacketSize},
                 Stats).

update_bad_match_counter() ->
    TableId = undefined,
    FlowId = undefined,
    PacketSize = 1024,
    ?assertEqual(ok, linc_us5_flow:update_match_counters(?SWITCH_ID,
                                                         TableId,
                                                         FlowId,PacketSize)),
    FlowEntryCounters = linc:lookup(?SWITCH_ID, flow_entry_counters),
    ?assertEqual([], ets:lookup(FlowEntryCounters, FlowId)).

empty_flow_stats() ->
    StatsReq = ofp_v5_utils:flow_stats(
                 [{table_id, 1}],
                 [{in_port,6}, {eth_dst,<<0,0,0,0,0,8>>}]),
    ?assertEqual(#ofp_flow_stats_reply{body=[]},
                 linc_us5_flow:get_stats(?SWITCH_ID, StatsReq)).

flow_stats_1_table() ->
    FlowModAdd1 = ofp_v5_utils:flow_add(
                    [{table_id,1}],
                    [{in_port,6}, {eth_dst,<<0,0,0,0,0,8>>}],
                    [{write_actions,[{group,3}]}]),
    ?assertEqual(ok, linc_us5_flow:modify(?SWITCH_ID, FlowModAdd1, #monitor_data{})),
    FlowModAdd2 = ofp_v5_utils:flow_add(
                    [{table_id,1}],
                    [{in_port,2}, {eth_dst,<<0,0,0,0,0,8>>}],
                    [{write_actions,[{group,3}]}]),
    ?assertEqual(ok, linc_us5_flow:modify(?SWITCH_ID, FlowModAdd2, #monitor_data{})),
    StatsReq = ofp_v5_utils:flow_stats(
                 [{table_id, 1}],
                 [{in_port,6}, {eth_dst,<<0,0,0,0,0,8>>}]),
    ?assertMatch(#ofp_flow_stats_reply{body=[#ofp_flow_stats{}]},
                 linc_us5_flow:get_stats(?SWITCH_ID, StatsReq)).

flow_stats_all_tables() ->
    FlowModAdd1 = ofp_v5_utils:flow_add(
                    [{table_id,1}],
                    [{in_port,6}, {eth_dst,<<0,0,0,0,0,8>>}],
                    [{write_actions,[{group,3}]}]),
    ?assertEqual(ok, linc_us5_flow:modify(?SWITCH_ID, FlowModAdd1, #monitor_data{})),
    FlowModAdd2 = ofp_v5_utils:flow_add(
                    [{table_id,2}],
                    [{in_port,6}, {eth_dst,<<0,0,0,0,0,8>>}],
                    [{write_actions,[{group,3}]}]),
    ?assertEqual(ok, linc_us5_flow:modify(?SWITCH_ID, FlowModAdd2, #monitor_data{})),
    StatsReq = ofp_v5_utils:flow_stats(
                 [{table_id, all}],
                 [{in_port,6}, {eth_dst,<<0,0,0,0,0,8>>}]),
    ?assertMatch(#ofp_flow_stats_reply{body=[#ofp_flow_stats{},
                                              #ofp_flow_stats{}]},
                 linc_us5_flow:get_stats(?SWITCH_ID, StatsReq)).

empty_aggr_stats() ->
    StatsReq = ofp_v5_utils:aggr_stats(
                 [{table_id, 1}],
                 [{in_port,6}, {eth_dst,<<0,0,0,0,0,8>>}]),
    ?assertEqual(#ofp_aggregate_stats_reply{packet_count=0,
                                            byte_count=0,
                                            flow_count=0},
                 linc_us5_flow:get_aggregate_stats(?SWITCH_ID, StatsReq)).

aggr_stats_1_table() ->
    TableId = 1,
    FlowModAdd1 = ofp_v5_utils:flow_add(
                    [{table_id,TableId}],
                    [{in_port,6}, {eth_dst,<<0,0,0,0,0,8>>}],
                    [{write_actions,[{group,3}]}]),
    ?assertEqual(ok, linc_us5_flow:modify(?SWITCH_ID, FlowModAdd1, #monitor_data{})),
    FlowModAdd2 = ofp_v5_utils:flow_add(
                    [{table_id,TableId}],
                    [{in_port,6}, {eth_dst,<<0,0,0,0,1,8>>}],
                    [{write_actions,[{group,3}]}]),
    ?assertEqual(ok, linc_us5_flow:modify(?SWITCH_ID, FlowModAdd2, #monitor_data{})),

    [#flow_entry{id=FlowId1},
     #flow_entry{id=FlowId2}] = linc_us5_flow:get_flow_table(?SWITCH_ID,
                                                             TableId),

    %% Increments flow counters
    PacketSize = 1024,
    ?assertEqual(ok, linc_us5_flow:update_match_counters(?SWITCH_ID,
                                                         TableId,
                                                         FlowId1,
                                                         PacketSize)),
    ?assertEqual(ok, linc_us5_flow:update_match_counters(?SWITCH_ID,
                                                         TableId,
                                                         FlowId2,
                                                         PacketSize)),
    %% This will only match one of the flows
    StatsReq = ofp_v5_utils:aggr_stats(
                 [{table_id, TableId}],
                 [{in_port,6}, {eth_dst,<<0,0,0,0,0,8>>}]),
    ?assertEqual(#ofp_aggregate_stats_reply{packet_count=1,
                                            byte_count=1024,
                                            flow_count=1},
                 linc_us5_flow:get_aggregate_stats(?SWITCH_ID, StatsReq)).

aggr_stats_all_tables() ->
    FlowModAdd1 = ofp_v5_utils:flow_add(
                    [{table_id,1}],
                    [{in_port,6}, {eth_dst,<<0,0,0,0,0,8>>}],
                    [{write_actions,[{group,3}]}]),
    ?assertEqual(ok, linc_us5_flow:modify(?SWITCH_ID, FlowModAdd1, #monitor_data{})),
    FlowModAdd2 = ofp_v5_utils:flow_add(
                    [{table_id,2}],
                    [{in_port,6}, {eth_dst,<<0,0,0,0,0,8>>}],
                    [{write_actions,[{group,3}]}]),
    ?assertEqual(ok, linc_us5_flow:modify(?SWITCH_ID, FlowModAdd2, #monitor_data{})),

    [#flow_entry{id=FlowId1}] = linc_us5_flow:get_flow_table(?SWITCH_ID, 1),
    [#flow_entry{id=FlowId2}] = linc_us5_flow:get_flow_table(?SWITCH_ID, 2),

    %% Increments flow counters
    PacketSize = 1024,
    ?assertEqual(ok, linc_us5_flow:update_match_counters(?SWITCH_ID,
                                                         1,
                                                         FlowId1,
                                                         PacketSize)),
    ?assertEqual(ok, linc_us5_flow:update_match_counters(?SWITCH_ID,
                                                         2,
                                                         FlowId2,
                                                         PacketSize)),
    %% This will matchboth flows
    StatsReq = ofp_v5_utils:aggr_stats(
                 [{table_id, all}],
                 [{in_port,6}, {eth_dst,<<0,0,0,0,0,8>>}]),
    ?assertEqual(#ofp_aggregate_stats_reply{packet_count=2,
                                            byte_count=2048,
                                            flow_count=2},
                 linc_us5_flow:get_aggregate_stats(?SWITCH_ID, StatsReq)).

empty_table_stats() ->
    ?assertMatch(#ofp_table_stats_reply{body=[#ofp_table_stats{}|_]},
                 linc_us5_flow:get_table_stats(?SWITCH_ID,
                                               #ofp_table_stats_request{})).

timer_test_() ->
    {setup, fun setup/0, fun teardown/1,
     {foreach, fun foreach_setup/0, fun foreach_teardown/1,
      [{"Idle timeout", fun idle_timeout/0}
       ,{"Hard timeout", fun hard_timeout/0}
      ]}}.

idle_timeout() ->
    FlowModAdd1 = ofp_v5_utils:flow_add(
                    [{table_id,1},
                     {idle_timeout,1}],
                    [{in_port,6}, {eth_dst,<<0,0,0,0,0,8>>}],
                    [{write_actions,[{group,3}]}]),
    ?assertEqual(ok, linc_us5_flow:modify(?SWITCH_ID, FlowModAdd1, #monitor_data{})),
    [#flow_entry{id=FlowId}] = linc_us5_flow:get_flow_table(?SWITCH_ID, 1),
    timer:sleep(100),
    [#flow_entry{id=FlowId}] = linc_us5_flow:get_flow_table(?SWITCH_ID, 1),
    ok = linc_us5_flow:reset_idle_timeout(?SWITCH_ID, FlowId),
    timer:sleep(100),
    ?assertMatch([#flow_entry{id=FlowId}],
                 linc_us5_flow:get_flow_table(?SWITCH_ID, 1)),
    timer:sleep(2500),
    ?assertEqual([], linc_us5_flow:get_flow_table(?SWITCH_ID, 1)).

hard_timeout() ->
    FlowModAdd1 = ofp_v5_utils:flow_add(
                    [{table_id,1},
                     {hard_timeout,1}],
                    [{in_port,6}, {eth_dst,<<0,0,0,0,0,8>>}],
                    [{write_actions,[{group,3}]}]),
    ?assertEqual(ok, linc_us5_flow:modify(?SWITCH_ID, FlowModAdd1, #monitor_data{})),
    ?assertMatch([#flow_entry{}], linc_us5_flow:get_flow_table(?SWITCH_ID, 1)),
    timer:sleep(2500),
    ?assertEqual([], linc_us5_flow:get_flow_table(?SWITCH_ID, 1)).

%% Fixtures --------------------------------------------------------------------
setup() ->
    linc_us5_test_utils:add_logic_path(),
    linc:create(?SWITCH_ID),
    linc_us5_test_utils:mock(?MOCKED),
    {ok, Pid} = linc_us5_flow:start_link(?SWITCH_ID),
    Pid.

teardown(Pid) ->
    unlink(Pid),
    exit(Pid, kill),
    linc:delete(?SWITCH_ID),
    linc_us5_test_utils:unmock(?MOCKED).

foreach_setup() ->
    linc_us5_flow:initialize(?SWITCH_ID).

foreach_teardown(State) ->
    linc_us5_flow:terminate(State).

%% Helpers ---------------------------------------------------------------------

%% Quickcheck properties -------------------------------------------------------
-ifdef(EQC).
bundle_equivalent_test_() ->
    {timeout, 600, ?_assertEqual(true, eqc:counterexample(prop_bundle_equivalent()))}.

%% Test that sending flow mods one by one is equivalent to sending
%% them in a bundle.
prop_bundle_equivalent() ->
    ?FORALL(
       FlowMods, list(flow_mod()),
       begin
           Pid1 = setup(),
           State1 = foreach_setup(),
           Ref1 = monitor(process, Pid1),
           unlink(Pid1),
           Result1 = (catch modify_individually(FlowMods)),
           foreach_teardown(State1),

           State2 = foreach_setup(),
           Result2 = (catch modify_bundle(FlowMods)),
           foreach_teardown(State2),
           teardown(Pid1),
           receive {'DOWN', Ref1, _, _, Reason} -> ok end,

           conjunction(
             [{no_crash, equals(killed, Reason)},
              {flow_tables, compare_flow_tables(Result1, Result2)}])
       end).

modify_individually([]) ->
    [begin
         ?assertNotEqual({TableId, undefined}, {TableId, linc_us5_flow:flow_table_ets(?SWITCH_ID, TableId)}),
         catch linc_us5_flow:get_flow_table(?SWITCH_ID, TableId)
     end
     || TableId <- lists:seq(0, ?OFPTT_MAX)];
modify_individually([FlowMod | Rest]) ->
    case linc_us5_flow:modify(?SWITCH_ID, FlowMod, #monitor_data{}) of
        ok ->
            modify_individually(Rest);
        {error, _} = Error ->
            Error
    end.

modify_bundle(FlowMods) ->
    Messages = [#ofp_message{body = FlowMod} || FlowMod <- FlowMods],
    case linc_us5_flow:bundle(?SWITCH_ID, Messages, #monitor_data{}) of
        ok ->
            [linc_us5_flow:get_flow_table(?SWITCH_ID, TableId)
             || TableId <- lists:seq(0, ?OFPTT_MAX)];
        {error, [#ofp_message{body = #ofp_error_msg{type = Type, code = Code}} | _]} ->
            %% Ignore errors beyond the first
            {error, {Type, Code}}
    end.

compare_flow_tables({error, Error1}, {error, Error2}) ->
    equals(Error1, Error2);
compare_flow_tables([_|_] = Tables1, [_|_] = Tables2) ->
    conjunction(
      lists:zipwith3(
        fun(TableId, Flows1, Flows2) ->
                {list_to_atom(integer_to_list(TableId)),
                 compare_flow_entries(Flows1, Flows2)}
        end, lists:seq(0, ?OFPTT_MAX), Tables1, Tables2));
compare_flow_tables(A, B) ->
    %% different types
    equals(A, B).

compare_flow_entries(Flows1, Flows2) ->
    ?WHENFAIL(
       io:format("~p~n /=~n~p~n", [Flows1, Flows2]),
       length(Flows1) =:= length(Flows2) andalso
       lists:all(fun compare_flow_entry_pair/1, lists:zip(Flows1, Flows2))).

compare_flow_entry_pair({#flow_entry{
                            priority = Priority,
                            match = Match,
                            cookie = Cookie,
                            flags = Flags,
                            instructions = Instructions},
                         #flow_entry{
                            priority = Priority,
                            match = Match,
                            cookie = Cookie,
                            flags = Flags,
                            instructions = Instructions}}) ->
    true;
compare_flow_entry_pair({#flow_entry{}, #flow_entry{}}) ->
    false.

%%% Flow mod generation
flow_mod() ->
    #ofp_flow_mod{cookie = default(<<"cookie01">>, nbinary(8)),
                  cookie_mask = default(<<-1:64>>, nbinary(8)),
                  table_id = default(0, table_id()),
                  command = flow_mod_command(),
                  idle_timeout = uint16(),
                  hard_timeout = uint16(),
                  priority = uint16(),
                  buffer_id = uint32(),
                  out_port = port_no(),
                  out_group = group_id(),
                  flags = ulist(flow_mod_flag()),
                  match = match(),
                  instructions = ulist(instruction())}.

flow_mod_command() ->
    frequency([{10, add},
               {1, modify},
               {1, modify_strict},
               {1, delete},
               {1, delete_strict}]).

flow_mod_flag() ->
    oneof([send_flow_rem,
           check_overlap,
           reset_counts,
           no_pkt_counts,
           no_byt_counts]).

%%% Instruction generation
instruction() ->
    oneof([instruction_goto_table(),
           instruction_write_metadata(),
           instruction_write_actions(),
           instruction_apply_actions(),
           instruction_clear_actions(),
           instruction_meter(),
           instruction_experimenter()]).

instruction_goto_table() ->
    #ofp_instruction_goto_table{table_id = uint8()}.

instruction_write_metadata() ->
    #ofp_instruction_write_metadata{metadata = nbinary(8),
                                    metadata_mask = nbinary(8)}.

instruction_write_actions() ->
    #ofp_instruction_write_actions{actions = ulist(action())}.

instruction_apply_actions() ->
    #ofp_instruction_apply_actions{actions = ulist(action())}.

instruction_clear_actions() ->
    #ofp_instruction_clear_actions{}.

instruction_meter() ->
    #ofp_instruction_meter{meter_id = meter_id()}.

instruction_experimenter() ->
    #ofp_instruction_experimenter{experimenter = uint32(),
                                  data = binary()}.

%%% Match generation
match() ->
    #ofp_match{fields = ukeylist(#ofp_field.name, field())}.

field() ->
    ?LET(Class, field_class(),
         ?LET(Name, field_name(Class),
              ?LET(LengthInBits, field_length(Class, Name),
                   ?LET(HasMask, field_has_mask(Class, Name),
                        #ofp_field{class = Class,
                                   name = Name,
                                   has_mask = HasMask,
                                   value = nbitstring(LengthInBits),
                                   mask = field_mask(HasMask, LengthInBits)})))).

field_class() ->
    openflow_basic.

field_name(openflow_basic) ->
    oneof([in_port,
%%% Validation fails for in_phy_port:
%%%               in_phy_port,
               metadata,
               eth_dst,
               eth_src,
               eth_type,
               vlan_vid,
               vlan_pcp,
               ip_dscp,
               ip_ecn,
               ip_proto,
               ipv4_src,
               ipv4_dst,
               tcp_src,
               tcp_dst,
               udp_src,
               udp_dst,
               sctp_src,
               sctp_dst,
               icmpv4_type,
               icmpv4_code,
               arp_op,
               arp_spa,
               arp_tpa,
               arp_sha,
               arp_tha,
               ipv6_src,
               ipv6_dst,
               ipv6_flabel,
               icmpv6_type,
               icmpv6_code,
               ipv6_nd_target,
               ipv6_nd_sll,
               ipv6_nd_tll,
               mpls_label,
               mpls_tc,
               mpls_bos,
               pbb_isid,
               tunnel_id,
               ipv6_exthdr,
               pbb_uca]);
field_name(_) ->
    bad_name.

field_length(openflow_basic, Field) when Field =/= bad_name ->
    ofp_v5_map:tlv_length(Field);
field_length(_, _) ->
    choose(0, 64).

field_has_mask(openflow_basic, Field) when Field == metadata;
                                           Field == eth_dst;
                                           Field == eth_src;
                                           Field == vlan_vid;
                                           Field == ipv4_src;
                                           Field == ipv4_dst;
                                           Field == arp_spa;
                                           Field == arp_tpa;
                                           Field == arp_sha;
                                           Field == arp_tha;
                                           Field == ipv6_src;
                                           Field == ipv6_dst;
                                           Field == ipv6_flabel;
                                           Field == pbb_isid;
                                           Field == tunnel_id;
                                           Field == ipv6_exthdr ->
    bool();
field_has_mask(openflow_basic, _) ->
    false;
field_has_mask(_, _) ->
    bool().

field_mask(true, LengthInBits) ->
    nbitstring(LengthInBits);
field_mask(false, _) ->
    undefined.

%%% Action generation
action() ->
    oneof([action_output(),
           action_copy_ttl_out(),
           action_copy_ttl_in(),
           action_set_mpls_ttl(),
           action_dec_mpls_ttl(),
           action_push_vlan(),
           action_pop_vlan(),
           action_push_mpls(),
           action_pop_mpls(),
           action_set_queue(),
           action_group(),
           action_set_nw_ttl(),
           action_dec_nw_ttl(),
           action_set_field(),
           %% These don't validate:
           %% action_push_pbb(),
           %% action_pop_pbb(),
           action_experimenter()]).

action_output() ->
    #ofp_action_output{port = port_no(),
                       max_len = controller_max_length()}.

action_copy_ttl_out() ->
    #ofp_action_copy_ttl_out{}.

action_copy_ttl_in() ->
    #ofp_action_copy_ttl_in{}.

action_set_mpls_ttl() ->
    #ofp_action_set_mpls_ttl{mpls_ttl = uint8()}.

action_dec_mpls_ttl() ->
    #ofp_action_dec_mpls_ttl{}.

action_push_vlan() ->
    #ofp_action_push_vlan{ethertype = uint16()}.

action_pop_vlan() ->
    #ofp_action_pop_vlan{}.

action_push_mpls() ->
    #ofp_action_push_mpls{ethertype = uint16()}.

action_pop_mpls() ->
    #ofp_action_pop_mpls{ethertype = uint16()}.

action_set_queue() ->
    #ofp_action_set_queue{queue_id = queue_id()}.

action_group() ->
    #ofp_action_group{group_id = group_id()}.

action_set_nw_ttl() ->
    #ofp_action_set_nw_ttl{nw_ttl = uint8()}.

action_dec_nw_ttl() ->
    #ofp_action_dec_nw_ttl{}.

action_set_field() ->
    #ofp_action_set_field{field = field()}.

%% action_push_pbb() ->
%%     #ofp_action_push_pbb{ethertype = uint16()}.

%% action_pop_pbb() ->
%%     #ofp_action_pop_pbb{}.

action_experimenter() ->
    #ofp_action_experimenter{experimenter = uint32()}.

%%% Miscellaneous
port_no() ->
    frequency([{8, uint32()},
               {2, oneof([in_port,
                          table,
                          normal,
                          flood,
                          all,
                          controller,
                          local,
                          any])}]).

table_id() ->
    frequency([{4, choose(0, ?OFPTT_MAX)},
               {1, oneof([all])}]).

group_id() ->
    frequency([{19, uint32()},
               {1, oneof([any,
                          all])}]).

queue_id() ->
    frequency([{4, uint32()},
               {1, oneof([all])}]).

meter_id() ->
    frequency([{4, uint32()},
               {1, oneof([all])}]).

controller_max_length() ->
    frequency([{19, uint16()},
               {1, oneof([no_buffer])}]).

%%% Basic data types
uint8() ->
    choose(0, 255).

uint16() ->
    choose(0, 65535).

uint32() ->
    choose(0, 4294967295).

nbinary(ByteSize) ->
    noshrink(binary(ByteSize)).

nbitstring(BitSize) ->
    noshrink(bitstring(BitSize)).

ulist(Gen) ->
    ?LET(List, list(Gen), lists:usort(List)).

ukeylist(KeyPos, Gen) ->
    ?LET(List, list(Gen), lists:ukeysort(KeyPos, List)).

-endif.
