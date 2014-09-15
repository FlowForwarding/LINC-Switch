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
%% @doc Unit tests for the per-flow meters module.
-module(linc_us4_oe_meter_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("of_protocol/include/ofp_v4.hrl").
-include("linc_us4_oe.hrl").

-define(MOD, linc_us4_oe_meter).
-define(ID, 1).

%% Tests -----------------------------------------------------------------------

meters_test_() ->
    [{"Initilize/Terminate", fun() ->
                                     Config = setup(),
                                     teardown(Config)
                             end},
     {"Get features", fun get_features/0},
     {"Meter Modification and Multiparts",
      {foreach,
       fun setup/0,
       fun teardown/1,
       [{"Add", fun add/0},
        {"Add when already exists", fun add_twice/0},
        {"Add with bad flags", fun add_bad_flags/0},
        {"Add with unsupported band", fun add_bad_band/0},
        {"Add with pktps value", fun add_with_pktps/0},
        {"Add with no value (kbps default)", fun add_with_no_value/0},
        {"Add with both kbps and pktps", fun add_with_two_values/0},
        {"Add with burst", fun add_with_burst/0},
        {"Add with burst and pktps", fun add_with_burst_pktps/0},
        {"Modify", fun modify/0},
        {"Modify non-existing", fun modify_nonexisting/0},
        {"Modify with bad_flags", fun modify_bad_flags/0},
        {setup,
         fun() -> meck:new(linc_us4_oe_flow),
                  meck:expect(linc_us4_oe_flow, delete_where_meter,
                              fun(_, _) -> ok end) end,
         fun(_) -> meck:unload(linc_us4_oe_flow) end,
         [{"Delete", fun delete/0},
          {"Delete non-existing", fun delete_nonexisting/0},
          {"Delete all", fun delete_all/0}]},
        {"Get config, no meters", fun get_config_none/0},
        {"Get stats, no meters", fun get_stats_none/0},
        {"Get stats, stats disabled", fun get_stats_disabled/0},
        {"Update flow count", fun update_flow_count/0}
       ]}},
     {"Applying Meters",
      {foreach,
       fun setup/0,
       fun teardown/1,
       [{"Apply meter, no match", fun apply_none/0},
        {"Apply meter, drop", fun apply_drop/0},
        {setup,
         fun() -> meck:new(linc_us4_oe_packet),
                  meck:expect(linc_us4_oe_packet, decrement_dscp,
                              fun(Pkt, _) -> Pkt end) end,
         fun(_) -> meck:unload(linc_us4_oe_packet) end,
         [{"Apply meter, dscp_remark", fun apply_dscp/0}]},
        {"Apply meter, experimenter", fun apply_experimenter/0},
        {"Apply meter, pktps", fun apply_pktps/0},
        {"Apply meter, burst/kbps", fun apply_burst_kbps/0},
        {"Apply meter, burst/pktps", fun apply_burst_pktps/0}
       ]}}
    ].

%% Tests -----------------------------------------------------------------------

get_features() ->
    Features = ?MOD:get_features(),
    ?assert(is_record(Features, ofp_meter_features_reply)).

add() ->
    add(1).

add(MeterId) ->
    Bands = [#ofp_meter_band_drop{rate = 200},
             #ofp_meter_band_dscp_remark{rate = 100,
                                         prec_level = 1},
             #ofp_meter_band_dscp_remark{rate = 150,
                                         prec_level = 2},
             #ofp_meter_band_experimenter{rate = 50,
                                          experimenter = 123}],
    MeterMod = #ofp_meter_mod{command = add,
                              flags = [kbps, stats],
                              meter_id = MeterId,
                              bands = Bands},
    ?assertEqual(noreply, ?MOD:modify(?ID, MeterMod)),
    ?assert(?MOD:is_valid(?ID, MeterId)),
    ExpectedConfig = meter_config([MeterMod]),
    ?assertEqual(ExpectedConfig, ?MOD:get_config(?ID, MeterId)).

