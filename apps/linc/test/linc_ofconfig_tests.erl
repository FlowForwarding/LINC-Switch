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
%% @copyright 2013 FlowForwarding.org
-module(linc_ofconfig_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("of_config/include/of_config.hrl").

-define(DATAPATH_ID, "00:00:00:00:00:00:00:0B").

-define(INSTANITATOR(CommentTestPairs),
        fun(Value) ->
                [{C, fun() -> T(Value) end} || {C, T} <- CommentTestPairs]
        end).

%% Generators ------------------------------------------------------------------

startup_format_without_ofconfig_test_() ->
    {setup,
     fun setup/0,
     fun teardown/1,
     [{foreach,
       fun load_environment_without_ofconfig/0,
       fun unload_environment/1,
       [{"Test startup for simple config",
         fun should_return_startup_with_generated_datapath_id/0},
        {"Test startup for simple config with datapath id",
         fun should_return_startup_with_datapath_id/0}]},
      {setup,
       fun load_environment_with_ports_without_ofconfig/0,
       fun unload_environment/1,
       ?INSTANITATOR([{"Test startup with two ports",
                       fun should_return_startup_with_ports/1}])},
      {setup,
       fun load_environment_with_ports_and_queues_without_ofconfig/0,
       fun unload_environment/1,
       ?INSTANITATOR([{"Test startup with one port with two queues",
                       fun should_return_startup_with_ports_and_queues/1}])},
      {setup,
       fun load_environment_with_extended_ports/0,
       fun unload_environment/1,
       ?INSTANITATOR([{"Test startup with extended ports config",
                       fun should_return_startup_with_extended_ports/1}])}
     ]}.

%% Tests -----------------------------------------------------------------------

should_return_startup_with_generated_datapath_id() ->
    ?assertMatch([{switch, 0, [{datapath_id, DatapathId},
                               {backend, linc_us4},
                               {controllers, []},
                               {controllers_listener, disabled},
                               {ports, []},
                               {queues_status, disabled},
                               {queues, []}]}]
                 when is_list(DatapathId) andalso length(DatapathId) == 23,
                      linc_ofconfig:get_startup_without_ofconfig()).

should_return_startup_with_datapath_id() ->
    %% GIVEN
    add_datapath_id_to_logical_switch_config(DatapathId = ?DATAPATH_ID),
    ExpectedConfig = [{switch, 0, [{backend, linc_us4},
                                   {controllers, []},
                                   {controllers_listener, disabled},
                                   {ports, []},
                                   {queues_status, disabled},
                                   {datapath_id, DatapathId},
                                   {queues, []}]}],

    %% WHEN
    ActualConfig = linc_ofconfig:get_startup_without_ofconfig(),

    %% THEN
    ?assertMatch(ExpectedConfig, ActualConfig).

should_return_startup_with_ports(CapableSwitchPorts) ->
    [{switch, _SwitchId, SwitchConfig}] =
        linc_ofconfig:get_startup_without_ofconfig(),
    Ports = proplists:get_value(ports, SwitchConfig),
    [?assertMatch({port, PortNo, [{config, #port_configuration{}},
                                  {features, #features{}},
                                  IntfTuple]},
                  lists:keyfind(PortNo, 2, Ports))
     || {port, PortNo, [IntfTuple]}  <- CapableSwitchPorts].

should_return_startup_with_ports_and_queues(LogicalSwitchPorts) ->
    [{switch, _SwitchId, SwitchConfig}] =
        linc_ofconfig:get_startup_without_ofconfig(),
    Queues = proplists:get_value(queues, SwitchConfig),
    [begin
         {port, ActualPortNo, PortOptsForQueues} = lists:keyfind(ExpectedPortNo,
                                                                 2, Queues),
         ?assert(ExpectedPortNo == ActualPortNo),
         ?assert(lists:keymember(port_rate, 1, PortOptsForQueues)),
         ?assert(lists:keymember(port_queues, 1, PortOptsForQueues)),
         assert_port_queues(ExpectedQueues, PortOptsForQueues)
     end || {port, ExpectedPortNo, [{queues, ExpectedQueues}]}
                <- LogicalSwitchPorts, ExpectedQueues /= []].

should_return_startup_with_extended_ports(LogicalSwitchPorts) ->
    %% GIVEN
    %% Logical switch ports has additional attributes: port_no
    %% and port name

    %% WHEN
    [{switch, _SwitchId, SwitchConfig}] =
        linc_ofconfig:get_startup_without_ofconfig(),

    %% THEN
    {ports, PortsConfig} = lists:keyfind(ports, 1, SwitchConfig),
    [begin
         {_, _, ActualOpts} = lists:keyfind(CapablePortNo, 2, PortsConfig),
         assert_logical_port_no_and_port_name(ExpectedOpts, ActualOpts)
     end || {port, CapablePortNo, ExpectedOpts} <- LogicalSwitchPorts].

assert_port_queues(ExpectedQueues, ActualPortOptsForQueues) ->
    ?assert(lists:all(fun({QueueId, QueueOpts}) ->
                              lists:member(QueueId, ExpectedQueues),
                              lists:keymember(min_rate, 1, QueueOpts),
                              lists:keymember(max_rate, 1, QueueOpts)
                      end, proplists:get_value(port_queues,
                                               ActualPortOptsForQueues))).

assert_logical_port_no_and_port_name(ExpectedOpts, ActualOpts) ->
    [?assertEqual(lists:keyfind(Opt, 1, ExpectedOpts),
                  lists:keyfind(Opt, 1, ActualOpts))
    || Opt <- [port_name, port_no]].

%% Fixtures --------------------------------------------------------------------

load_environment_without_ofconfig() ->
    CapableSwitchPorts = CapableSwitchQueues = LogicalSwitchPorts = [],
    load_environment_without_ofconfig(CapableSwitchPorts,
                                      CapableSwitchQueues,
                                      LogicalSwitchPorts).

load_environment_with_ports_without_ofconfig() ->
    CapableSwitchPorts = [{port, 1, [{interface, "eth0"}]},
                          {port, 2, [{interface, "eth1"}]}],
    LogicalSwitchPorts = [{port, 1, [{queues, []}]},
                          {port, 2, [{queues, []}]}],
    CapableSwitchQueues = [],
    load_environment_without_ofconfig(CapableSwitchPorts,
                                      CapableSwitchQueues,
                                      LogicalSwitchPorts),
    CapableSwitchPorts.

load_environment_with_ports_and_queues_without_ofconfig() ->
    CapableSwitchPorts = [{port, 1, [{interface, "eth0"}]}],
    CapableSwitchQueues = [{queue, 33, [{min_rate, 100}, {max_rate, 200}]},
                           {queue, 99, [{min_rate, 100}, {max_rate, 100}]}],
    LogicalSwitchPorts = [{port, 1, {queues, [33, 99]}}],
    load_environment_without_ofconfig(CapableSwitchPorts,
                                      CapableSwitchQueues,
                                      LogicalSwitchPorts),
    LogicalSwitchPorts.

load_environment_with_extended_ports() ->
    CapableSwitchPorts = [{port, 1, [{interface, "eth0"}]},
                          {port, 2, [{interface, "eth1"}]},
                          {port, 3, [{interface, "eth2"}]}],
    LogicalSwitchPorts =
        [{port, 1, [{queues, []}, {port_no, 100}, {port_name, "LAPIERRE"}]},
         {port, 2, [{queues, []}, {port_no, 100}, {port_name, "DEVINCI"}]},
         {port, 3, [{queues, []}]}],
    CapableSwitchQueues = [],
    load_environment_without_ofconfig(CapableSwitchPorts,
                                      CapableSwitchQueues,
                                      LogicalSwitchPorts),
    LogicalSwitchPorts.

unload_environment(_) ->
    application:unload(linc).

%% Helpers ----------------------------------------------------------------------

setup() ->
    meck:new(inet, [unstick, passthrough]),
    meck:expect(inet, getifaddrs, 0,
                {ok, [{"fake0",
                       [{flags,[up,broadcast,running,multicast]},
                        {hwaddr,[2,0,0,0,0,1]},
                        {addr,{192,168,1,1}},
                        {netmask,{255,255,255,0}},
                        {broadaddr,{192,168,1,255}}]}]}).

teardown(_) ->
    meck:unload().

load_environment_without_ofconfig(CapableSwitchPorts, CapableSwitchQueues,
                                  LogicalSwitchPorts) ->
    application:load(linc),
    application:set_env(linc, of_config, disabled),
    application:set_env(linc, capable_switch_ports, CapableSwitchPorts),
    application:set_env(linc, capable_switch_queues, CapableSwitchQueues),
    application:set_env(linc, logical_switches,
                        generate_logical_switch_config(CapableSwitchQueues,
                                                       LogicalSwitchPorts)).


generate_logical_switch_config(CapableSwitchQueues, LogicalSwitchPorts) ->
    [{switch, 0,
      [{backend, linc_us4},
       {controllers, []},
       {controllers_listener, disabled},
       {ports, LogicalSwitchPorts},
       {queues_status, case CapableSwitchQueues of
                           [] ->
                               disabled;
                           _ ->
                               enabled
                       end}]}].

add_datapath_id_to_logical_switch_config(DatapathId) ->
    {ok, [{switch, 0, Opts0}]} = application:get_env(linc,
                                                     logical_switches),
    Opts1 = lists:keystore(datapath_id, 1, Opts0,
                           {datapath_id, DatapathId}),
    ok = application:set_env(linc, logical_switches,
                             [{switch, 0, Opts1}]).
