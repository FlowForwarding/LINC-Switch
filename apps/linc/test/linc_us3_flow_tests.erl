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
-include_lib("of_protocol/include/of_protocol.hrl").
-include_lib("of_protocol/include/ofp_v3.hrl").

%% Tests -----------------------------------------------------------------------

flow_mod_test_() ->
    {foreach,
     fun setup/0,
     fun teardown/1,
     [{"Add simple flow", fun add_simple_flow/0},
      {"Modify some flow", fun modify_flow/0}]}.

add_simple_flow() ->
    %% FlowModAdd = #ofp_flow_mod{...
    %% linc_us3_flow:modify(FlowModAdd),
    %% Check if the flow was added correctly...
    ?assert(unimplemented).

modify_flow() ->
    ?assert(unimplemented).

%% Fixtures --------------------------------------------------------------------

setup() ->
    %% linc_us3_flow:create(),
    ok.

teardown(ok) ->
    %% linc_us3_flow:destroy(),
    ok.

%% Helpers ---------------------------------------------------------------------
