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

-import(linc_test_utils, [check_if_called/1]).

-include_lib("eunit/include/eunit.hrl").
-include_lib("of_protocol/include/of_protocol.hrl").
-include_lib("of_protocol/include/ofp_v3.hrl").

%% Tests -----------------------------------------------------------------------

instruction_test_() ->
    {foreach,
     fun setup/0,
     fun teardown/1,
     [{"Apply-Actions", fun apply_actions/0},
      {"Clear-Actions", fun clear_actions/0},
      {"Write-Actions", fun write_actions/0},
      {"Write-Metadata", fun write_metadata/0},
      {"Goto-Table", fun goto_table/0},
      {"Empty instruction list", fun empty/0}]}.

apply_actions() ->
    ApplyActionsInstruction = create_apply_actions(),
    linc_us3_instructions:apply(pkt, [ApplyActionsInstruction]),
    ?assert(check_if_called({linc_us3_actions, apply_list, 2})).

clear_actions() ->
    ?assert(unimplemented).

write_actions() ->
    ?assert(unimplemented).

write_metadata() ->
    ?assert(unimplemented).

goto_table() ->
    GotoInstruction = create_goto_table(5),
    ?assertEqual({{goto, 5}, pkt},
                 linc_us3_instructions:apply(pkt, [GotoInstruction])).

empty() ->
    ?assertEqual({stop, pkt}, linc_us3_instructions:apply(pkt, [])).

%% Fixtures --------------------------------------------------------------------

setup() ->
    ok.

teardown(ok) ->
    ok.

%% Helpers ---------------------------------------------------------------------

create_apply_actions() ->
    #ofp_instruction_apply_actions{actions = []}.

create_goto_table(TableId) ->
    #ofp_instruction_goto_table{table_id = TableId}.
