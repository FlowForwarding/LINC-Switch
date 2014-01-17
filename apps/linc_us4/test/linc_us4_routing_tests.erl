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
-module(linc_us4_routing_tests).

-import(linc_us4_test_utils, [mock/1,
                              unmock/1,
                              check_if_called/1,
                              check_output_on_ports/0]).

-include_lib("of_protocol/include/of_protocol.hrl").
-include_lib("of_protocol/include/ofp_v4.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("pkt/include/pkt.hrl").
-include("linc_us4.hrl").

-define(MOCKED, [port]).
-define(SWITCH_ID, 0).

%% Tests -----------------------------------------------------------------------

routing_test_() ->
    {setup, fun setup/0, fun teardown/1,
     {foreach, fun foreach_setup/0, fun foreach_teardown/1,
      [{"Routing: match on Flow Table entry",
        fun match/0},
       {"Routing: match on Flow Table entry with highest priority",
        fun match_priority/0},
       {"Routing: match on Flow Table entry with empty match list",
        fun match_empty_matches/0},
       {"Routing: match on Flow Table miss entry",
        fun match_miss/0},
       {"Routing: match on Flow Table miss entry invokes Goto instruction",
        fun match_miss_goto/0},
       {"Routing: match on next Flow Table because of Goto instruction",
        fun goto/0},
       {"Routing: table miss - continue to next table", fun miss_continue/0},
       {"Routing: table miss - send to controller", fun miss_controller/0},
       {"Routing: table miss - drop packet", fun miss_drop/0},
       {"Routing: match fields with masks", fun mask_match/0},
       {"Routing: spawn new route process", fun spawn_route/0},
       {"Routing: maybe spawn new route process", fun maybe_spawn_route/0}
      ]}}.

%% @doc Test matching on VLAN tag in accordance to OF spec. v1.3.2 ch. 7.2.3.7.
vlan_matching_test_() ->
    [{"Test matching packets with and without a VLAN tag",
      fun match_with_and_without_vlan_tag/0},
     {"Test matching only packets without a VLAN tag",
      fun match_only_without_vlan_tag/0},
     {"Test matching only packets with a VLAN tag regardless of VID value",
      fun match_unrestricted_vlan_tag/0},
     {"Test matching packets containing a VLAN tag with masked VID",
      fun match_masked_vlan_tag/0},
     {"Test matching packets containing a VLAN tag with specified VID",
      fun match_not_masked_vlan_tag/0}].

match() ->
    Flow1 = 200,
    Flow2 = 100,
    MatchFieldsFlow1 = [{ipv4_dst, abc}, {ipv4_src, def}],
    MatchFieldsFlow2 = [{ipv4_dst, ghi}, {ipv4_src, jkl}],
    TableId = 0,
    FlowEntries = [flow_entry(Flow1, MatchFieldsFlow1),
                   flow_entry(Flow2, MatchFieldsFlow2, cookie)],
    TableConfig = drop,
    flow_table(TableId, FlowEntries, TableConfig),

    %% Match on the second flow entry in the first flow table
    MatchFieldsPkt = [{ipv4_dst, ghi},
                      {ipv4_src, jkl},
                      {not_in_match, shouldnt_be_used}],
    Pkt = pkt(MatchFieldsPkt),
    ?assertEqual({match, Flow2, Pkt#linc_pkt{cookie = cookie,
                                            table_id = TableId}},
                 linc_us4_routing:route(Pkt)).

match_priority() ->
    Flow1 = 200,
    Flow2 = 100,
    MatchFieldsFlow1 = [{ipv4_dst, abc}, {ipv4_src, def}],
    MatchFieldsFlow2 = [{ipv4_dst, abc}, {ipv4_src, def}],
    TableId = 0,
    FlowEntries = [flow_entry(Flow1, MatchFieldsFlow1),
                   flow_entry(Flow2, MatchFieldsFlow2)],
    TableConfig = drop,
    flow_table(TableId, FlowEntries, TableConfig),

    %% Match on the first flow entry in the first flow table
    MatchFieldsPkt = [{ipv4_dst, abc}, {ipv4_src, def}],
    Pkt = pkt(MatchFieldsPkt),
    ?assertEqual({match, Flow1, Pkt#linc_pkt{table_id = TableId,
                                            cookie = <<0:64>>}},
                 linc_us4_routing:route(Pkt)).

