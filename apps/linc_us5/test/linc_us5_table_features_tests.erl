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
-module(linc_us5_table_features_tests).

-include_lib("of_protocol/include/of_protocol.hrl").
-include_lib("of_protocol/include/ofp_v5.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("linc_us5/include/linc_us5.hrl").

-define(MOCKED, []).

%% Tests -----------------------------------------------------------------------
table_features_test_() ->
    {setup,
     fun setup/0,
     fun teardown/1,
     [{"Get table features", fun get_table_features/0}
      ,{"Set missing features", fun set_missing_feature/0}
      ,{"Set duplicate features", fun set_duplicate_feature/0}
      ,{"Set bad table id", fun set_bad_table_id/0}
      ,{"Set features", fun set_features/0}
     ]}.

get_table_features() ->
    Req = #ofp_table_features_request{body=[]},
    ?assertMatch(#ofp_table_features_reply{}, linc_us5_table_features:handle_req(0, Req, #monitor_data{})).

set_missing_feature() ->
    FeaturesList = [#ofp_table_feature_prop_instructions{}
                    , #ofp_table_feature_prop_next_tables{}
                    %% , #ofp_table_feature_prop_write_actions{}
                    , #ofp_table_feature_prop_apply_actions{}
                    , #ofp_table_feature_prop_match{}
                    , #ofp_table_feature_prop_wildcards{}
                    , #ofp_table_feature_prop_write_setfield{}
                    , #ofp_table_feature_prop_apply_setfield{}
                   ],
    Req = #ofp_table_features_request{
             body=[#ofp_table_features{table_id=0,
                                       properties=FeaturesList}]},
    ?assertMatch(#ofp_error_msg{ type=table_features_failed, code=bad_argument },
                 linc_us5_table_features:handle_req(0, Req, #monitor_data{})).

set_duplicate_feature() ->
    FeaturesList = [#ofp_table_feature_prop_instructions{}
                    , #ofp_table_feature_prop_next_tables{}
                    , #ofp_table_feature_prop_write_actions{}
                    , #ofp_table_feature_prop_apply_actions{} % Duplicate this
                    , #ofp_table_feature_prop_apply_actions{} % Duplicate this
                    , #ofp_table_feature_prop_match{}
                    , #ofp_table_feature_prop_wildcards{}
                    , #ofp_table_feature_prop_write_setfield{}
                    , #ofp_table_feature_prop_apply_setfield{}
                   ],
    Req = #ofp_table_features_request{
             body=[#ofp_table_features{table_id=0,
                                       properties=FeaturesList}]},
    ?assertMatch(#ofp_error_msg{ type=table_features_failed, code=bad_argument },
                 linc_us5_table_features:handle_req(0, Req, #monitor_data{})).

set_bad_table_id() ->
    FeaturesList = [#ofp_table_feature_prop_instructions{}
                    , #ofp_table_feature_prop_next_tables{}
                    , #ofp_table_feature_prop_write_actions{}
                    , #ofp_table_feature_prop_apply_actions{}
                    , #ofp_table_feature_prop_match{}
                    , #ofp_table_feature_prop_wildcards{}
                    , #ofp_table_feature_prop_write_setfield{}
                    , #ofp_table_feature_prop_apply_setfield{}
                   ],
    Req = #ofp_table_features_request{
             body=[#ofp_table_features{table_id=all,
                                       properties=FeaturesList}]},
    ?assertMatch(#ofp_error_msg{ type=table_features_failed, code=bad_table },
                 linc_us5_table_features:handle_req(0, Req, #monitor_data{})).

set_features() ->
    FeaturesList = [#ofp_table_feature_prop_instructions{}
                    , #ofp_table_feature_prop_next_tables{}
                    , #ofp_table_feature_prop_write_actions{}
                    , #ofp_table_feature_prop_apply_actions{}
                    , #ofp_table_feature_prop_match{}
                    , #ofp_table_feature_prop_wildcards{}
                    , #ofp_table_feature_prop_write_setfield{}
                    , #ofp_table_feature_prop_apply_setfield{}
                   ],
    Req = #ofp_table_features_request{
             body=[#ofp_table_features{table_id=0,
                                       properties=FeaturesList}]},
    ?assertMatch(#ofp_table_features_reply{}, linc_us5_table_features:handle_req(0, Req, #monitor_data{})).

%% Fixtures --------------------------------------------------------------------
setup() ->
    ets:new(linc_switch_0, [named_table, public]),
    [
     ets:insert(linc_switch_0,
                {list_to_atom("flow_table_" ++ integer_to_list(Table)),
                 ets:new(flow_table, [])})
     || Table <- lists:seq(0, ?OFPTT_MAX)
    ],
    {ok, Pid} = linc_us5_flow:start_link(0),
    Pid.

teardown(Pid) ->
    unlink(Pid),
    exit(Pid, kill),
    ets:foldl(fun({_, Tid}, _) -> is_integer(Tid) andalso ets:delete(Tid) end, ignored, linc_switch_0),
    ets:delete(linc_switch_0),
    ok.

%% Helpers ---------------------------------------------------------------------
