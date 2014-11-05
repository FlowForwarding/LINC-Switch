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
-module(linc_us4_oe_flow_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("of_protocol/include/of_protocol.hrl").
-include_lib("of_protocol/include/ofp_v4.hrl").
-include_lib("linc_us4_oe/include/linc_us4_oe.hrl").

-define(MOCKED, [logic,group,port,meter]).
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
       ,{"Prerequisite field can have any value", fun prerequisite_field_can_have_any_value/0}
       ,{"Goto table with smaller table_id", fun goto_backwards/0}
       ,{"Invalid in port", fun invalid_in_port/0}
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
       ,{"Add flow with an incompatible value/mask pair in the match",
         fun incompatible_value_mask_pair_in_match/0}
       ,{"OE, delete flow with match containing fields from infoblox class",
         fun oe_delete_with_fields_from_infoblox_class/0}
      ]}}.

bad_table_id() ->
    %% Create flow_mod record
    FlowModAdd = ofp_v4_utils:flow_add(
                   [{table_id,all},
                    {priority,5},
                    {flags,[]}],
                   [{in_port,6},{in_port,6}],
                   [{write_actions,[{output,15,1400}]}]),
    %% Add flow
    ?assertEqual({error,{flow_mod_failed,bad_table_id}},
                 linc_us4_oe_flow:modify(?SWITCH_ID, FlowModAdd)).

duplicate_field() ->
    %% Create flow_mod record
    FlowModAdd = ofp_v4_utils:flow_add(
                   [{table_id,0},
                    {priority,5},
                    {flags,[]}],
                   [{in_port,6},{in_port,6}],
                   [{write_actions,[{output,15,1400}]}]),
    %% Add flow
    ?assertEqual({error,{bad_match,dup_field}},
                 linc_us4_oe_flow:modify(?SWITCH_ID, FlowModAdd)).

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
    ?assertEqual(ok, linc_us4_oe_flow:modify(?SWITCH_ID, FlowModAdd)).

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
                 linc_us4_oe_flow:modify(?SWITCH_ID, FlowModAdd)).

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
                 linc_us4_oe_flow:modify(?SWITCH_ID, FlowModAdd)).

prerequisite_field_can_have_any_value() ->
    [begin
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
                                        class = infoblox,
                                        name = och_sigtype,
                                        value = <<SigType>>},
                                     #ofp_field{
                                        class = infoblox,
                                        name = och_sigid,
                                        value = <<111:48>>}]},
                         instructions =
                             [#ofp_instruction_write_actions{
                                 actions =
                                     [#ofp_action_output{port = 15,
                                                         max_len = 1400}]}]},
         ?assertEqual(ok, linc_us4_oe_flow:modify(?SWITCH_ID, FlowModAdd))
     end || SigType <- lists:seq(1,10)].

%% Goto a table with smaller table_id
goto_backwards() ->
    FlowModAdd = ofp_v4_utils:flow_add(
                   [{table_id,5},
                    {priority,5},
                    {flags,[]}],
                   [{in_port,6}],
                   [{goto_table,2}]),
    ?assertEqual({error,{bad_action,bad_table_id}},
                 linc_us4_oe_flow:modify(?SWITCH_ID, FlowModAdd)).

invalid_in_port() ->
    FlowModAdd = ofp_v4_utils:flow_add(
                   [{table_id,0},
                    {priority,5},
                    {flags,[]}],
                   [{in_port, _Over33IsInvalid = 33}],
                   [{write_actions,[{output,15,1400}]}]),
    ?assertEqual({error, {bad_match, bad_value}},
                 linc_us4_oe_flow:modify(?SWITCH_ID, FlowModAdd)).

valid_out_port() ->
    %% Create flow_mod record
    FlowModAdd = ofp_v4_utils:flow_add(
                   [{table_id,0},
                    {priority,5},
                    {flags,[]}],
                   [{in_port,6}],
                   [{write_actions,[{output,15,1400}]}]),
    ?assertEqual(ok, linc_us4_oe_flow:modify(?SWITCH_ID, FlowModAdd)).

invalid_out_port() ->
    %% Create flow_mod record
    FlowModAdd = ofp_v4_utils:flow_add(
                   [{table_id,0},
                    {priority,5},
                    {flags,[]}],
                   [{in_port,6}],
                   [{write_actions,[{output,33,1400}]}]),
    ?assertEqual({error,{bad_action,bad_out_port}},
                 linc_us4_oe_flow:modify(?SWITCH_ID, FlowModAdd)).

valid_out_group() ->
    %% Create flow_mod record
    FlowModAdd = ofp_v4_utils:flow_add(
                   [{table_id,0},
                    {priority,5},
                    {flags,[]}],
                   [{in_port,6}],
                   [{write_actions,[{group,1}]}]),
    ?assertEqual(ok,
                 linc_us4_oe_flow:modify(?SWITCH_ID, FlowModAdd)).

invalid_out_group() ->
    %% Create flow_mod record
    FlowModAdd = ofp_v4_utils:flow_add(
                   [{table_id,0},
                    {priority,5},
                    {flags,[]}],
                   [{in_port,6}],
                   [{write_actions,[{group,33}]}]),
    ?assertEqual({error,{bad_action,bad_out_group}},
                 linc_us4_oe_flow:modify(?SWITCH_ID, FlowModAdd)).

invalid_meter() ->
    %% Create flow_mod record
    FlowModAdd = ofp_v4_utils:flow_add(
                   [{table_id,0},
                    {priority,5},
                    {flags,[]}],
                   [{in_port,6}],
                   [{meter,9}]),
    ?assertEqual({error,{bad_instruction,unsup_inst}},
                 linc_us4_oe_flow:modify(?SWITCH_ID, FlowModAdd)).

valid_meter() ->
    %% Create flow_mod record
    FlowModAdd = ofp_v4_utils:flow_add(
                   [{table_id,0},
                    {priority,5},
                    {flags,[]}],
                   [{in_port,6}],
                   [{meter,4}]),
    ?assertEqual(ok,
                 linc_us4_oe_flow:modify(?SWITCH_ID, FlowModAdd)).

