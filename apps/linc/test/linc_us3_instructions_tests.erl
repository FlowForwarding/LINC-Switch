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

-import(linc_test_utils, [mock/1,
                          unmock/1,
                          check_if_called/1]).

-include_lib("eunit/include/eunit.hrl").
-include_lib("linc/include/linc_us3.hrl").

-define(MOCKED, [actions]).

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
    ApplyActions = #ofp_instruction_apply_actions{actions = []},
    linc_us3_instructions:apply(pkt, [ApplyActions]),
    ?assert(check_if_called({linc_us3_actions, apply_list, 2})).

clear_actions() ->
    SomeAction = #ofp_action_output{port = 0},
    AnotherAction = #ofp_action_copy_ttl_out{},
    SomePacket = #ofs_pkt{actions = [SomeAction, AnotherAction]},
    ClearActions = #ofp_instruction_clear_actions{},
    {_, NewPacket} = linc_us3_instructions:apply(SomePacket, [ClearActions]),
    ?assertEqual([], NewPacket#ofs_pkt.actions).

write_actions() ->
    SomePacket = #ofs_pkt{actions = []},
    SomeAction = #ofp_action_output{port = 0},
    WriteActions = #ofp_instruction_write_actions{actions = [SomeAction]},
    {_, NewPacket} = linc_us3_instructions:apply(SomePacket, [WriteActions]),
    ?assertEqual([SomeAction], NewPacket#ofs_pkt.actions).

write_metadata() ->
    SomePacket = #ofs_pkt{metadata = <<111:64>>},
    WriteMetadata = #ofp_instruction_write_metadata{metadata = <<333:64>>,
                                                    metadata_mask = <<222:64>>},
    {_, NewPacket} = linc_us3_instructions:apply(SomePacket, [WriteMetadata]),
    NewValue = 111 + (333 band 222),
    ?assertEqual(<<NewValue:64>>, NewPacket#ofs_pkt.metadata).

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
