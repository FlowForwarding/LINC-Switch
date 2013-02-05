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
-module(linc_buffer_tests).

-include_lib("of_protocol/include/of_protocol.hrl").
-include_lib("eunit/include/eunit.hrl").

-define(SWITCH_ID, 0).

%% Tests -----------------------------------------------------------------------

flow_mod_test_() ->
    {foreach,
     fun setup/0,
     fun teardown/1,
     [{"Get when empty", fun get_empty/0}
      ,{"Save and get", fun save_and_get/0}
      ,{"Expiration", fun expiration/0}
     ]}.

get_empty() ->
    ?assertEqual(not_found, linc_buffer:get_buffer(?SWITCH_ID, 1)).

save_and_get() ->
    Pkt = {test,some,more},
    BufferId = linc_buffer:save_buffer(?SWITCH_ID, Pkt),
    ?assertMatch(Pkt, linc_buffer:get_buffer(?SWITCH_ID, BufferId)).

expiration() ->
    Pkt = {test, some, more},
    BufferId = linc_buffer:save_buffer(?SWITCH_ID, Pkt),
    ?assertMatch(Pkt, linc_buffer:get_buffer(?SWITCH_ID, BufferId)),
    timer:sleep(3500),
    ?assertEqual(not_found, linc_buffer:get_buffer(?SWITCH_ID, BufferId)).

%% Fixtures --------------------------------------------------------------------
setup() ->
    linc:create(?SWITCH_ID),
    linc_buffer:initialize(?SWITCH_ID).

teardown(State) ->
    linc:delete(?SWITCH_ID),
    linc_buffer:terminate(State).

%% Helpers ---------------------------------------------------------------------
