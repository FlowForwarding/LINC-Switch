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
-module(linc_us4_port_tests).

-import(linc_us4_test_utils, [mock/1,
                              unmock/1,
                              check_if_called/1,
                              check_output_on_ports/0]).

-include_lib("eunit/include/eunit.hrl").
-include_lib("pkt/include/pkt.hrl").
-include("linc_us4.hrl").

-define(MOCKED, [port_native]).

%% Tests -----------------------------------------------------------------------

port_test_() ->
    {foreach,
     fun setup/0,
     fun teardown/1,
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
      {"Port stats: queue_stats_request", fun queue_stats_request/0},
      {"Port config: port_down", fun config_port_down/0},
      {"Port config: no_recv", fun config_no_recv/0},
      {"Port config: no_fwd", fun config_no_fwd/0},
      {"Port config: no_pkt_in", fun config_no_pkt_in/0},
      {"Port state: link_down", fun state_link_down/0},
      {"Port state: blocked", fun state_blocked/0},
      {"Port state: live", fun state_live/0}
     ]}.

port_mod() ->
    BadPort = 999,
    PortMod1 = #ofp_port_mod{port_no = BadPort},
    Error1 = {error, {bad_request, bad_port}},
    ?assertEqual(Error1, linc_us4_port:modify(PortMod1)),

    Port = 1,
    BadHwAddr = <<2,2,2,2,2,2>>,
    PortMod2 = #ofp_port_mod{port_no = Port, hw_addr = BadHwAddr},
    ?assertEqual({error, {bad_request, bad_hw_addr}},
                 linc_us4_port:modify(PortMod2)),

    HwAddr = <<1,1,1,1,1,1>>,
    PortMod3 = #ofp_port_mod{port_no = Port, hw_addr = HwAddr,
                             config = [], mask = [],
                             advertise = [copper, autoneg]},
    ?assertEqual(ok, linc_us4_port:modify(PortMod3)),
    ok.

is_valid() ->
    ?assertEqual(true, linc_us4_port:is_valid(1)),
    ?assertEqual(false, linc_us4_port:is_valid(999)).

send_in_port() ->
    Pkt = pkt(1),
    ?assertEqual(ok, linc_us4_port:send(Pkt, in_port)).

send_table() ->
    meck:new(linc_us4_routing),
    meck:expect(linc_us4_routing, spawn_route, fun(_) -> ok end),
    ?assertEqual(ok, linc_us4_port:send(pkt(), table)),
    meck:unload(linc_us4_routing).

send_normal() ->
    ?assertEqual(bad_port, linc_us4_port:send(pkt(), normal)).

send_flood() ->
    ?assertEqual(bad_port, linc_us4_port:send(pkt(), flood)).

send_all() ->
    ?assertEqual(ok, linc_us4_port:send(pkt(), all)).
    %% ?assertEqual(2, meck:num_calls(linc_us4_port_native, send, '_')).

send_controller() ->
    ?assertEqual(ok, linc_us4_port:send(#ofp_port_status{}, controller)),
    ?assertEqual(ok, linc_us4_port:send(pkt(controller,no_match), controller)).

send_local() ->
    ?assertEqual(bad_port, linc_us4_port:send(pkt(), local)).

send_any() ->
    ?assertEqual(bad_port, linc_us4_port:send(pkt(), any)).

send_port_number() ->
    ?assertEqual(ok, linc_us4_port:send(pkt(), 1)).

port_stats_request() ->
    BadPort = 999,
    StatsRequest1 = #ofp_port_stats_request{port_no = BadPort},
    ?assertEqual(#ofp_error_msg{type = bad_request, code = bad_port},
                 linc_us4_port:get_stats(StatsRequest1)),

    ValidPort = 1,
    StatsRequest2 = #ofp_port_stats_request{port_no = ValidPort},
    StatsReply2 = linc_us4_port:get_stats(StatsRequest2),
    ?assertEqual(1, length(StatsReply2#ofp_port_stats_reply.stats)),

    AllPorts = all,
    StatsRequest3 = #ofp_port_stats_request{port_no = AllPorts},
    StatsReply3 = linc_us4_port:get_stats(StatsRequest3),
    ?assertEqual(2, length(StatsReply3#ofp_port_stats_reply.stats)),

    ok.

queue_stats_request() ->
    BadPort = 999,
    BadQueue = 999,
    ValidPort = 1,

    StatsRequest1 = #ofp_queue_stats_request{port_no = BadPort,
                                             queue_id = BadQueue},
    StatsReply1 = linc_us4_port:get_queue_stats(StatsRequest1),
    ?assertEqual(#ofp_error_msg{type = bad_request, code = bad_port},
                 StatsReply1),

    StatsRequest2 = #ofp_queue_stats_request{port_no = ValidPort,
                                             queue_id = BadQueue},
    StatsReply2 = linc_us4_port:get_queue_stats(StatsRequest2),
    ?assertEqual(#ofp_error_msg{type = bad_request, code = bad_queue},
                 StatsReply2),

    ok.

config_port_down() ->
    ?assertEqual([], linc_us4_port:get_config(1)),
    ?assertEqual(ok, linc_us4_port:set_config(1, [port_down])),
    ?assertEqual([port_down], linc_us4_port:get_config(1)).

config_no_recv() ->
    ?assertEqual([], linc_us4_port:get_config(1)),
    ?assertEqual(ok, linc_us4_port:set_config(1, [no_recv])),
    ?assertEqual([no_recv], linc_us4_port:get_config(1)).

config_no_fwd() ->
    ?assertEqual([], linc_us4_port:get_config(1)),
    ?assertEqual(ok, linc_us4_port:set_config(1, [no_fwd])),
    ?assertEqual([no_fwd], linc_us4_port:get_config(1)).

config_no_pkt_in() ->
    ?assertEqual([], linc_us4_port:get_config(1)),
    ?assertEqual(ok, linc_us4_port:set_config(1, [no_pkt_in])),
    ?assertEqual([no_pkt_in], linc_us4_port:get_config(1)).

state_link_down() ->
    ?assertEqual([live], linc_us4_port:get_state(1)),
    ?assertEqual(ok, linc_us4_port:set_state(1, [link_down])),
    ?assertEqual([link_down], linc_us4_port:get_state(1)).

state_blocked() ->
    ?assertEqual([live], linc_us4_port:get_state(1)),
    ?assertEqual(ok, linc_us4_port:set_state(1, [blocked])),
    ?assertEqual([blocked], linc_us4_port:get_state(1)).

state_live() ->
    ?assertEqual([live], linc_us4_port:get_state(1)),
    ?assertEqual(ok, linc_us4_port:set_state(1, [live])),
    ?assertEqual([live], linc_us4_port:get_state(1)).

%% Fixtures --------------------------------------------------------------------

setup() ->
    mock(?MOCKED),
    catch linc_us4_port_sup:start_link(),
    UserspaceBackend = {userspace, [{ports, [{1, [{interface, "dummy1"}]},
                                             {2, [{interface, "dummy2"}]}
                                            ]}]},
    application:set_env(linc, backends, [UserspaceBackend]),
    ok = linc_us4_port:initialize().

teardown(_) ->
    ok = linc_us4_port:terminate(),
    unmock(?MOCKED).

pkt() ->
    #ofs_pkt{packet = [<<>>]}.

pkt(Port) ->
    #ofs_pkt{in_port = Port, packet = [<<>>]}.

pkt(controller=Port,Reason) ->
    #ofs_pkt{in_port = Port, packet_in_reason=Reason, packet = [<<>>]}.