dupl_instruction() ->
    %% FIXME: The spec 1.2 does not specify an error for this case.
    %% So for now we return this {bad_instruction, unknown_inst}.
    FlowModAdd = ofp_v4_utils:flow_add(
                   [{table_id,5},
                    {priority,5},
                    {flags,[]}],
                   [{in_port,6},{eth_type,<<8,0>>},{udp_src,<<8,0>>}],
                   [{write_actions,[{set_field,tcp_dst,<<8,0>>}]},
                    {write_actions,[{set_field,tcp_dst,<<8,0>>}]}]),
    ?assertEqual({error,{bad_instruction, unknown_inst}},
                 linc_us4_oe_flow:modify(?SWITCH_ID, FlowModAdd)).

%% Match un UDP, but action tries to change a TCP field
incompatible_set_field() ->
    FlowModAdd = ofp_v4_utils:flow_add(
                   [{table_id,5},
                    {priority,5},
                    {flags,[]}],
                   [{in_port,6},{eth_type,<<8,0>>},{udp_src,<<8,0>>}],
                   [{write_actions,[{set_field,tcp_dst,<<8,0>>}]}]),
    ?assertEqual({error,{bad_action,bad_argument}},
                 linc_us4_oe_flow:modify(?SWITCH_ID, FlowModAdd)).

