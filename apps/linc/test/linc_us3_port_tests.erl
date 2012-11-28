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
-module(linc_us3_port_tests).

-import(linc_test_utils, [mock/1,
                          unmock/1,
                          check_if_called/1,
                          check_output_on_ports/0]).

-include_lib("eunit/include/eunit.hrl").
-include_lib("linc/include/linc_us3.hrl").
-include_lib("pkt/include/pkt.hrl").

-define(MOCKED, []).

%% Tests -----------------------------------------------------------------------

port_test_() ->
    {setup,
     fun setup/0,
     fun teardown/1,
     [
      {"Port: create/destroy", fun create_destroy/0},
      {"Port config: no_fwd", fun empty/0},
      {"Port config: no_pkt_in", fun empty/0},
      {"Port config: port_down", fun empty/0}
     ]}.

create_destroy() ->
    {ok, _Pid} = linc_us3_port_sup:start_link(),
    meck:new(linc_us3_port_native),
    meck:expect(linc_us3_port_native, eth, fun(_) -> {socket, 0, pid} end),
    meck:expect(linc_us3_port_native, close, fun(_) -> ok end),
    application:set_env(linc, backends, [{userspace, [{ports, [{1, [{interface, "dummy0"}]}]}]}]),
    ok = linc_us3_port:initialize(),
    ok = linc_us3_port:terminate(),
    meck:unload(linc_us3_port_native).

empty() ->
    ok.

%% Fixtures --------------------------------------------------------------------

setup() ->
    %% application:set_env(linc, backends, [{userspace, [{ports, []}]}]),
    %% ok = linc_us3_port:initialize(),
    mock(?MOCKED).

teardown(_) ->
    %% ok = linc_us3_port:terminate(),
    unmock(?MOCKED).
