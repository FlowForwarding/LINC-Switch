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

-import(linc_us3_test_utils, [mock/1,
                              unmock/1,
                              check_if_called/1,
                              check_output_on_ports/0]).

-include_lib("of_config/include/of_config.hrl").
-include_lib("of_protocol/include/of_protocol.hrl").
-include_lib("of_protocol/include/ofp_v3.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("pkt/include/pkt.hrl").
-include("linc_us3.hrl").

-define(MOCKED, [logic, port_native]).
-define(SWITCH_ID, 0).

%% Tests -----------------------------------------------------------------------

port_test_() ->
    {setup, fun setup/0, fun teardown/1,
     {foreach, fun foreach_setup/0, fun foreach_teardown/1,
      [
       {"Port: port_mod", fun port_mod/0},
       {"Port: is_valid", fun is_valid/0},
       {"Port send: in_port", fun send_in_port/0},
       {"Port send: table", fun send_table/0},
       {"Port send: normal", fun send_normal/0},
       {"Port send: flood", fun send_flood/0},
       {"Port send: all", fun send_all/0},
       {"Port send: controller", fun send_controller/0},
       {"Port send: local", fun send_local/0},
       {"Port send: any", fun send_any/0},
       {"Port send: port number", fun send_port_number/0},
       {"Port stats: port_stats_request", fun port_stats_request/0},
       {"Port config: port_down", fun config_port_down/0},
       {"Port config: no_recv", fun config_no_recv/0},
       {"Port config: no_fwd", fun config_no_fwd/0},
       {"Port config: no_pkt_in", fun config_no_pkt_in/0},
       {"Port state: link_down", fun state_link_down/0},
       {"Port state: blocked", fun state_blocked/0},
       {"Port state: live", fun state_live/0},
       {"Port features: change advertised features", fun advertised_features/0}
      ]}}.

port_mod() ->
    BadPort = 999,
    PortMod1 = #ofp_port_mod{port_no = BadPort},
    Error1 = {error, {bad_request, bad_port}},
    ?assertEqual(Error1, linc_us3_port:modify(?SWITCH_ID, PortMod1)),

    Port = 1,
    BadHwAddr = <<2,2,2,2,2,2>>,
    PortMod2 = #ofp_port_mod{port_no = Port, hw_addr = BadHwAddr},
    ?assertEqual({error, {port_mod_failed, bad_hw_addr}},
                 linc_us3_port:modify(?SWITCH_ID, PortMod2)),

    HwAddr = <<1,1,1,1,1,1>>,
    PortMod3 = #ofp_port_mod{port_no = Port, hw_addr = HwAddr,
                             config = [], mask = [],
                             advertise = [copper, autoneg]},
    ?assertEqual(ok, linc_us3_port:modify(?SWITCH_ID, PortMod3)),
    ok.

is_valid() ->
    ?assertEqual(true, linc_us3_port:is_valid(?SWITCH_ID, any)),
    ?assertEqual(true, linc_us3_port:is_valid(?SWITCH_ID, 1)),
    ?assertEqual(false, linc_us3_port:is_valid(?SWITCH_ID, 999)).

send_in_port() ->
    Pkt = pkt(1),
    ?assertEqual(ok, linc_us3_port:send(Pkt, in_port)).

send_table() ->
    meck:new(linc_us3_routing),
    meck:expect(linc_us3_routing, spawn_route, fun(_) -> ok end),
    ?assertEqual(ok, linc_us3_port:send(pkt(), table)),
    meck:unload(linc_us3_routing).

send_normal() ->
    ?assertEqual(bad_port, linc_us3_port:send(pkt(), normal)).

send_flood() ->
    ?assertEqual(bad_port, linc_us3_port:send(pkt(), flood)).

send_all() ->
    ?assertEqual(ok, linc_us3_port:send(pkt(), all)),
    %% wait because send to port is a gen_server:cast
    timer:sleep(500),
    ?assertEqual(2, meck:num_calls(linc_us3_port_native, send, '_')).

send_controller() ->
    ?assertEqual(ok, linc_us3_port:send(pkt(controller,no_match), controller)).

send_local() ->
    ?assertEqual(bad_port, linc_us3_port:send(pkt(), local)).

send_any() ->
    ?assertEqual(bad_port, linc_us3_port:send(pkt(), any)).

send_port_number() ->
    ?assertEqual(ok, linc_us3_port:send(pkt(), 1)).