%% Add one flow, in an empty table, this should always succeed.
add_flow(TableId, Flags) ->
    Priority=5,
    %% Create flow_mod record
    FlowModAdd = ofp_v4_utils:flow_add(
                   [{table_id,TableId},
                    {priority,Priority},
                    {flags,Flags}],
                   [{in_port,6}, {eth_dst,<<0,0,0,0,0,8>>,<<0,0,0,0,0,15>>}],
                   [{write_actions,[{output,15,1400}]}]),
    ?assertEqual(ok, linc_us4_oe_flow:modify(?SWITCH_ID, FlowModAdd)),

    %% Check if the flow was added correctly...
    #ofp_flow_mod{match=Match,
                  instructions=Instructions} = FlowModAdd,

    [#flow_entry{id=Id,
                 match=Match1,
                 instructions=Instructions1}] =
        linc_us4_oe_flow:get_flow_table(?SWITCH_ID, TableId),

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
    FlowModAdd1 = ofp_v4_utils:flow_add(
                    [{table_id,TableId},
                     {priority,Priority},
                     {flags,Flags}],
                    [{in_port,6}, {eth_dst,<<0,0,0,0,0,8>>}],
                    [{write_actions,[{output,15,1400}]}]),

    FlowModAdd2 = ofp_v4_utils:flow_add(
                    [{table_id,TableId},
                     {priority,Priority},
                     {flags,Flags}],
                    [{in_port,6}, {eth_dst,<<0,0,0,0,0,9>>}],
                    [{write_actions,[{output,15,1400}]}]),
    %% Add flows
    ?assertEqual(ok, linc_us4_oe_flow:modify(?SWITCH_ID, FlowModAdd1)),
    ?assertEqual(ok, linc_us4_oe_flow:modify(?SWITCH_ID, FlowModAdd2)),

    %% Check if the flows were added correctly...
    #ofp_flow_mod{match=Match1,
                  instructions=Instructions1} = FlowModAdd1,
    #ofp_flow_mod{match=Match2,
                  instructions=Instructions2} = FlowModAdd2,

    [#flow_entry{match=GotMatch1, instructions=GotInstructions1},
     #flow_entry{match=GotMatch2, instructions=GotInstructions2}] =
        linc_us4_oe_flow:get_flow_table(?SWITCH_ID, TableId),
    ?assertEqual(lists:sort([{Match1,Instructions1},{Match2, Instructions2}]),
                 lists:sort([{GotMatch1,GotInstructions1},{GotMatch2, GotInstructions2}])).

%% Add two overlapping, but not exact, flows, without the check_overlap flag set,
%% this should succeed.
add_overlapping_flows() ->
    TableId = 2,
    Priority=5,
    Flags = [],
    %% Create flow_mod record
    FlowModAdd1 = ofp_v4_utils:flow_add(
                    [{table_id,TableId},
                     {priority,Priority},
                     {flags,Flags}],
                    [{in_port,6}, {eth_dst,<<0,0,0,0,0,7>>,<<0,0,0,0,0,15>>}],
                    [{write_actions,[{output,15,1400}]}]),

    FlowModAdd2 = ofp_v4_utils:flow_add(
                    [{table_id,TableId},
                     {priority,Priority},
                     {flags,Flags}],
                    [{in_port,6}, {eth_dst,<<0,0,0,0,0,9>>,<<0,0,0,0,0,31>>}],
                    [{write_actions,[{output,15,1400}]}]),
    %% Add flows
    ?assertEqual(ok, linc_us4_oe_flow:modify(?SWITCH_ID, FlowModAdd1)),
    ?assertEqual(ok, linc_us4_oe_flow:modify(?SWITCH_ID, FlowModAdd2)),

    %% Check if the flows were added correctly...
    #ofp_flow_mod{match=Match1,
                  instructions=Instructions1} = FlowModAdd1,
    #ofp_flow_mod{match=Match2,
                  instructions=Instructions2} = FlowModAdd2,

    [#flow_entry{match=GotMatch1,
                 instructions=GotInstructions1},
     #flow_entry{match=GotMatch2,
                 instructions=GotInstructions2}]
        = linc_us4_oe_flow:get_flow_table(?SWITCH_ID, TableId),
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
    FlowModAdd1 = ofp_v4_utils:flow_add(
                    [{table_id,TableId},
                     {priority,Priority},
                     {flags,Flags}],
                    [{in_port,6}, {eth_dst,<<0,0,0,0,0,16#7>>,<<0,0,0,0,0,16#0F>>}],
                    [{write_actions,[{output,15,1400}]}]),

    FlowModAdd2 = ofp_v4_utils:flow_add(
                    [{table_id,TableId},
                     {priority,Priority},
                     {flags,Flags}],
                    [{in_port,6}, {eth_dst,<<0,0,0,0,0,16#17>>,<<0,0,0,0,0,16#1F>>}],
                    [{write_actions,[{output,15,1400}]}]),
    %% Add flows
    ?assertEqual(ok, linc_us4_oe_flow:modify(?SWITCH_ID, FlowModAdd1)),
    ?assertEqual({error,{flow_mod_failed,overlap}},
                 linc_us4_oe_flow:modify(?SWITCH_ID, FlowModAdd2)),

    %% Check that flow_removed has not been sent
    %% FIXME: Cannot mock linc_logic module that belongs to another application
    %% ?assertEqual(false,linc_us4_oe_test_utils:check_if_called({linc_logic,send_to_controllers,1})),
    %% Check that the the overlapping flow was not added
    #ofp_flow_mod{match=Match1,
                  instructions=Instructions1} = FlowModAdd1,

    ?assertMatch([#flow_entry{match=Match1,
                              instructions=Instructions1}],
                 linc_us4_oe_flow:get_flow_table(?SWITCH_ID, TableId)).

add_exact_flow(Flags) ->
    TableId = 4,
    Priority = 6,
    Match = [{in_port,6}, {eth_dst,<<0,0,0,0,0,16#7>>}],

    Instructions1 = [{write_actions,[{output,15,1400}]}],
    %% Create flow_mod record
    FlowModAdd1 = ofp_v4_utils:flow_add(
                    [{table_id,TableId},
                     {priority,Priority},
                     {flags,Flags}],
                    Match,
                    Instructions1
                   ),

    Instructions2 = [{write_actions,[{output,32,1400}]}],
    FlowModAdd2 = ofp_v4_utils:flow_add(
                    [{table_id,TableId},
                     {priority,Priority},
                     {flags,Flags}],
                    Match,
                    Instructions2),

    %% Add first flow
    ?assertEqual(ok, linc_us4_oe_flow:modify(?SWITCH_ID, FlowModAdd1)),
    %% Get FlowId
    [#flow_entry{id=FlowId1}] = linc_us4_oe_flow:get_flow_table(?SWITCH_ID,
                                                             TableId),

    %% Increments flow counters
    PacketSize = 1024,
    linc_us4_oe_flow:update_match_counters(?SWITCH_ID, TableId,
                                        FlowId1, PacketSize),

    %% Check that counters are updated
    FlowEntryCounters = linc:lookup(?SWITCH_ID, flow_entry_counters),
    [#flow_entry_counter{
        id=FlowId1,
        received_packets=1,
        received_bytes=PacketSize}] = ets:lookup(FlowEntryCounters, FlowId1),

    %% Add second flow
    ?assertEqual(ok, linc_us4_oe_flow:modify(?SWITCH_ID, FlowModAdd2)),

    %% Check that the the new flow has replaced the previous one
    #ofp_flow_mod{match=M1,
                  instructions=I1} = FlowModAdd2,

    [#flow_entry{id = FlowId2,
                 match = M2,
                 instructions = I2}] = linc_us4_oe_flow:get_flow_table(?SWITCH_ID,
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
    FlowModAdd1 = ofp_v4_utils:flow_add(
                    [{table_id,TableId},
                     {priority,100},
                     {flags,[]}],
                    [{in_port,6}, {eth_dst,<<0,0,0,0,0,8>>}],
                    [{write_actions,[{output,15,1400}]}]),

    FlowModAdd2 = ofp_v4_utils:flow_add(
                    [{table_id,TableId},
                     {priority,200},
                     {flags,[]}],
                    [{in_port,6}, {eth_dst,<<0,0,0,0,0,9>>}],
                    [{write_actions,[{output,5,1400}]}]),
    %% Add flows
    ?assertEqual(ok, linc_us4_oe_flow:modify(?SWITCH_ID, FlowModAdd1)),
    ?assertEqual(ok, linc_us4_oe_flow:modify(?SWITCH_ID, FlowModAdd2)),

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
                 linc_us4_oe_flow:get_flow_table(?SWITCH_ID, TableId)).

modify_strict(Flags) ->
    TableId = 4,
    Priority = 6,
    Match = [{in_port,6}, {eth_dst,<<0,0,0,0,0,16#7>>}],

    Instructions1 = [{write_actions,[{output,15,1400}]}],
    %% Create flow_mod record
    FlowModAdd1 = ofp_v4_utils:flow_add(
                    [{table_id,TableId},
                     {priority,Priority},
                     {flags,[]}],
                    Match,
                    Instructions1
                   ),

    Instructions2 = [{write_actions,[{output,32,1400}]}],
    FlowMod = ofp_v4_utils:flow_modify(modify_strict,
                                       [{table_id,TableId},
                                        {priority,Priority},
                                        {flags,Flags}],
                                       Match,
                                       Instructions2),

    %% Add first flow
    ?assertEqual(ok, linc_us4_oe_flow:modify(?SWITCH_ID, FlowModAdd1)),
    %% Get FlowId
    [#flow_entry{id=FlowId}] = linc_us4_oe_flow:get_flow_table(?SWITCH_ID,
                                                            TableId),

    %% Increments flow counters
    PacketSize = 1024,
    linc_us4_oe_flow:update_match_counters(?SWITCH_ID, TableId,
                                        FlowId, PacketSize),

    %% Check that counters are updated
    FlowEntryCounters = linc:lookup(?SWITCH_ID, flow_entry_counters),
    ?assertMatch([#flow_entry_counter{
                     id=FlowId,
                     received_packets=1,
                     received_bytes=PacketSize}],
                 ets:lookup(FlowEntryCounters, FlowId)),

    %% Modify flow
    ?assertEqual(ok, linc_us4_oe_flow:modify(?SWITCH_ID, FlowMod)),

    %% Check that the the new flow has replaced the previous one
    #ofp_flow_mod{match=M1, instructions=I1} = FlowMod,

    ?assertMatch([#flow_entry{id=FlowId, match = M1, instructions = I1}],
                 linc_us4_oe_flow:get_flow_table(?SWITCH_ID, TableId)),

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
    FlowModAdd1 = ofp_v4_utils:flow_add([{table_id,TableId},
                                         {cookie,<<2:64>>},
                                         {priority,Priority},
                                         {flags,[]}],
                                        Match,
                                        [{write_actions,[{output,15,1400}]}]
                                       ),
    FlowMod = ofp_v4_utils:flow_modify(modify,
                                       [{table_id,TableId},
                                        {cookie,<<4:64>>},
                                        {cookie_mask,<<4:64>>},
                                        {priority,Priority},
                                        {flags,[]}],
                                       Match,
                                       [{write_actions,[{output,32,1400}]}]),

    %% Add first flow
    ?assertEqual(ok, linc_us4_oe_flow:modify(?SWITCH_ID, FlowModAdd1)),
    ?assertMatch([#flow_entry{}], linc_us4_oe_flow:get_flow_table(?SWITCH_ID,
                                                               TableId)),

    %% Modify flow
    ?assertEqual(ok, linc_us4_oe_flow:modify(?SWITCH_ID, FlowMod)),

    %% Check that the the flow was not modified
    #ofp_flow_mod{match=M1,
                  instructions=I1} = FlowModAdd1,

    ?assertMatch([#flow_entry{match = M1,
                              instructions = I1}],
                 linc_us4_oe_flow:get_flow_table(?SWITCH_ID, TableId)).

modify_cookie_match() ->
    TableId = 4,
    Priority = 6,
    Match = [{in_port,6}, {eth_dst,<<0,0,0,0,0,16#7>>}],

    Instructions1 = [{write_actions,[{output,15,1400}]}],
    %% Create flow_mod record
    FlowModAdd1 = ofp_v4_utils:flow_add(
                    [{table_id,TableId},
                     {cookie,<<4:64>>},
                     {priority,Priority},
                     {flags,[]}],
                    Match,
                    Instructions1
                   ),

    Instructions2 = [{write_actions,[{output,32,1400}]}],
    FlowModAdd2 = ofp_v4_utils:flow_modify(
                    modify,
                    [{table_id,TableId},
                     {cookie,<<4:64>>},
                     {cookie_mask,<<4:64>>},
                     {priority,Priority},
                     {flags,[]}],
                    Match,
                    Instructions2),

    %% Add first flow
    ?assertEqual(ok, linc_us4_oe_flow:modify(?SWITCH_ID, FlowModAdd1)),

    ?assertMatch([#flow_entry{}], linc_us4_oe_flow:get_flow_table(?SWITCH_ID,
                                                               TableId)),

    %% Modify flow
    ?assertEqual(ok, linc_us4_oe_flow:modify(?SWITCH_ID, FlowModAdd2)),

    %% Check that the the flow was modified
    #ofp_flow_mod{match=M,
                  instructions=I} = FlowModAdd2,

    ?assertMatch([#flow_entry{match = M,
                              instructions = I}],
                 linc_us4_oe_flow:get_flow_table(?SWITCH_ID, TableId)).

delete_strict() ->
    TableId = 4,
    Priority = 6,
    Match = [{in_port,6}, {eth_dst,<<0,0,0,0,0,16#7>>}],
    %% Create flow_mod record
    FlowModAdd1 = ofp_v4_utils:flow_add(
                    [{table_id,TableId},
                     {priority,Priority},
                     {flags,[]}],
                    Match,
                    [{write_actions,[{output,15,1400}]}]
                   ),

    FlowDel = ofp_v4_utils:flow_delete(
                delete_strict,
                [{table_id,TableId},
                 {priority,Priority},
                 {flags,[]}],
                Match),

    %% Add flow
    ?assertEqual(ok, linc_us4_oe_flow:modify(?SWITCH_ID, FlowModAdd1)),
    %% Check that flow was added
    [#flow_entry{}] = linc_us4_oe_flow:get_flow_table(?SWITCH_ID, TableId),
    %% Delete flow
    ?assertEqual(ok, linc_us4_oe_flow:modify(?SWITCH_ID, FlowDel)),
    %% Check that flow was deleted
    ?assertEqual([], linc_us4_oe_flow:get_flow_table(?SWITCH_ID, TableId)).

delete_cookie_no_match() ->
    TableId = 4,
    Priority = 6,
    Match = [{in_port,6}, {eth_dst,<<0,0,0,0,0,16#7>>}],

    Instructions1 = [{write_actions,[{output,15,1400}]}],
    %% Create flow_mod record
    FlowModAdd1 = ofp_v4_utils:flow_add(
                    [{table_id,TableId},
                     {cookie,<<2:64>>},
                     {priority,Priority},
                     {flags,[]}],
                    Match,
                    Instructions1
                   ),

    FlowDel = ofp_v4_utils:flow_delete(
                delete,
                [{table_id,TableId},
                 {cookie,<<4:64>>},
                 {cookie_mask,<<4:64>>},
                 {priority,Priority},
                 {flags,[]}],
                Match),

    %% Add first flow
    ?assertEqual(ok, linc_us4_oe_flow:modify(?SWITCH_ID, FlowModAdd1)),
    %% Get FlowId
    ?assertMatch([#flow_entry{}], linc_us4_oe_flow:get_flow_table(?SWITCH_ID,
                                                               TableId)),

    %% Delete flow
    ?assertEqual(ok, linc_us4_oe_flow:modify(?SWITCH_ID, FlowDel)),

    %% Check that the the flow was not deleted
    #ofp_flow_mod{match=M1,
                  instructions=I1} = FlowModAdd1,

    ?assertMatch([#flow_entry{match = M1,
                              instructions = I1}],
                 linc_us4_oe_flow:get_flow_table(?SWITCH_ID, TableId)).

delete_cookie_match() ->
    TableId = 4,
    Priority = 6,
    Match = [{in_port,6}, {eth_dst,<<0,0,0,0,0,16#7>>}],

    Instructions1 = [{write_actions,[{output,15,1400}]}],
    %% Create flow_mod record
    FlowModAdd1 = ofp_v4_utils:flow_add(
                    [{table_id,TableId},
                     {cookie,<<4:64>>},
                     {priority,Priority},
                     {flags,[]}],
                    Match,
                    Instructions1
                   ),

    FlowDel = ofp_v4_utils:flow_delete(
                    delete,
                    [{table_id,TableId},
                     {cookie,<<4:64>>},
                     {cookie_mask,<<4:64>>},
                     {priority,Priority},
                     {flags,[]}],
                    Match),

    %% Add first flow
    ?assertEqual(ok, linc_us4_oe_flow:modify(?SWITCH_ID, FlowModAdd1)),
    %% Get FlowId
    ?assertMatch([#flow_entry{}], linc_us4_oe_flow:get_flow_table(?SWITCH_ID,
                                                               TableId)),

    %% Delete flow
    ?assertEqual(ok, linc_us4_oe_flow:modify(?SWITCH_ID, FlowDel)),

    %% Check that the the flow was deleted
    ?assertEqual([], linc_us4_oe_flow:get_flow_table(?SWITCH_ID, TableId)).

delete_send_flow_rem() ->
    TableId = 4,
    Priority = 6,
    Match = [{in_port,6}, {eth_dst,<<0,0,0,0,0,16#7>>}],

    Instructions1 = [{write_actions,[{output,15,1400}]}],
    %% Create flow_mod record
    FlowModAdd1 = ofp_v4_utils:flow_add(
                    [{table_id,TableId},
                     {cookie,<<4:64>>},
                     {priority,Priority},
                     {flags,[send_flow_rem]}],
                    Match,
                    Instructions1
                   ),

    FlowDel = ofp_v4_utils:flow_delete(
                    delete,
                    [{table_id,TableId},
                     {cookie,<<4:64>>},
                     {cookie_mask,<<4:64>>},
                     {priority,Priority},
                     {flags,[]}],
                    Match),

    %% Add first flow
    ?assertEqual(ok, linc_us4_oe_flow:modify(?SWITCH_ID, FlowModAdd1)),
    %% Get FlowId
    ?assertMatch([#flow_entry{}], linc_us4_oe_flow:get_flow_table(?SWITCH_ID,
                                                               TableId)),

    %% Delete flow
    ?assertEqual(ok, linc_us4_oe_flow:modify(?SWITCH_ID, FlowDel)),

    %% Check that the the flow was deleted
    ?assertEqual([], linc_us4_oe_flow:get_flow_table(?SWITCH_ID, TableId)).
    %% FIXME: Cannot mock linc_logic module that belongs to another application
    %% ?assertEqual(true,linc_us4_oe_test_utils:check_if_called({linc_logic,send_to_controllers,1})).


delete_outport_no_match() ->
    TableId = 4,
    Priority = 6,
    Match = [{in_port,6}, {eth_dst,<<0,0,0,0,0,16#7>>}],

    Instructions1 = [{write_actions,[{output,15,1400}]}],
    %% Create flow_mod record
    FlowModAdd1 = ofp_v4_utils:flow_add(
                    [{table_id,TableId},
                     {priority,Priority},
                     {flags,[]}],
                    Match,
                    Instructions1
                   ),

    FlowDel = ofp_v4_utils:flow_delete(
                delete,
                [{table_id,TableId},
                 {priority,Priority},
                 {out_port,10},
                 {flags,[]}],
                Match),

    %% Add first flow
    ?assertEqual(ok, linc_us4_oe_flow:modify(?SWITCH_ID, FlowModAdd1)),
    ?assertMatch([#flow_entry{}], linc_us4_oe_flow:get_flow_table(?SWITCH_ID,
                                                               TableId)),

    %% Delete flow
    ?assertEqual(ok, linc_us4_oe_flow:modify(?SWITCH_ID, FlowDel)),

    %% Check that the the flow was not deleted
    #ofp_flow_mod{match=M1,
                  instructions=I1} = FlowModAdd1,

    ?assertMatch([#flow_entry{match = M1, instructions = I1}],
                 linc_us4_oe_flow:get_flow_table(?SWITCH_ID, TableId)).

delete_outport_match() ->
    TableId = 4,
    Priority = 6,
    Match = [{in_port,6}, {eth_dst,<<0,0,0,0,0,16#7>>}],

    Instructions1 = [{write_actions,[{output,15,1400}]}],
    %% Create flow_mod record
    FlowModAdd1 = ofp_v4_utils:flow_add(
                    [{table_id,TableId},
                     {priority,Priority},
                     {flags,[]}],
                    Match,
                    Instructions1
                   ),

    FlowDel = ofp_v4_utils:flow_delete(
                    delete,
                    [{table_id,TableId},
                     {priority,Priority},
                     {out_port,15},
                     {flags,[]}],
                    Match),

    %% Add first flow
    ?assertEqual(ok, linc_us4_oe_flow:modify(?SWITCH_ID, FlowModAdd1)),
    ?assertMatch([#flow_entry{}], linc_us4_oe_flow:get_flow_table(?SWITCH_ID,
                                                               TableId)),

    %% Delete flow
    ?assertEqual(ok, linc_us4_oe_flow:modify(?SWITCH_ID, FlowDel)),

    %% Check that the the flow was deleted
    ?assertEqual([], linc_us4_oe_flow:get_flow_table(?SWITCH_ID, TableId)).

delete_outgroup_no_match() ->
    TableId = 4,
    Priority = 6,
    Match = [{in_port,6}, {eth_dst,<<0,0,0,0,0,16#7>>}],

    Instructions1 = [{write_actions,[{group,3}]}],
    %% Create flow_mod record
    FlowModAdd1 = ofp_v4_utils:flow_add(
                    [{table_id,TableId},
                     {priority,Priority},
                     {flags,[]}],
                    Match,
                    Instructions1
                   ),

    FlowDel = ofp_v4_utils:flow_delete(
                delete,
                [{table_id,TableId},
                 {priority,Priority},
                 {out_group,10},
                 {flags,[]}],
                Match),

    %% Add first flow
    ?assertEqual(ok, linc_us4_oe_flow:modify(?SWITCH_ID, FlowModAdd1)),
    %% Get FlowId
    ?assertMatch([#flow_entry{}], linc_us4_oe_flow:get_flow_table(?SWITCH_ID,
                                                               TableId)),

    %% Delete flow
    ?assertEqual(ok, linc_us4_oe_flow:modify(?SWITCH_ID, FlowDel)),

    %% Check that the the flow was not deleted
    #ofp_flow_mod{match=M1, instructions=I1} = FlowModAdd1,

    ?assertMatch([#flow_entry{match = M1, instructions = I1}],
                 linc_us4_oe_flow:get_flow_table(?SWITCH_ID, TableId)).

delete_outgroup_match() ->
    TableId = 4,
    Priority = 6,
    Match = [{in_port,6}, {eth_dst,<<0,0,0,0,0,16#7>>}],

    Instructions1 = [{write_actions,[{group,3}]}],
    %% Create flow_mod record
    FlowModAdd1 = ofp_v4_utils:flow_add(
                    [{table_id,TableId},
                     {priority,Priority},
                     {flags,[]}],
                    Match,
                    Instructions1
                   ),

    FlowDel = ofp_v4_utils:flow_delete(
                delete,
                [{table_id,TableId},
                 {priority,Priority},
                 {out_group,3},
                 {flags,[]}],
                Match),

    %% Add first flow
    ?assertEqual(ok, linc_us4_oe_flow:modify(?SWITCH_ID, FlowModAdd1)),
    %% Get FlowId
    ?assertMatch([#flow_entry{}], linc_us4_oe_flow:get_flow_table(?SWITCH_ID,
                                                               TableId)),

    %% Delete flow
    ?assertEqual(ok, linc_us4_oe_flow:modify(?SWITCH_ID, FlowDel)),

    %% Check that the the flow was deleted
    ?assertEqual([], linc_us4_oe_flow:get_flow_table(?SWITCH_ID, TableId)).

delete_all_tables() ->
    %% Create flow_mod record
    FlowModAdd1 = ofp_v4_utils:flow_add(
                    [{table_id,1}],
                    [{in_port,6}, {eth_dst,<<0,0,0,0,0,8>>}],
                    [{write_actions,[{output,15,1400}]}]),

    FlowModAdd2 = ofp_v4_utils:flow_add(
                    [{table_id,2}],
                    [{in_port,6}, {eth_dst,<<0,0,0,0,0,8>>}],
                    [{write_actions,[{output,15,1400}]}]),

    %% Add flows
    ?assertEqual(ok, linc_us4_oe_flow:modify(?SWITCH_ID, FlowModAdd1)),
    ?assertEqual(ok, linc_us4_oe_flow:modify(?SWITCH_ID, FlowModAdd2)),

    %% Check if the flows were added correctly...
    ?assertMatch([#flow_entry{}], linc_us4_oe_flow:get_flow_table(?SWITCH_ID, 1)),
    ?assertMatch([#flow_entry{}], linc_us4_oe_flow:get_flow_table(?SWITCH_ID, 2)),

    %% Delete all flows
    FlowDel = ofp_v4_utils:flow_delete(
                delete,
                [{table_id,all},
                 {flags,[]}],
                []),
    ?assertEqual(ok, linc_us4_oe_flow:modify(?SWITCH_ID, FlowDel)),

    ?assertEqual([],linc_us4_oe_flow:get_flow_table(?SWITCH_ID, 1)),
    ?assertEqual([],linc_us4_oe_flow:get_flow_table(?SWITCH_ID, 2)).

delete_where_group() ->
    %% Create flow_mod record
    FlowModAdd1 = ofp_v4_utils:flow_add(
                    [{table_id,1}],
                    [{in_port,6}, {eth_dst,<<0,0,0,0,0,8>>}],
                    [{write_actions,[{group,3}]}]),
    FlowModAdd2 = ofp_v4_utils:flow_add(
                    [{table_id,1}],
                    [{in_port,6}, {eth_dst,<<0,0,0,0,0,8>>}],
                    [{write_actions,[{group,4}]}]),

    %% Add flows
    ?assertEqual(ok, linc_us4_oe_flow:modify(?SWITCH_ID, FlowModAdd1)),
    ?assertEqual(ok, linc_us4_oe_flow:modify(?SWITCH_ID, FlowModAdd2)),

    #ofp_flow_mod{match=Match2,
                  instructions=Instructions2} = FlowModAdd2,

    %% Delete all referencing group 3
    ?assertEqual(ok, linc_us4_oe_flow:delete_where_group(?SWITCH_ID, 3)),

    ?assertMatch([#flow_entry{match=Match2,
                              instructions=Instructions2}],
                 linc_us4_oe_flow:get_flow_table(?SWITCH_ID, 1)).

delete_where_meter() ->
    %% Create flow_mod record
    FlowModAdd1 = ofp_v4_utils:flow_add(
                    [{table_id,1}],
                    [{in_port,6}, {eth_dst,<<0,0,0,0,0,8>>}],
                    [{meter,4}]),
    FlowModAdd2 = ofp_v4_utils:flow_add(
                    [{table_id,1}],
                    [{in_port,6}, {eth_dst,<<0,0,0,0,0,8>>}],
                    [{meter,5}]),

    %% Add flows
    ?assertEqual(ok, linc_us4_oe_flow:modify(?SWITCH_ID, FlowModAdd1)),
    ?assertEqual(ok, linc_us4_oe_flow:modify(?SWITCH_ID, FlowModAdd2)),

    #ofp_flow_mod{match=Match2,
                  instructions=Instructions2} = FlowModAdd2,

    %% Delete all referencing meter 4
    ?assertEqual(ok, linc_us4_oe_flow:delete_where_meter(?SWITCH_ID, 4)),

    ?assertMatch([#flow_entry{match=Match2,
                              instructions=Instructions2}],
                 linc_us4_oe_flow:get_flow_table(?SWITCH_ID, 1)).

incompatible_value_mask_pair_in_match() ->
    FlowModAdd = ofp_v4_utils:flow_add(
                   [],
                   %% In the last octet in the address to be matched there's
                   %% a binary value of 00000111 while in the mask 00000110.
                   %% This is an error as all bits set to 1 in a value demand
                   %% a corresponding bit in the mask set to 1.
                   [{eth_type, <<16#800:16>>},
                    {ipv4_src, <<10,0,0,7>>, <<10,0,0,6>>}],
                   [{write_actions,[{output,15,no_buffer}]}]),
    ?assertEqual({error, {bad_match, bad_wildcards}},
                 linc_us4_oe_flow:modify(?SWITCH_ID, FlowModAdd)).

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
    ?assertEqual(ok, linc_us4_oe_flow:update_lookup_counter(?SWITCH_ID, TableId)),
    ?assertMatch([#flow_table_counter{packet_lookups=1}],
                 ets:lookup(FlowTableCounters, TableId)).


update_match_counter() ->
    TableId = 5,
    FlowModAdd = ofp_v4_utils:flow_add(
                   [{table_id,TableId},
                    {priority,4},
                    {flags,[]}],
                   [{in_port,6}, {eth_dst,<<0,0,0,0,0,8>>,<<0,0,0,0,0,15>>}],
                   [{write_actions,[{output,15,1400}]}]),

    ?assertEqual(ok, linc_us4_oe_flow:modify(?SWITCH_ID, FlowModAdd)),

    [#flow_entry{id=FlowId}] = linc_us4_oe_flow:get_flow_table(?SWITCH_ID,
                                                            TableId),

    %% Increments flow counters
    PacketSize = 1024,
    ?assertEqual(ok, linc_us4_oe_flow:update_match_counters(?SWITCH_ID,
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
    ?assertEqual(ok, linc_us4_oe_flow:update_match_counters(?SWITCH_ID,
                                                         TableId,
                                                         FlowId,PacketSize)),
    FlowEntryCounters = linc:lookup(?SWITCH_ID, flow_entry_counters),
    ?assertEqual([], ets:lookup(FlowEntryCounters, FlowId)).

empty_flow_stats() ->
    StatsReq = ofp_v4_utils:flow_stats(
                 [{table_id, 1}],
                 [{in_port,6}, {eth_dst,<<0,0,0,0,0,8>>}]),
    ?assertEqual(#ofp_flow_stats_reply{body=[]},
                 linc_us4_oe_flow:get_stats(?SWITCH_ID, StatsReq)).

flow_stats_1_table() ->
    FlowModAdd1 = ofp_v4_utils:flow_add(
                    [{table_id,1}],
                    [{in_port,6}, {eth_dst,<<0,0,0,0,0,8>>}],
                    [{write_actions,[{group,3}]}]),
    ?assertEqual(ok, linc_us4_oe_flow:modify(?SWITCH_ID, FlowModAdd1)),
    FlowModAdd2 = ofp_v4_utils:flow_add(
                    [{table_id,1}],
                    [{in_port,2}, {eth_dst,<<0,0,0,0,0,8>>}],
                    [{write_actions,[{group,3}]}]),
    ?assertEqual(ok, linc_us4_oe_flow:modify(?SWITCH_ID, FlowModAdd2)),
    StatsReq = ofp_v4_utils:flow_stats(
                 [{table_id, 1}],
                 [{in_port,6}, {eth_dst,<<0,0,0,0,0,8>>}]),
    ?assertMatch(#ofp_flow_stats_reply{body=[#ofp_flow_stats{}]},
                 linc_us4_oe_flow:get_stats(?SWITCH_ID, StatsReq)).

flow_stats_all_tables() ->
    FlowModAdd1 = ofp_v4_utils:flow_add(
                    [{table_id,1}],
                    [{in_port,6}, {eth_dst,<<0,0,0,0,0,8>>}],
                    [{write_actions,[{group,3}]}]),
    ?assertEqual(ok, linc_us4_oe_flow:modify(?SWITCH_ID, FlowModAdd1)),
    FlowModAdd2 = ofp_v4_utils:flow_add(
                    [{table_id,2}],
                    [{in_port,6}, {eth_dst,<<0,0,0,0,0,8>>}],
                    [{write_actions,[{group,3}]}]),
    ?assertEqual(ok, linc_us4_oe_flow:modify(?SWITCH_ID, FlowModAdd2)),
    StatsReq = ofp_v4_utils:flow_stats(
                 [{table_id, all}],
                 [{in_port,6}, {eth_dst,<<0,0,0,0,0,8>>}]),
    ?assertMatch(#ofp_flow_stats_reply{body=[#ofp_flow_stats{},
                                              #ofp_flow_stats{}]},
                 linc_us4_oe_flow:get_stats(?SWITCH_ID, StatsReq)).

empty_aggr_stats() ->
    StatsReq = ofp_v4_utils:aggr_stats(
                 [{table_id, 1}],
                 [{in_port,6}, {eth_dst,<<0,0,0,0,0,8>>}]),
    ?assertEqual(#ofp_aggregate_stats_reply{packet_count=0,
                                            byte_count=0,
                                            flow_count=0},
                 linc_us4_oe_flow:get_aggregate_stats(?SWITCH_ID, StatsReq)).

aggr_stats_1_table() ->
    TableId = 1,
    FlowModAdd1 = ofp_v4_utils:flow_add(
                    [{table_id,TableId}],
                    [{in_port,6}, {eth_dst,<<0,0,0,0,0,8>>}],
                    [{write_actions,[{group,3}]}]),
    ?assertEqual(ok, linc_us4_oe_flow:modify(?SWITCH_ID, FlowModAdd1)),
    FlowModAdd2 = ofp_v4_utils:flow_add(
                    [{table_id,TableId}],
                    [{in_port,6}, {eth_dst,<<0,0,0,0,1,8>>}],
                    [{write_actions,[{group,3}]}]),
    ?assertEqual(ok, linc_us4_oe_flow:modify(?SWITCH_ID, FlowModAdd2)),

    [#flow_entry{id=FlowId1},
     #flow_entry{id=FlowId2}] = linc_us4_oe_flow:get_flow_table(?SWITCH_ID,
                                                             TableId),

    %% Increments flow counters
    PacketSize = 1024,
    ?assertEqual(ok, linc_us4_oe_flow:update_match_counters(?SWITCH_ID,
                                                         TableId,
                                                         FlowId1,
                                                         PacketSize)),
    ?assertEqual(ok, linc_us4_oe_flow:update_match_counters(?SWITCH_ID,
                                                         TableId,
                                                         FlowId2,
                                                         PacketSize)),
    %% This will only match one of the flows
    StatsReq = ofp_v4_utils:aggr_stats(
                 [{table_id, TableId}],
                 [{in_port,6}, {eth_dst,<<0,0,0,0,0,8>>}]),
    ?assertEqual(#ofp_aggregate_stats_reply{packet_count=1,
                                            byte_count=1024,
                                            flow_count=1},
                 linc_us4_oe_flow:get_aggregate_stats(?SWITCH_ID, StatsReq)).

aggr_stats_all_tables() ->
    FlowModAdd1 = ofp_v4_utils:flow_add(
                    [{table_id,1}],
                    [{in_port,6}, {eth_dst,<<0,0,0,0,0,8>>}],
                    [{write_actions,[{group,3}]}]),
    ?assertEqual(ok, linc_us4_oe_flow:modify(?SWITCH_ID, FlowModAdd1)),
    FlowModAdd2 = ofp_v4_utils:flow_add(
                    [{table_id,2}],
                    [{in_port,6}, {eth_dst,<<0,0,0,0,0,8>>}],
                    [{write_actions,[{group,3}]}]),
    ?assertEqual(ok, linc_us4_oe_flow:modify(?SWITCH_ID, FlowModAdd2)),

    [#flow_entry{id=FlowId1}] = linc_us4_oe_flow:get_flow_table(?SWITCH_ID, 1),
    [#flow_entry{id=FlowId2}] = linc_us4_oe_flow:get_flow_table(?SWITCH_ID, 2),

    %% Increments flow counters
    PacketSize = 1024,
    ?assertEqual(ok, linc_us4_oe_flow:update_match_counters(?SWITCH_ID,
                                                         1,
                                                         FlowId1,
                                                         PacketSize)),
    ?assertEqual(ok, linc_us4_oe_flow:update_match_counters(?SWITCH_ID,
                                                         2,
                                                         FlowId2,
                                                         PacketSize)),
    %% This will matchboth flows
    StatsReq = ofp_v4_utils:aggr_stats(
                 [{table_id, all}],
                 [{in_port,6}, {eth_dst,<<0,0,0,0,0,8>>}]),
    ?assertEqual(#ofp_aggregate_stats_reply{packet_count=2,
                                            byte_count=2048,
                                            flow_count=2},
                 linc_us4_oe_flow:get_aggregate_stats(?SWITCH_ID, StatsReq)).

empty_table_stats() ->
    ?assertMatch(#ofp_table_stats_reply{body=[#ofp_table_stats{}|_]},
                 linc_us4_oe_flow:get_table_stats(?SWITCH_ID,
                                               #ofp_table_stats_request{})).

timer_test_() ->
    {setup, fun setup/0, fun teardown/1,
     {foreach, fun foreach_setup/0, fun foreach_teardown/1,
      [{"Idle timeout", fun idle_timeout/0}
       ,{"Hard timeout", fun hard_timeout/0}
      ]}}.

idle_timeout() ->
    FlowModAdd1 = ofp_v4_utils:flow_add(
                    [{table_id,1},
                     {idle_timeout,1}],
                    [{in_port,6}, {eth_dst,<<0,0,0,0,0,8>>}],
                    [{write_actions,[{group,3}]}]),
    ?assertEqual(ok, linc_us4_oe_flow:modify(?SWITCH_ID, FlowModAdd1)),
    [#flow_entry{id=FlowId}] = linc_us4_oe_flow:get_flow_table(?SWITCH_ID, 1),
    timer:sleep(100),
    [#flow_entry{id=FlowId}] = linc_us4_oe_flow:get_flow_table(?SWITCH_ID, 1),
    ok = linc_us4_oe_flow:reset_idle_timeout(?SWITCH_ID, FlowId),
    timer:sleep(100),
    ?assertMatch([#flow_entry{id=FlowId}],
                 linc_us4_oe_flow:get_flow_table(?SWITCH_ID, 1)),
    timer:sleep(2500),
    ?assertEqual([], linc_us4_oe_flow:get_flow_table(?SWITCH_ID, 1)).

hard_timeout() ->
    FlowModAdd1 = ofp_v4_utils:flow_add(
                    [{table_id,1},
                     {hard_timeout,1}],
                    [{in_port,6}, {eth_dst,<<0,0,0,0,0,8>>}],
                    [{write_actions,[{group,3}]}]),
    ?assertEqual(ok, linc_us4_oe_flow:modify(?SWITCH_ID, FlowModAdd1)),
    ?assertMatch([#flow_entry{}], linc_us4_oe_flow:get_flow_table(?SWITCH_ID, 1)),
    timer:sleep(2500),
    ?assertEqual([], linc_us4_oe_flow:get_flow_table(?SWITCH_ID, 1)).

oe_delete_with_fields_from_infoblox_class() ->
    %% GIVEN
    Match = [{in_port, 3},
             {och_sigtype, <<10>>},
             {och_sigid, <<0,0,0,10,0,0>>}],
    ok = linc_us4_oe_flow:modify(?SWITCH_ID,
                                 ofp_v4_utils:flow_add([], Match, [])),

    %% WHEN
    ok = linc_us4_oe_flow:modify(?SWITCH_ID,
                                 ofp_v4_utils:flow_delete(delete, Match, [])),

    %% THEN
    ?assertEqual([], linc_us4_oe_flow:get_flow_table(?SWITCH_ID,
                                                     _DefaultTableId = 0)).

%% Fixtures --------------------------------------------------------------------
setup() ->
    linc_us4_oe_test_utils:add_logic_path(),
    linc:create(?SWITCH_ID),
    linc_us4_oe_test_utils:mock(?MOCKED).

teardown(_) ->
    linc:delete(?SWITCH_ID),
    linc_us4_oe_test_utils:unmock(?MOCKED).

foreach_setup() ->
    linc_us4_oe_flow:initialize(?SWITCH_ID).

foreach_teardown(State) ->
    linc_us4_oe_flow:terminate(State).

%% Helpers ---------------------------------------------------------------------
