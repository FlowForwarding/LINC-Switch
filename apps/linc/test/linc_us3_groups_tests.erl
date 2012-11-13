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
-module(linc_us3_groups_tests).

-import(linc_test_utils, [mock/1,
                          unmock/1]).

-include_lib("eunit/include/eunit.hrl").
-include_lib("linc/include/linc_us3.hrl").

-define(MOCKED, [port, actions]).

%% Tests -----------------------------------------------------------------------

group_test_() ->
    {foreach,
     fun setup/0,
     fun teardown/1,
     [{"Add group", fun add_group/0},
      {"Modify group", fun modify_group/0},
      {"Delete group", fun delete_group/0}]}.

add_group() ->
    ?assert(unimplemented).

modify_group() ->
    ?assert(unimplemented).

delete_group() ->
    ?assert(unimplemented).

%% Fixtures --------------------------------------------------------------------

setup() ->
    mock(?MOCKED),
    %% linc_us3_groups:create(),
    ok.

teardown(ok) ->
    unmock(?MOCKED),
    %% linc_us3_groups:destroy(),
    ok.