match_empty_matches() ->
    Flow1 = 200,
    Flow2 = 100,
    MatchFieldsFlow1 = [{ipv4_dst, abc}, {ipv4_src, def}],
    MatchFieldsFlow2 = [],
    TableId = 0,
    FlowEntries = [flow_entry(Flow1, MatchFieldsFlow1),
                   flow_entry(Flow2, MatchFieldsFlow2)],
    TableConfig = drop,
    flow_table(TableId, FlowEntries, TableConfig),

    %% Match on the second flow entry in the first flow table
    MatchFieldsPkt = [{ipv4_dst, zxc}, {ipv4_src, qwe}],
    Pkt = pkt(MatchFieldsPkt),
    ?assertEqual({match, Flow2, Pkt#linc_pkt{table_id = TableId,
                                            cookie = <<0:64>>}},
                 linc_us4_routing:route(Pkt)).

match_miss() ->
    Flow1 = 200,
    Flow2 = 100,
    FlowMiss = 0,
    MatchFieldsFlow1 = [{ipv4_dst, abc}, {ipv4_src, def}],
    MatchFieldsFlow2 = [{ipv4_dst, ghi}, {ipv4_src, jkl}],
    MatchFieldsFlow3 = [],
    TableId = 0,
    FlowEntries = [flow_entry(Flow1, MatchFieldsFlow1),
                   flow_entry(Flow2, MatchFieldsFlow2),
                   flow_entry(FlowMiss, MatchFieldsFlow3, cookie)],
    TableConfig = drop,
    flow_table(TableId, FlowEntries, TableConfig),

    %% Match on the third flow entry (table-miss) in the first flow table
    MatchFieldsPkt = [{ipv4_dst, not_in_any_flow}],
    Pkt = pkt(MatchFieldsPkt),
    ?assertEqual({match, FlowMiss, Pkt#linc_pkt{table_id = TableId,
                                               cookie = cookie,
                                               packet_in_reason = no_match}},
                 linc_us4_routing:route(Pkt)).

match_miss_goto() ->
    Flow1 = 0,
    Flow2 = 100,
    MatchFieldsFlow1 = [],
    MatchFieldsFlow2 = [{ipv4_dst, abc}, {ipv4_src, def}],
    TableId1 = 0,
    TableId2 = 1,
    FlowEntry1a = flow_entry(Flow1, MatchFieldsFlow1),
    InstructionGoto = #ofp_instruction_goto_table{table_id = TableId2},
    FlowEntry1b = FlowEntry1a#flow_entry{instructions = [InstructionGoto]},
    FlowEntries1 = [FlowEntry1b],
    FlowEntries2 = [flow_entry(Flow2, MatchFieldsFlow2)],
    TableConfig = drop,
    flow_table(TableId1, FlowEntries1, TableConfig),
    flow_table(TableId2, FlowEntries2, TableConfig),

    %% Match on the third flow entry (table-miss) in the first flow table
    MatchFieldsPkt = [{ipv4_dst, abc}, {ipv4_src, def}],
    Pkt = pkt(MatchFieldsPkt),
    ?assertEqual({match, Flow2, Pkt#linc_pkt{table_id = TableId2,
                                            cookie = <<0:64>>,
                                            packet_in_reason = no_match}},
                 linc_us4_routing:route(Pkt)).

goto() ->
    Flow1 = 200,
    Flow2 = 100,
    MatchFieldsFlow1 = [{ipv4_dst, abc}, {ipv4_src, def}],
    MatchFieldsFlow2 = [{ipv4_dst, abc}, {ipv4_src, def}],
    TableId1 = 0,
    TableId2 = 1,
    FlowEntry1a = flow_entry(Flow1, MatchFieldsFlow1),
    InstructionGoto = #ofp_instruction_goto_table{table_id = TableId2},
    FlowEntry1b = FlowEntry1a#flow_entry{instructions = [InstructionGoto]},
    FlowEntries1 = [FlowEntry1b],
    FlowEntries2 = [flow_entry(Flow2, MatchFieldsFlow2)],
    TableConfig = continue,
    flow_table(TableId1, FlowEntries1, TableConfig),
    flow_table(TableId2, FlowEntries2, TableConfig),

    %% Match on the first flow entry in the second flow table    
    MatchFieldsPkt = [{ipv4_dst, abc}, {ipv4_src, def}],
    Pkt = pkt(MatchFieldsPkt),
    ?assertEqual({match, Flow2, Pkt#linc_pkt{table_id = TableId2,
                                            cookie = <<0:64>>}},
                 linc_us4_routing:route(Pkt)).

