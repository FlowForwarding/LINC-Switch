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

-define(LINC_BACKEND, linc_backend).

-define(INSTANITATOR(CommentTestPairs),
        fun(Value) ->
                [{C, fun() -> T(Value) end} || {C, T} <- CommentTestPairs]
        end).

-define(CAPABLE_PORTS(PortNums), [{port, No, [{interface, "dummy"}]}
                                  || No <- PortNums]).

-define(PORTS, {_Capable = ?CAPABLE_PORTS([1,2,3]),
                _Logical = [{port, 1, [{queues, []}, {port_no, 10}]},
                            {port, 2, [{queues, []}, {port_no, 11}]},
                            {port, 3, [{queues, []}]}]
               }).

-define(INCORRECT_PORTS_LIST,
        [{duplicated_capable_port_no,
          {?CAPABLE_PORTS([1,2]),
           [{port, 1, [{queues, []}, {port_no, 10}]},
            {port, 1, [{queues, []}, {port_no, 11}]}]
          }},
         {duplicated_logical_port_no,
          {?CAPABLE_PORTS([1,2]),
           [{port, 1, [{queues, []}, {port_no, 10}]},
            {port, 2, [{queues, []}, {port_no, 10}]}]
          }},
         {duplicated_logical_port_no,
          {?CAPABLE_PORTS([1,2]),
           %% Logical port_no defaults to capable port_no when port_no
           %% option is not present.
           [{port, 1, {queues, []}}, {port, 2, [{queues, []}, {port_no, 1}]}]
          }}]).

%% Tests -----------------------------------------------------------------------

backend_start_test_() ->
    {timeout, 30,
     {setup,
      fun backend_start_setup/0,
      fun backend_start_teardown/1,
      ?INSTANITATOR([{"Start/stop LINC common logic",
                      fun linc_logic_should_be_started/1}])
     }}.

port_mapping_test_() ->
    {foreach,
     fun port_mapping_setup/0,
     fun port_mapping_teardown/1,
     [?INSTANITATOR([{"Test capable to logical ports mapping",
                      fun capable_to_logical_ports_map_should_be_created/1}]),
      ?INSTANITATOR([{"Test capable to logical ports mapping without ports",
                      fun capable_to_logical_ports_map_should_be_empty/1}]),
      ?INSTANITATOR([{"Test capable to logical ports mapping badly defined",
                      fun capable_to_logical_ports_mapping_should_fail/1}])
     ]}.

linc_logic_should_be_started(SwitchId) ->
    %% GIVEN
    expect_linc_backend(),

    %% WHEN
    ?assertEqual(ok, application:start(linc)),

    %% THEN
    assert_linc_logic_is_running(SwitchId, 10),
    ?assertEqual(ok, application:stop(linc)).

capable_to_logical_ports_map_should_be_created(SwitchId) ->
    %% GIVEN
    set_ports({CapablePorts, LogicalPorts} = ?PORTS),
    ok = application:start(linc),

    %% WHEN
    assert_linc_logic_is_running(SwitchId, 10),

    %% THEN
    [begin
         LogicalPort = lists:keyfind(CapableNo, 2, LogicalPorts),
         assert_capable_port_mapped_correctly(CapableNo, SwitchId,
                                              LogicalPort)
     end || {port, CapableNo, _} <- CapablePorts].

capable_to_logical_ports_map_should_be_empty(SwitchId) ->
    %% GIVEN
    set_ports({[], []}),
    ok = application:start(linc),

    %% WHEN
    assert_linc_logic_is_running(SwitchId, 10),

    %% THEN
    ?assertEqual([], ets:tab2list(ports_map)).

capable_to_logical_ports_mapping_should_fail(_) ->
    [begin
         %% GIVEN
         set_ports(Ports),

         %% WHEN
         turn_lager_error_reports(off),
         Result = application:start(linc),
         turn_lager_error_reports(on),

         %% THEN
         ?assertMatch({error, {{bad_port_config, ExpectedFailReason}, _}},
                      Result)
     end || {ExpectedFailReason, Ports} <- ?INCORRECT_PORTS_LIST].

%% Fixtures --------------------------------------------------------------------

backend_start_setup() ->
    error_logger:tty(false),
    start_dependencies(),
    turn_lager_error_reports(on),
    mock_inet(),
    mock_backend(),
    setup_environment(?LINC_BACKEND, SwitchId = 1),
    SwitchId.