add_twice() ->
    add(),
    MeterMod = #ofp_meter_mod{command = add,
                              flags = [kbps, stats],
                              meter_id = 1,
                              bands = []},
    Error = #ofp_error_msg{type = meter_mod_failed,
                           code = meter_exists},
    ?assertEqual({reply, Error}, ?MOD:modify(?ID, MeterMod)),
    ?assert(?MOD:is_valid(?ID, 1)).

add_with_pktps() ->
    MeterMod = #ofp_meter_mod{command = add,
                              flags = [pktps, stats],
                              meter_id = 1,
                              bands = []},
    ?assertEqual(noreply, ?MOD:modify(?ID, MeterMod)),
    ?assert(?MOD:is_valid(?ID, 1)),
    ?assertEqual(meter_config([MeterMod]), ?MOD:get_config(?ID, 1)).

add_with_no_value() ->
    MeterMod = #ofp_meter_mod{command = add,
                              flags = [stats],
                              meter_id = 1,
                              bands = []},
    ?assertEqual(noreply, ?MOD:modify(?ID, MeterMod)),
    ?assert(?MOD:is_valid(?ID, 1)),
    MeterMod2 = MeterMod#ofp_meter_mod{flags = [kbps, stats]},
    ?assertEqual(meter_config([MeterMod2]), ?MOD:get_config(?ID, 1)).

add_with_two_values() ->
    MeterMod = #ofp_meter_mod{command = add,
                              flags = [kbps, pktps],
                              meter_id = 1,
                              bands = []},
    Error = #ofp_error_msg{type = meter_mod_failed,
                           code = bad_flags},
    ?assertEqual({reply, Error}, ?MOD:modify(?ID, MeterMod)),
    ?assertNot(?MOD:is_valid(?ID, 1)).

add_bad_flags() ->
    MeterMod = #ofp_meter_mod{command = add,
                              flags = [kbps, bad_flag, stats],
                              meter_id = 1,
                              bands = []},
    Error = #ofp_error_msg{type = meter_mod_failed,
                           code = bad_flags},
    ?assertEqual({reply, Error}, ?MOD:modify(?ID, MeterMod)),
    ?assertNot(?MOD:is_valid(?ID, 1)).

add_bad_band() ->
    Bands = [#ofp_meter_band_drop{rate = 200},
             bad_meter_band,
             #ofp_meter_band_dscp_remark{rate = 100,
                                         prec_level = 1}],
    MeterMod = #ofp_meter_mod{command = add,
                              flags = [kbps, stats],
                              meter_id = 1,
                              bands = Bands},
    Error = #ofp_error_msg{type = meter_mod_failed,
                           code = bad_band},
    ?assertEqual({reply, Error}, ?MOD:modify(?ID, MeterMod)),
    ?assertNot(?MOD:is_valid(?ID, 1)).

add_with_burst() ->
    Bands = [#ofp_meter_band_drop{burst_size = 2, rate = 1}],
    MeterMod = #ofp_meter_mod{command = add,
                              flags = [kbps, burst, stats],
                              meter_id = 1,
                              bands = Bands},
    ?assertEqual(noreply, ?MOD:modify(?ID, MeterMod)),
    ?assert(?MOD:is_valid(?ID, 1)),
    ExpectedConfig = meter_config([MeterMod]),
    ?assertEqual(ExpectedConfig, ?MOD:get_config(?ID, 1)),
    ?assertEqual(ExpectedConfig, ?MOD:get_config(?ID, all)).

add_with_burst_pktps() ->
    Bands = [#ofp_meter_band_drop{burst_size = 30, rate = 5}],
    MeterMod = #ofp_meter_mod{command = add,
                              flags = [pktps, burst, stats],
                              meter_id = 1,
                              bands = Bands},
    ?assertEqual(noreply, ?MOD:modify(?ID, MeterMod)),
    ?assert(?MOD:is_valid(?ID, 1)),
    ExpectedConfig = meter_config([MeterMod]),
    ?assertEqual(ExpectedConfig, ?MOD:get_config(?ID, 1)),
    ?assertEqual(ExpectedConfig, ?MOD:get_config(?ID, all)).

