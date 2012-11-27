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
-module(linc_tests).

-import(linc_test_utils, [mock/1,
                          unmock/1,
                          check_if_called/1,
                          check_output_on_ports/0]).

-include_lib("eunit/include/eunit.hrl").
-include_lib("linc/include/linc_us3.hrl").
-include_lib("pkt/include/pkt.hrl").

-define(MOCKED, []).

%% Tests -----------------------------------------------------------------------

switch_setup_test_() ->
    {setup,
     fun setup/0,
     fun teardown/1,
     [{"Start/stop LINC switch w/o OF-Config subsystem", fun no_ofconfig/0},
      {"Start/stop LINC switch with OF-Config subsystem", fun with_ofconfig/0}
     ]}.

no_ofconfig() ->
    application:set_env(linc, of_config, disabled),
    application:set_env(linc, backend, {linc_us3, []}),
    ?assertEqual(ok, application:start(linc)),
    ?assertEqual(ok, application:stop(linc)).

with_ofconfig() ->
    %% Default sshd port is 830 and requires root or cap_net_admin capability 
    %% on the beam to open the port, thus we change it to value above 1024.
    application:set_env(enetconf, sshd_port, 1830),
    application:set_env(linc, of_config, enabled),
    application:set_env(linc, backend, {linc_us3, []}),
    ?assertEqual(ok, application:start(linc)),
    ?assertEqual(ok, application:stop(linc)).

%% Fixtures --------------------------------------------------------------------

setup() ->
    error_logger:tty(false),
    ok = application:start(xmerl),
    ok = application:start(mnesia),
    ok = application:start(syntax_tools),
    ok = application:start(compiler),
    ok = application:start(lager),
    ok = lager:set_loglevel(lager_console_backend, error),
    mock(?MOCKED).

teardown(_) ->
    ok = application:stop(compiler),
    ok = application:stop(syntax_tools),
    ok = application:stop(mnesia),
    ok = application:stop(xmerl),
    ok = application:stop(lager),
    unmock(?MOCKED).