backend_start_teardown(_) ->
    unmock_inet(),
    unmock_backend(),
    application:unload(linc),
    stop_dependencies().

port_mapping_setup() ->
    SwitchId = backend_start_setup(),
    expect_linc_backend(),
    SwitchId.

port_mapping_teardown(State) ->
    case lists:keyfind(linc, 1, application:which_applications()) of
        {linc, _, _} ->
            ok = application:stop(linc);
        false ->
            ok
    end,
    ok = application:unload(linc),
    backend_start_teardown(State).

%% Helper functions ------------------------------------------------------------

start_dependencies() ->
    ok = application:start(asn1),
    ok = application:start(public_key),
    ok = application:start(ssh),
    ok = application:start(xmerl),
    ok = application:start(mnesia),
    ok = application:start(syntax_tools),
    ok = application:start(compiler),
    ok = application:start(netlink),
    ok = application:start(goldrush),
    ok = application:start(lager).

stop_dependencies() ->
    ok = application:stop(compiler),
    ok = application:stop(syntax_tools),
    ok = application:stop(mnesia),
    ok = application:stop(xmerl),
    ok = application:stop(lager),
    ok = application:stop(goldrush),
    ok = application:stop(netlink),
    ok = application:stop(public_key),
    ok = application:stop(asn1),
    ok = application:stop(ssh).

mock_inet() ->
    meck:new(inet, [unstick, passthrough]),
    meck:expect(inet, getifaddrs, 0,
                {ok, [{"fake0",
                       [{flags,[up,broadcast,running,multicast]},
                        {hwaddr,[2,0,0,0,0,1]},
                        {addr,{192,168,1,1}},
                        {netmask,{255,255,255,0}},
                        {broadaddr,{192,168,1,255}}]}]}).

mock_backend() ->
    %% As a logic backend we choose stub module 'linc_backend' from linc/test
    %% directory. It is required because Meck won't mock modules that don't
    %% exist.
    meck:new(?LINC_BACKEND).

unmock_backend() ->
    meck:unload(?LINC_BACKEND).

unmock_inet() ->
    meck:unload(inet).

setup_environment(Backend, SwitchId) ->
    Config = [{switch, SwitchId,
               [{backend, Backend},
                {controllers, []},
                {controllers_listener, disabled},
                {ports, []},
                {queues_status, disabled},
                {queues, []}]}],
    application:set_env(linc, logical_switches, Config),
    application:set_env(linc, capable_switch_ports, []),
    application:set_env(linc, capable_switch_queues, []).

expect_linc_backend() ->
    meck:expect(?LINC_BACKEND, start, fun(_) -> {ok, version, state} end),
    meck:expect(?LINC_BACKEND, stop, fun(_) -> ok end).

turn_lager_error_reports(off) ->
    ok = lager:set_loglevel(lager_console_backend, emergency);
turn_lager_error_reports(on) ->
    ok = lager:set_loglevel(lager_console_backend, error).

set_ports({CapablePorts, LogicalPorts}) ->
    set_capable_ports(CapablePorts),
    set_logical_ports(LogicalPorts).

set_logical_ports(LogicalPorts) ->
    {ok, [{switch, SwitchId, Opts0}]} = application:get_env(linc,
                                                           logical_switches),
    Opts1 = lists:keystore(ports, 1, Opts0, {ports, LogicalPorts}),
    application:set_env(linc, logical_switches, [{switch, SwitchId, Opts1}]).

set_capable_ports(CapablePorts) ->
    ok = application:set_env(linc, capable_switch_ports, CapablePorts).

assert_linc_logic_is_running(SwitchId, Retries) ->
    lists:takewhile(fun(_) ->
                          timer:sleep(300),
                          not is_pid(linc:lookup(SwitchId, linc_logic))
                  end, [ _TryNo || _TryNo <- lists:seq(1, Retries)]),
    ?assert(erlang:is_process_alive(linc:lookup(SwitchId, linc_logic))).

assert_capable_port_mapped_correctly(CapableNo, SwitchId, LogicalPort) ->
    {_,_, PortOpts} = LogicalPort,
    LogicalNo = proplists:get_value(port_no, PortOpts, CapableNo),
    ?assertMatch([[{SwitchId, LogicalNo}]],
                 ets:match(ports_map, {CapableNo, '$1'})).