modify() ->
    add(),
    MeterMod = #ofp_meter_mod{command = modify,
                              meter_id = 1,
                              flags = [kbps],
                              bands = []},
    ?assertEqual(noreply, ?MOD:modify(?ID, MeterMod)),
    ?assert(?MOD:is_valid(?ID, 1)),
    ?assertEqual(meter_config([MeterMod]), ?MOD:get_config(?ID, 1)).

modify_nonexisting() ->
    MeterMod = #ofp_meter_mod{command = modify,
                              meter_id = 1,
                              flags = [pktps],
                              bands = []},
    Error = #ofp_error_msg{type = meter_mod_failed,
                           code = unknown_meter},
    ?assertEqual({reply, Error}, ?MOD:modify(?ID, MeterMod)),
    ?assertNot(?MOD:is_valid(?ID, 1)).

modify_bad_flags() ->
    add(),
    MeterMod = #ofp_meter_mod{command = modify,
                              meter_id = 1,
                              flags = [pktps, bad_flag, stats],
                              bands = []},
    Error = #ofp_error_msg{type = meter_mod_failed,
                           code = bad_flags},
    ?assertEqual({reply, Error}, ?MOD:modify(?ID, MeterMod)),
    ?assert(?MOD:is_valid(?ID, 1)).

delete() ->
    add(),
    MeterMod = #ofp_meter_mod{command = delete,
                              meter_id = 1,
                              flags = [],
                              bands = []},
    ?assertEqual(noreply, ?MOD:modify(?ID, MeterMod)),
    ?assertNot(?MOD:is_valid(?ID, 1)).

delete_nonexisting() ->
    MeterMod = #ofp_meter_mod{command = delete,
                              meter_id = 1,
                              flags = [],
                              bands = []},
    ?assertEqual(noreply, ?MOD:modify(?ID, MeterMod)),
    ?assertNot(?MOD:is_valid(?ID, 1)).

delete_all() ->
    add(1),
    add(2),
    MeterMod = #ofp_meter_mod{command = delete,
                              meter_id = all,
                              flags = [],
                              bands = []},
    ?assertEqual(noreply, ?MOD:modify(?ID, MeterMod)),
    ?assertNot(?MOD:is_valid(?ID, 1)),
    ?assertNot(?MOD:is_valid(?ID, 2)).

get_config_none() ->
    ?assertEqual(meter_config([]), ?MOD:get_config(?ID, all)),
    ?assertEqual(meter_config([]), ?MOD:get_config(?ID, 1)).