miss_continue() ->
    [begin
         miss_no_flow_entries(TableConfig, MissError),
         miss_no_matching_flow_entry(TableConfig, MissError)
     end || {TableConfig, MissError} <- [{continue, drop}]].

miss_controller() ->
    meck:new(pkt),
    meck:expect(pkt, encapsulate, fun(_) -> <<>> end),
    [begin
         miss_no_flow_entries(TableConfig, MissError),
         miss_no_matching_flow_entry(TableConfig, MissError)
     end || {TableConfig, MissError} <- [{controller, controller}]],
    meck:unload(pkt).

miss_drop() ->
    [begin
         miss_no_flow_entries(TableConfig, MissError),
         miss_no_matching_flow_entry(TableConfig, MissError)
     end || {TableConfig, MissError} <- [{drop, drop}]].

mask_match() ->
    [begin
         Field1 = #ofp_field{value = V1},
         Field2 = #ofp_field{value = V2, has_mask = true, mask = Mask},
         ?assertEqual(Result,
                      linc_us4_routing:pkt_field_match_flow_field(Field1,
                                                                  Field2))
     end || {V1, V2, Mask, Result} <- [{<<>>, <<>>, <<>>, true},
                                       {<<7,7,7>>, <<7,7,7>>, <<1,1,1>>, true},
                                       {<<7,7,7>>, <<7,7,8>>, <<1,1,1>>, false},
                                       {<<7,7,7>>, <<7,7,8>>, <<1,1,0>>, true}
                                      ]].

flow_table_and_pkt() ->
    Flow1 = 0,
    MatchFieldsFlow1 = [],
    TableId = 0,
    FlowEntries = [flow_entry(Flow1, MatchFieldsFlow1)],
    TableConfig = drop,
    flow_table(TableId, FlowEntries, TableConfig),

    MatchFieldsPkt = [],
    pkt(MatchFieldsPkt).

spawn_route() ->
    ?assert(is_pid(linc_us4_routing:spawn_route(flow_table_and_pkt()))).

maybe_spawn_route() ->
    Pkt = flow_table_and_pkt(), 
    application:set_env(linc, sync_routing, false),
    ?assert(is_pid(linc_us4_routing:maybe_spawn_route(Pkt))),
    application:set_env(linc, sync_routing, true),
    ?assertMatch({match, 0, _}, linc_us4_routing:maybe_spawn_route(Pkt)).

match_with_and_without_vlan_tag() ->
    PktFields1 = create_ofp_fields([{vlan_vid, <<10:12>>}]),
    PktFields2 = [],
    FlowFields = [],
    ?assert(linc_us4_routing:pkt_fields_match_flow_fields(PktFields1,
                                                          FlowFields)),
    ?assert(linc_us4_routing:pkt_fields_match_flow_fields(PktFields2,
                                                          FlowFields)).

match_only_without_vlan_tag() ->
    PktFields1 = create_ofp_fields([{vlan_vid, <<10:12>>}]),
    PktFields2 = [],
    FlowFields = create_ofp_fields([{vlan_vid, <<?OFPVID_NONE:13>>}]),
    ?assertNot(linc_us4_routing:pkt_fields_match_flow_fields(PktFields1,
                                                             FlowFields)),
    ?assert(linc_us4_routing:pkt_fields_match_flow_fields(PktFields2,
                                                          FlowFields)).

match_unrestricted_vlan_tag() ->
    PktFields1 = create_ofp_fields([{vlan_vid, <<10:12>>}]),
    PktFields2 = [],
    FlowFields = create_ofp_fields([{vlan_vid, <<?OFPVID_PRESENT:13>>,
                                     <<?OFPVID_PRESENT:13>>}]),
    ?assert(linc_us4_routing:pkt_fields_match_flow_fields(PktFields1,
                                                          FlowFields)),
    ?assertNot(linc_us4_routing:pkt_fields_match_flow_fields(PktFields2,
                                                             FlowFields)).

