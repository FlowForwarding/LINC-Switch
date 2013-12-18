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

-include_lib("eunit/include/eunit.hrl").

%% Tests -----------------------------------------------------------------------

switch_setup_test_() ->
    {timeout, 30,
     {setup,
      fun setup/0,
      fun teardown/1,
      [{"Start/stop LINC common logic", fun logic/0}]}}.

logic() ->
    %% As a logic backend we choose stub module 'linc_backend' from linc/test
    %% directory. It is required because Meck won't mock modules that don't
    %% exist.
    Backend = linc_backend,
    application:load(linc),
    %% application:set_env(linc, backend, Backend),
    Config = [{switch, SwitchId = 0,
               [{backend, Backend},
                {controllers, []},
                {controllers_listener, disabled},
                {ports, []},
                {queues_status, disabled},
                {queues, []}]}],
    application:set_env(linc, logical_switches, Config),
    application:set_env(linc, capable_switch_ports, []),
    application:set_env(linc, capable_switch_queues, []),
    meck:new(inet, [unstick, passthrough]),
    meck:expect(inet, getifaddrs, 0,
                {ok, [{"fake0",
                       [{flags,[up,broadcast,running,multicast]},
                        {hwaddr,[2,0,0,0,0,1]},
                        {addr,{192,168,1,1}},
                        {netmask,{255,255,255,0}},
                        {broadaddr,{192,168,1,255}}]}]}),
    meck:new(Backend),
    meck:expect(Backend, start, fun(_) -> {ok, version, state} end),
    meck:expect(Backend, stop, fun(_) -> ok end),
    ?assertEqual(ok, application:start(linc)),
    assert_linc_logic_is_running(SwitchId, 10),
    ?assertEqual(ok, application:stop(linc)),
    meck:unload(Backend),
    meck:unload(inet).

%% Fixtures --------------------------------------------------------------------

setup() ->
    error_logger:tty(false),
    ok = application:start(asn1),
    ok = application:start(public_key),
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
    ok = application:stop(public_key),
    ok = application:stop(asn1),
    ok = application:stop(ssh).

%% Helper functions ------------------------------------------------------------

assert_linc_logic_is_running(SwitchId, Retries) ->
    lists:takewhile(fun(_) ->
                          timer:sleep(300),
                          not is_pid(linc:lookup(SwitchId, linc_logic))
                  end, [ _TryNo || _TryNo <- lists:seq(1, Retries)]),
    ?assert(erlang:is_process_alive(linc:lookup(SwitchId, linc_logic))).