port_stats_request() ->
    BadPort = 999,
    StatsRequest1 = #ofp_port_stats_request{port_no = BadPort},
    ?assertEqual(#ofp_error_msg{type = bad_request, code = bad_port},
                 linc_us3_port:get_stats(?SWITCH_ID, StatsRequest1)),

    ValidPort = 1,
    StatsRequest2 = #ofp_port_stats_request{port_no = ValidPort},
    StatsReply2 = linc_us3_port:get_stats(?SWITCH_ID, StatsRequest2),
    ?assertEqual(1, length(StatsReply2#ofp_port_stats_reply.stats)),

    AllPorts = any,
    StatsRequest3 = #ofp_port_stats_request{port_no = AllPorts},
    StatsReply3 = linc_us3_port:get_stats(?SWITCH_ID, StatsRequest3),
    ?assertEqual(2, length(StatsReply3#ofp_port_stats_reply.stats)).

config_port_down() ->
    ?assertEqual([], linc_us3_port:get_config(?SWITCH_ID, 1)),
    ?assertEqual(ok, linc_us3_port:set_config(?SWITCH_ID, 1, [port_down])),
    ?assertEqual(1, meck:num_calls(linc_logic, send_to_controllers, '_')),
    ?assertEqual([port_down], linc_us3_port:get_config(?SWITCH_ID, 1)).

config_no_recv() ->
    ?assertEqual([], linc_us3_port:get_config(?SWITCH_ID, 1)),
    ?assertEqual(ok, linc_us3_port:set_config(?SWITCH_ID, 1, [no_recv])),
    ?assertEqual(1, meck:num_calls(linc_logic, send_to_controllers, '_')),
    ?assertEqual([no_recv], linc_us3_port:get_config(?SWITCH_ID, 1)).

config_no_fwd() ->
    ?assertEqual([], linc_us3_port:get_config(?SWITCH_ID, 1)),
    ?assertEqual(ok, linc_us3_port:set_config(?SWITCH_ID, 1, [no_fwd])),
    ?assertEqual(1, meck:num_calls(linc_logic, send_to_controllers, '_')),
    ?assertEqual([no_fwd], linc_us3_port:get_config(?SWITCH_ID, 1)).

config_no_pkt_in() ->
    ?assertEqual([], linc_us3_port:get_config(?SWITCH_ID, 1)),
    ?assertEqual(ok, linc_us3_port:set_config(?SWITCH_ID, 1, [no_pkt_in])),
    ?assertEqual(1, meck:num_calls(linc_logic, send_to_controllers, '_')),
    ?assertEqual([no_pkt_in], linc_us3_port:get_config(?SWITCH_ID, 1)).

state_link_down() ->
    ?assertEqual([live], linc_us3_port:get_state(?SWITCH_ID, 1)),
    ?assertEqual(ok, linc_us3_port:set_state(?SWITCH_ID, 1, [link_down])),
    ?assertEqual(1, meck:num_calls(linc_logic, send_to_controllers, '_')),
    ?assertEqual([link_down], linc_us3_port:get_state(?SWITCH_ID, 1)).

state_blocked() ->
    ?assertEqual([live], linc_us3_port:get_state(?SWITCH_ID, 1)),
    ?assertEqual(ok, linc_us3_port:set_state(?SWITCH_ID, 1, [blocked])),
    ?assertEqual(1, meck:num_calls(linc_logic, send_to_controllers, '_')),
    ?assertEqual([blocked], linc_us3_port:get_state(?SWITCH_ID, 1)).

state_live() ->
    ?assertEqual([live], linc_us3_port:get_state(?SWITCH_ID, 1)),
    ?assertEqual(ok, linc_us3_port:set_state(?SWITCH_ID, 1, [live])),
    ?assertEqual(1, meck:num_calls(linc_logic, send_to_controllers, '_')),
    ?assertEqual([live], linc_us3_port:get_state(?SWITCH_ID, 1)).

advertised_features() ->
    FeatureSet1 = [other],
    FeatureSet2 = [copper, autoneg],
    ?assertEqual(ok,
                 linc_us3_port:set_advertised_features(?SWITCH_ID, 1,
                                                       FeatureSet1)),
    ?assertEqual(FeatureSet1,
                 linc_us3_port:get_advertised_features(?SWITCH_ID, 1)),
    ?assertEqual(ok,
                 linc_us3_port:set_advertised_features(?SWITCH_ID, 1,
                                                       FeatureSet2)),
    ?assertEqual(FeatureSet2,
                 linc_us3_port:get_advertised_features(?SWITCH_ID, 1)).

%% Fixtures --------------------------------------------------------------------

ports() ->
    [{port, 1, [{interface, "dummy1"},
                {features, #features{}},
                {config, #port_configuration{}}]},
     {port, 2, [{interface, "dummy2"},
                {features, #features{}},
                {config, #port_configuration{}}]}].

ports_without_queues() ->
    Ports = ports(),
    [{switch, 0, [{ports, Ports},
                  {queues_status, disabled},
                  {queues, []}]}].

setup() ->
    mock(?MOCKED),
    linc:create(?SWITCH_ID),
    linc_us3_test_utils:add_logic_path(),
    {ok, _Pid} = linc_us3_sup:start_link(?SWITCH_ID),
    Config = ports_without_queues(),
    application:load(linc),
    application:set_env(linc, logical_switches, Config).

teardown(_) ->
    linc:delete(?SWITCH_ID),
    unmock(?MOCKED).

foreach_setup() ->
    ok = meck:reset(linc_logic),
    ok = meck:reset(linc_us3_port_native),
    {ok, Switches} = application:get_env(linc, logical_switches),
    ok = linc_us3_port:initialize(?SWITCH_ID, Switches).

foreach_teardown(_) ->
    ok = linc_us3_port:terminate(?SWITCH_ID).

pkt() ->
    #linc_pkt{packet = [<<>>]}.

pkt(Port) ->
    #linc_pkt{in_port = Port, packet = [<<>>]}.

pkt(controller=Port,Reason) ->
    #linc_pkt{in_port = Port, packet_in_reason=Reason, packet = [<<>>]}.