match_masked_vlan_tag() ->
    PktFields1 = create_ofp_fields([{vlan_vid, <<16#007:12>>}]),
    PktFields2 = create_ofp_fields([{vlan_vid, <<16#00F:12>>}]),
    PktFields3 = create_ofp_fields([{vlan_vid, <<16#006:12>>}]),
    FlowFields = create_ofp_fields([{vlan_vid,
                                     <<(?OFPVID_PRESENT bor 16#007):13>>,
                                     <<(?OFPVID_PRESENT bor 16#FF7):13>>}]),
    ?assert(linc_us4_routing:pkt_fields_match_flow_fields(PktFields1,
                                                          FlowFields)),
    ?assert(linc_us4_routing:pkt_fields_match_flow_fields(PktFields2,
                                                          FlowFields)),
    ?assertNot(linc_us4_routing:pkt_fields_match_flow_fields(PktFields3,
                                                             FlowFields)).

match_not_masked_vlan_tag() ->
    PktFields1 = create_ofp_fields([{vlan_vid, <<16#007:12>>}]),
    PktFields2 = create_ofp_fields([{vlan_vid, <<16#00F:12>>}]),
    FlowFields = create_ofp_fields([{vlan_vid,
                                     <<(?OFPVID_PRESENT bor 16#007):13>>}]),
    ?assert(linc_us4_routing:pkt_fields_match_flow_fields(PktFields1,
                                                          FlowFields)),
    ?assertNot(linc_us4_routing:pkt_fields_match_flow_fields(PktFields2,
                                                             FlowFields)).

%% Fixtures --------------------------------------------------------------------

setup() ->
    linc:create(?SWITCH_ID),
    mock(?MOCKED).

teardown(_) ->
    linc:delete(?SWITCH_ID),
    unmock(?MOCKED).

foreach_setup() ->
    linc_us4_flow:initialize(?SWITCH_ID).

foreach_teardown(State) ->
    ok = linc_us4_flow:terminate(State).

%% Helpers  --------------------------------------------------------------------

flow_entry(FlowId, Matches) ->
    flow_entry(FlowId, Matches, <<0:64>>).

flow_entry(FlowId, Matches, Cookie) ->
    true = ets:insert(linc:lookup(?SWITCH_ID, flow_entry_counters),
                      #flow_entry_counter{id = FlowId}),
    MatchFields = [#ofp_field{name = Type, value = Value}
                   || {Type, Value} <- Matches],
    #flow_entry{id = FlowId, priority = FlowId, cookie = Cookie,
                match = #ofp_match{fields = MatchFields}}.

flow_table(TableId, FlowEntries, Config) ->
    TableConfig = #flow_table_config{id = TableId, config = Config},
    TableName = list_to_atom("flow_table_" ++ integer_to_list(TableId)),
    ets:insert(linc:lookup(?SWITCH_ID, flow_table_config), TableConfig),
    ets:insert(linc:lookup(?SWITCH_ID, TableName), FlowEntries).

pkt(Matches) ->
    MatchFields = [#ofp_field{name = Type, value = Value}
                   || {Type, Value} <- Matches],
    #linc_pkt{fields = #ofp_match{fields = MatchFields}}.

miss_no_flow_entries(TableConfig, MissError) ->
    %% Table miss when no flow entries in the flow table
    MatchFields = [],
    Pkt = pkt(MatchFields),
    FlowEntries = [],
    TableId = 0,
    flow_table(TableId, FlowEntries, TableConfig),
    ?assertEqual({table_miss, MissError}, linc_us4_routing:route(Pkt)).

miss_no_matching_flow_entry(TableConfig, MissError) ->
    %% Table miss when no flow entry matches the packet
    MatchFieldsPkt = [{ipv4_src, abc}],
    MatchFieldsFlow = [{ipv4_src, def}],
    Pkt = pkt(MatchFieldsPkt),
    FlowEntries = [flow_entry(f1, MatchFieldsFlow)],
    TableId = 0,
    flow_table(TableId, FlowEntries, TableConfig),
    ?assertEqual({table_miss, MissError}, linc_us4_routing:route(Pkt)).

create_ofp_fields(Fields) ->
    lists:foldr(fun(Field, Acc) ->
                        [create_ofp_field(Field) | Acc]
                end, [], Fields).

create_ofp_field({Name, Value}) ->
    #ofp_field{name = Name, value = Value};
create_ofp_field({Name, Value, Mask}) ->
    #ofp_field{name = Name, value = Value, has_mask = true, mask = Mask}.
