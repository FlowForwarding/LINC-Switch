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
-module(linc_us4_queue_tests).

-import(linc_us4_test_utils, [mock/1,
                              unmock/1,
                              check_if_called/1]).

-include_lib("of_protocol/include/of_protocol.hrl").
-include_lib("of_protocol/include/ofp_v4.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("linc_us4.hrl").

-define(MOCKED, [port_native]).
-define(SWITCH_ID, 0).

%% Tests -----------------------------------------------------------------------

queue_test_() ->
    {setup,
     fun setup/0,
     fun teardown/1,
     [{"Port multipart: queue_stats_request", fun queue_stats_request/0},
      {"Sending through queue", fun sending/0}]}.

queue_stats_request() ->
    BadPort = 999,
    BadQueue = 999,
    ValidQueue = 1,
    ValidPort = 1,

    StatsRequest1 = #ofp_queue_stats_request{port_no = BadPort,
                                             queue_id = BadQueue},
    StatsReply1 = linc_us4_queue:get_stats(?SWITCH_ID, StatsRequest1),
    ?assertEqual(#ofp_error_msg{type = bad_request, code = bad_port},
                 StatsReply1),

    StatsRequest2 = #ofp_queue_stats_request{port_no = ValidPort,
                                             queue_id = BadQueue},
    StatsReply2 = linc_us4_queue:get_stats(?SWITCH_ID, StatsRequest2),
    ?assertEqual(#ofp_error_msg{type = bad_request, code = bad_queue},
                 StatsReply2),

    StatsRequest3 = #ofp_queue_stats_request{port_no = ValidPort,
                                             queue_id = ValidQueue},
    StatsReply3 = linc_us4_queue:get_stats(?SWITCH_ID, StatsRequest3),
    ?assertMatch(#ofp_queue_stats_reply{}, StatsReply3),
    [QueueStats] = StatsReply3#ofp_queue_stats_reply.body,
    ?assertEqual(0, QueueStats#ofp_queue_stats.duration_sec),
    ?assertNot(QueueStats#ofp_queue_stats.duration_nsec == 0),

    StatsRequest4 = #ofp_queue_stats_request{port_no = ValidPort,
                                             queue_id = all},
    StatsReply4 = linc_us4_queue:get_stats(?SWITCH_ID, StatsRequest4),
    ?assertMatch(#ofp_queue_stats_reply{}, StatsReply4),
    ?assertEqual(2, length(StatsReply4#ofp_queue_stats_reply.body)),

    StatsRequest5 = #ofp_queue_stats_request{port_no = any,
                                             queue_id = 1},
    StatsReply5 = linc_us4_queue:get_stats(?SWITCH_ID, StatsRequest5),
    ?assertMatch(#ofp_queue_stats_reply{}, StatsReply5),
    ?assertEqual(1, length(StatsReply5#ofp_queue_stats_reply.body)),

    StatsRequest6 = #ofp_queue_stats_request{port_no = any,
                                             queue_id = all},
    StatsReply6 = linc_us4_queue:get_stats(?SWITCH_ID, StatsRequest6),
    ?assertMatch(#ofp_queue_stats_reply{}, StatsReply6),
    ?assertEqual(2, length(StatsReply6#ofp_queue_stats_reply.body)).

sending() ->
    ok.

%% Fixtures --------------------------------------------------------------------

setup() ->
    mock(?MOCKED),
    linc:create(?SWITCH_ID),
    {ok, _Pid} = linc_us4_sup:start_link(?SWITCH_ID),
    Queues = [{port, 1, [{port_rate, {100, kbps}},
                         {port_queues, [{1, [{min_rate, 100}, {max_rate, 100}]},
                                        {2, [{min_rate, 100}, {max_rate, 100}]}
                                       ]}]}],
    Backend = {linc_us4, [{ports, [{1, [{interface, "dummy1"}]},
                                   {2, [{interface, "dummy2"}]}]},
                          {queues_status, enabled},
                          {queues, Queues}
                         ]},
    application:set_env(linc, backends_opts, [Backend]),
    linc_us4_port:initialize(?SWITCH_ID),
    ok.

teardown(ok) ->
    linc_us4_port:terminate(?SWITCH_ID),
    unmock(?MOCKED),
    ok.
