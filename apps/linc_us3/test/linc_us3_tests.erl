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
-module(linc_us3_tests).

-include_lib("eunit/include/eunit.hrl").

%% Tests -----------------------------------------------------------------------

-define(TIMEOUT, 300).

switch_setup_test_() ->
    {setup,
     fun setup/0,
     fun teardown/1,
     [
      {"Start/stop LINC v3 switch backend w/o OF-Config subsystem",
       fun no_ofconfig/0},
      {"Start/stop LINC v3 switch backend with OF-Config subsystem",
       fun with_ofconfig/0}
     ]}.

no_ofconfig() ->
    application:load(linc),
    application:set_env(linc, of_config, disabled),
    Config = [{switch, 0,
               [{backend, linc_us3},
                {controllers, []},
                {ports, []},
                {queues_status, disabled},
                {queues, []}]}],
    application:set_env(linc, logical_switches, Config),

    [begin
         ?assertEqual(ok, application:start(linc)),
         timer:sleep(?TIMEOUT),
         ?assertEqual(ok, application:stop(linc))
     end || _ <- [lists:seq(1,10)]].

with_ofconfig() ->
    %% Default sshd port is 830 and requires root or cap_net_admin capability
    %% on the beam to open the port, thus we change it to value above 1024.
    application:load(linc),
    application:set_env(enetconf, sshd_port, 1830),
    application:set_env(linc, of_config, enabled),
    application:set_env(linc, backend, linc_us3),

    [begin
         ?assertEqual(ok, application:start(linc)),
         timer:sleep(?TIMEOUT),
         ?assertEqual(ok, application:stop(linc))
     end || _ <- [lists:seq(1,10)]].

%% Fixtures --------------------------------------------------------------------

setup() ->
    linc_us3_test_utils:add_logic_path(),
    error_logger:tty(false),
    ok = application:start(ssh),
    ok = application:start(xmerl),
    ok = application:start(mnesia),
    ok = application:start(syntax_tools),
    ok = application:start(compiler),
    ok = application:start(lager),
    ok = lager:set_loglevel(lager_console_backend, error).

teardown(_) ->
    ok = application:stop(compiler),
    ok = application:stop(syntax_tools),
    ok = application:stop(mnesia),
    ok = application:stop(xmerl),
    ok = application:stop(lager),
    ok = application:stop(ssh).
