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
-module(linc_us3_instructions_tests).

-import(linc_us3_test_utils, [mock/1,
                              unmock/1,
                              check_if_called/1]).

-include_lib("of_protocol/include/of_protocol.hrl").
-include_lib("of_protocol/include/ofp_v3.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("linc_us3.hrl").

-define(MOCKED, []).

%% Tests -----------------------------------------------------------------------

instruction_test_() ->
    {setup,
     fun setup/0,
     fun teardown/1,
     [{"Apply-Actions", fun apply_actions/0},
      {"Clear-Actions", fun clear_actions/0},
      {"Write-Actions", fun write_actions/0},
      {"Write-Metadata", fun write_metadata/0},
      {"Goto-Table", fun goto_table/0},
      {"Empty instruction list", fun empty/0}]}.

apply_actions() ->
    Pkt = #linc_pkt{},
    ApplyActions = #ofp_instruction_apply_actions{actions = []},
    ?assertMatch({stop, Pkt}, linc_us3_instructions:apply(Pkt, [ApplyActions])).

clear_actions() ->
    SomeAction = #ofp_action_output{port = 0},
    AnotherAction = #ofp_action_copy_ttl_out{},
    SomePacket = #linc_pkt{actions = [SomeAction, AnotherAction]},
    ClearActions = #ofp_instruction_clear_actions{},
    {_, NewPacket} = linc_us3_instructions:apply(SomePacket, [ClearActions]),
    ?assertEqual([], NewPacket#linc_pkt.actions).

write_actions() ->
    SomePacket = #linc_pkt{actions = []},
    SomeAction = #ofp_action_output{port = 0},
    WriteActions = #ofp_instruction_write_actions{actions = [SomeAction]},
    {_, NewPacket} = linc_us3_instructions:apply(SomePacket, [WriteActions]),
    ?assertEqual([SomeAction], NewPacket#linc_pkt.actions).

write_metadata() ->
    OldMetadata = <<111:64>>,
    Metadata = <<333:64>>,
    MetadataMask = <<222:64>>,
    WriteMetadata = #ofp_instruction_write_metadata{metadata = Metadata,
                                                    metadata_mask = MetadataMask},
    %% No metadata in packet before, ignore mask
    Packet1 = #linc_pkt{fields = #ofp_match{}},
    {_, NewPacket1} = linc_us3_instructions:apply(Packet1, [WriteMetadata]),
    Fields1 = NewPacket1#linc_pkt.fields#ofp_match.fields,
    ?assertMatch(true, lists:keymember(metadata, #ofp_field.name, Fields1)),
    MetadataField1 = lists:keyfind(metadata, #ofp_field.name, Fields1),
    ?assertEqual(Metadata, MetadataField1#ofp_field.value),
    
    %% Metadata in packet before, apply mask
    Packet2 = #linc_pkt{fields = #ofp_match{fields = [#ofp_field{name = metadata,
                                                                value = OldMetadata}]}},
    {_, NewPacket2} = linc_us3_instructions:apply(Packet2, [WriteMetadata]),
    %% From OpenFlow 1.2 spec, page 14:
    %% new metadata = (old metadata & ~mask) | (value & mask)
    ExpectedMetadata = (111 band (bnot 222)) bor (333 band 222),
    Fields2 = NewPacket2#linc_pkt.fields#ofp_match.fields,
    ?assertMatch(true, lists:keymember(metadata, #ofp_field.name, Fields2)),
    MetadataField2 = lists:keyfind(metadata, #ofp_field.name, Fields2),
    ?assertEqual(<<ExpectedMetadata:64>>, MetadataField2#ofp_field.value).

goto_table() ->
    GotoTable = #ofp_instruction_goto_table{table_id = 5},
    ?assertEqual({{goto, 5}, pkt},
                 linc_us3_instructions:apply(pkt, [GotoTable])).

empty() ->
    ?assertEqual({stop, pkt}, linc_us3_instructions:apply(pkt, [])).

%% Fixtures --------------------------------------------------------------------

setup() ->
    mock(?MOCKED),
    ok.

teardown(ok) ->
    unmock(?MOCKED),
    ok.
