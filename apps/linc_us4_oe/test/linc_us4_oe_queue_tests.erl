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
-module(linc_us4_oe_queue_tests).

-import(linc_us4_oe_test_utils, [mock/1,
                              unmock/1,
                              check_if_called/1]).

-include_lib("of_config/include/of_config.hrl").
-include_lib("of_protocol/include/of_protocol.hrl").
-include_lib("of_protocol/include/ofp_v4.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("linc_us4_oe.hrl").

-define(MOCKED, [port_native]).
-define(SWITCH_ID, 0).

%% Tests -----------------------------------------------------------------------

queue_test_() ->
    {setup,
     fun setup/0,
     fun teardown/1,
     [{"Port multipart: queue_stats_request", fun queue_stats_request/0},
      {"Sending through queue", fun sending/0},
      {"Set queue property: min-rate", fun min_rate/0},
      {"Set queue property: max-rate", fun max_rate/0}
     ]}.

queue_stats_request() ->
    BadPort = 999,
    BadQueue = 999,
    ValidQueue = 1,
    ValidPort = 1,

    StatsRequest1 = #ofp_queue_stats_request{port_no = BadPort,
                                             queue_id = BadQueue},
    StatsReply1 = linc_us4_oe_queue:get_stats(?SWITCH_ID, StatsRequest1),
    ?assertEqual(#ofp_error_msg{type = queue_op_failed, code = bad_port},
                 StatsReply1),

    StatsRequest2 = #ofp_queue_stats_request{port_no = ValidPort,
                                             queue_id = BadQueue},
    StatsReply2 = linc_us4_oe_queue:get_stats(?SWITCH_ID, StatsRequest2),
    ?assertEqual(#ofp_error_msg{type = queue_op_failed, code = bad_queue},
                 StatsReply2),
    StatsRequest3 = #ofp_queue_stats_request{port_no = ValidPort,
                                             queue_id = ValidQueue},
    StatsReply3 = linc_us4_oe_queue:get_stats(?SWITCH_ID, StatsRequest3),
    ?assertMatch(#ofp_queue_stats_reply{}, StatsReply3),
    [QueueStats] = StatsReply3#ofp_queue_stats_reply.body,
    ?assertEqual(0, QueueStats#ofp_queue_stats.duration_sec),
    ?assertNot(QueueStats#ofp_queue_stats.duration_nsec == 0),

    StatsRequest4 = #ofp_queue_stats_request{port_no = ValidPort,
                                             queue_id = all},
    StatsReply4 = linc_us4_oe_queue:get_stats(?SWITCH_ID, StatsRequest4),
    ?assertMatch(#ofp_queue_stats_reply{}, StatsReply4),
    ?assertEqual(2, length(StatsReply4#ofp_queue_stats_reply.body)),

    StatsRequest5 = #ofp_queue_stats_request{port_no = any,
                                             queue_id = 1},
    StatsReply5 = linc_us4_oe_queue:get_stats(?SWITCH_ID, StatsRequest5),
    ?assertMatch(#ofp_queue_stats_reply{}, StatsReply5),
    ?assertEqual(1, length(StatsReply5#ofp_queue_stats_reply.body)),

    StatsRequest6 = #ofp_queue_stats_request{port_no = any,
                                             queue_id = all},
    StatsReply6 = linc_us4_oe_queue:get_stats(?SWITCH_ID, StatsRequest6),
    ?assertMatch(#ofp_queue_stats_reply{}, StatsReply6),
    ?assertEqual(2, length(StatsReply6#ofp_queue_stats_reply.body)).

sending() ->
    PortId = 1,
    QueueId = 1,
    ?assertEqual(ok, linc_us4_oe_queue:send(?SWITCH_ID, PortId, QueueId, <<>>)).

min_rate() ->
    PortId = 1,
    QueueId = 1,
    %% set min-rate as 50% of current port-rate (100kb/s)
    ?assertEqual(ok,
                 linc_us4_oe_queue:set_min_rate(?SWITCH_ID, PortId, QueueId, 500)).

max_rate() ->
    PortId = 1,
    QueueId = 1,
    %% set max-rate as 50% of current port-rate (100kb/s)
    ?assertEqual(ok,
                 linc_us4_oe_queue:set_max_rate(?SWITCH_ID, PortId, QueueId, 500)).

%% Fixtures --------------------------------------------------------------------

ports() ->
    [{port, 1, [{interface, "dummy1"},
                {features, #features{}},
                {config, #port_configuration{}}]},
     {port, 2, [{interface, "dummy2"},
                {features, #features{}},
                {config, #port_configuration{}}]}].

ports_with_queues() ->
    %% Port 1 with two explicit queues
    %% Port 2 with implicit default queue
    Queues = [{port, 1, [{port_rate, {100, kbps}},
                         {port_queues, [{1, [{min_rate, 100}, {max_rate, 100}]},
                                        {2, [{min_rate, 100}, {max_rate, 100}]}
                                       ]}]}],
    Ports = ports(),
    [{switch, 0, [{ports, Ports},
                  {queues_status, enabled},
                  {queues, Queues}]}].

setup() ->
    mock(?MOCKED),
    linc:create(?SWITCH_ID),
    {ok, Pid} = linc_us4_oe_sup:start_link(?SWITCH_ID),
    Config = ports_with_queues(),
    application:load(linc),
    application:set_env(linc, logical_switches, Config),
    linc_us4_oe_port:initialize(?SWITCH_ID, Config),
    Pid.

teardown(Pid) ->
    linc_us4_oe_port:terminate(?SWITCH_ID),
    linc:delete(?SWITCH_ID),

    unlink(Pid),
    Ref = monitor(process, Pid),
    exit(Pid, shutdown),
    receive {'DOWN', Ref, _, _, _} -> ok end,

    unmock(?MOCKED).