get_stats_none() ->
    ?assertEqual(#ofp_meter_stats_reply{body = []}, ?MOD:get_stats(?ID, all)),
    ?assertEqual(#ofp_meter_stats_reply{body = []}, ?MOD:get_stats(?ID, 1)).

get_stats_disabled() ->
    Bands = [#ofp_meter_band_drop{rate = 200}],
    MeterMod = #ofp_meter_mod{command = add,
                              flags = [kbps],
                              meter_id = 1,
                              bands = Bands},
    ?assertEqual(noreply, ?MOD:modify(?ID, MeterMod)),

    #ofp_meter_stats_reply{body = [Stats]} = ?MOD:get_stats(?ID, 1),
    ?assertEqual(-1, Stats#ofp_meter_stats.flow_count),
    ?assertEqual(-1, Stats#ofp_meter_stats.packet_in_count),
    ?assertEqual(-1, Stats#ofp_meter_stats.byte_in_count),
    [Band] = Stats#ofp_meter_stats.band_stats,
    ?assertEqual(-1, Band#ofp_meter_band_stats.packet_band_count),
    ?assertEqual(-1, Band#ofp_meter_band_stats.byte_band_count).

update_flow_count() ->
    add(),

    #ofp_meter_stats_reply{body = [Stats1]} = ?MOD:get_stats(?ID, 1),
    ?assertEqual(0, Stats1#ofp_meter_stats.flow_count),

    ?MOD:update_flow_count(?ID, 1, 1),

    #ofp_meter_stats_reply{body = [Stats2]} = ?MOD:get_stats(?ID, 1),
    ?assertEqual(1, Stats2#ofp_meter_stats.flow_count).

apply_none() ->
    add(),

    #ofp_meter_stats_reply{body = [Stats1]} = ?MOD:get_stats(?ID, 1),
    ?assertEqual(0, Stats1#ofp_meter_stats.packet_in_count),
    ?assertEqual(0, Stats1#ofp_meter_stats.byte_in_count),

    Pkt = #linc_pkt{size = 1},
    ?assertEqual({continue, Pkt}, ?MOD:apply(?ID, 1, Pkt)),

    #ofp_meter_stats_reply{body = [Stats2]} = ?MOD:get_stats(?ID, 1),
    ?assertEqual(1, Stats2#ofp_meter_stats.packet_in_count),
    ?assertEqual(1, Stats2#ofp_meter_stats.byte_in_count).

apply_drop() ->
    add(),

    Pkt = #linc_pkt{size = 30000},
    ?assertEqual(drop, ?MOD:apply(?ID, 1, Pkt)),

    #ofp_meter_stats_reply{body = [Stats]} = ?MOD:get_stats(?ID, 1),
    [Drop, _, _, _] = Stats#ofp_meter_stats.band_stats,
    ?assertEqual(1, Stats#ofp_meter_stats.packet_in_count),
    ?assertEqual(30000, Stats#ofp_meter_stats.byte_in_count),
    ?assertEqual(1, Drop#ofp_meter_band_stats.packet_band_count),
    ?assertEqual(30000, Drop#ofp_meter_band_stats.byte_band_count).

apply_dscp() ->
    add(),

    Pkt = #linc_pkt{size = 15000},
    ?assertEqual(continue, element(1, ?MOD:apply(?ID, 1, Pkt))),

    #ofp_meter_stats_reply{body = [Stats]} = ?MOD:get_stats(?ID, 1),
    [_, Dscp, _, _] = Stats#ofp_meter_stats.band_stats,
    ?assertEqual(1, Stats#ofp_meter_stats.packet_in_count),
    ?assertEqual(15000, Stats#ofp_meter_stats.byte_in_count),
    ?assertEqual(1, Dscp#ofp_meter_band_stats.packet_band_count),
    ?assertEqual(15000, Dscp#ofp_meter_band_stats.byte_band_count).

apply_experimenter() ->
    add(),

    Pkt = #linc_pkt{size = 7500},
    ?assertEqual(continue, element(1, ?MOD:apply(?ID, 1, Pkt))),

    #ofp_meter_stats_reply{body = [Stats]} = ?MOD:get_stats(?ID, 1),
    [_, _, _, Exp] = Stats#ofp_meter_stats.band_stats,
    ?assertEqual(1, Stats#ofp_meter_stats.packet_in_count),
    ?assertEqual(7500, Stats#ofp_meter_stats.byte_in_count),
    ?assertEqual(1, Exp#ofp_meter_band_stats.packet_band_count),
    ?assertEqual(7500, Exp#ofp_meter_band_stats.byte_band_count).

apply_pktps() ->
    Bands = [#ofp_meter_band_drop{rate = 2}],
    MeterMod = #ofp_meter_mod{command = add,
                              flags = [pktps, stats],
                              meter_id = 1,
                              bands = Bands},
    ?assertEqual(noreply, ?MOD:modify(?ID, MeterMod)),

    Pkt1 = #linc_pkt{size = 200},
    ?assertEqual(continue, element(1, ?MOD:apply(?ID, 1, Pkt1))),
    Pkt2 = #linc_pkt{size = 300},
    ?assertEqual(continue, element(1, ?MOD:apply(?ID, 1, Pkt2))),
    Pkt3 = #linc_pkt{size = 500},
    ?assertEqual(drop, ?MOD:apply(?ID, 1, Pkt3)),

    #ofp_meter_stats_reply{body = [Stats]} = ?MOD:get_stats(?ID, 1),
    [Drop] = Stats#ofp_meter_stats.band_stats,
    ?assertEqual(3, Stats#ofp_meter_stats.packet_in_count),
    ?assertEqual(1000, Stats#ofp_meter_stats.byte_in_count),
    ?assertEqual(1, Drop#ofp_meter_band_stats.packet_band_count),
    ?assertEqual(500, Drop#ofp_meter_band_stats.byte_band_count).

apply_burst_kbps() ->
    add_with_burst(),

    %% Test sending a packet that should be allowed because it is
    %% smaller than the burst size, even though it exceeds the rate
    %% limit:
    SmallPkt = #linc_pkt{size = 240},
    ?assertMatch({continue, _}, ?MOD:apply(?ID, 1, SmallPkt)),

    %% Now send a packet that exceeds both the burst size and the
    %% configured rate.
    Pkt = #linc_pkt{size = 10000},
    ?assertEqual(drop, ?MOD:apply(?ID, 1, Pkt)),

    #ofp_meter_stats_reply{body = [Stats]} = ?MOD:get_stats(?ID, 1),
    [Drop] = Stats#ofp_meter_stats.band_stats,
    ?assertEqual(2, Stats#ofp_meter_stats.packet_in_count),
    ?assertEqual(10240, Stats#ofp_meter_stats.byte_in_count),
    ?assertEqual(1, Drop#ofp_meter_band_stats.packet_band_count),
    ?assertEqual(10000, Drop#ofp_meter_band_stats.byte_band_count).

apply_burst_pktps() ->
    add_with_burst_pktps(),

    Pkt1 = #linc_pkt{size = 100},
    [?assertMatch({continue, _}, ?MOD:apply(?ID, 1, Pkt1))
     || _ <- lists:seq(1, 30)],

    Pkt31 = #linc_pkt{size = 200},
    ?assertEqual(drop, ?MOD:apply(?ID, 1, Pkt31)),

    #ofp_meter_stats_reply{body = [Stats]} = ?MOD:get_stats(?ID, 1),
    [Drop] = Stats#ofp_meter_stats.band_stats,
    ?assertEqual(31, Stats#ofp_meter_stats.packet_in_count),
    ?assertEqual(3200, Stats#ofp_meter_stats.byte_in_count),
    ?assertEqual(1, Drop#ofp_meter_band_stats.packet_band_count),
    ?assertEqual(200, Drop#ofp_meter_band_stats.byte_band_count).

%% Fixtures --------------------------------------------------------------------

setup() ->
    linc:create(?ID),
    {ok, Pid} = linc_us4_oe_meter_sup:start_link(?ID),
    unlink(Pid),
    Pid.

teardown(Pid) ->
    linc_us4_oe_meter_sup:stop(?ID),
    wait_for_teardown(Pid),
    ets:delete(linc_switch_1).

%% Helpers ---------------------------------------------------------------------

wait_for_teardown(Pid) ->
    case is_process_alive(Pid) of
        true ->
            timer:sleep(10),
            wait_for_teardown(Pid);
        false ->
            ok
    end.

meter_config(MeterMods) ->
    Meters = [#ofp_meter_config{flags = Flags,
                                meter_id = Id,
                                bands = Bands}
              || #ofp_meter_mod{meter_id = Id,
                                flags = Flags,
                                bands = Bands} <- MeterMods],
    #ofp_meter_config_reply{body = Meters}.
