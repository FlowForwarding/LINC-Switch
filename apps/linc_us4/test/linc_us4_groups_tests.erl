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
-module(linc_us4_groups_tests).

-import(linc_us4_test_utils, [mock/1,
                              unmock/1]).

-include_lib("of_protocol/include/of_protocol.hrl").
-include_lib("of_protocol/include/ofp_v4.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("linc_us4.hrl").

-define(MOCKED, [flow, port]).
-define(SWITCH_ID, 0).

%%%
%%% Tests -----------------------------------------------------------------------
%%%

group_test_() ->
    {setup, fun setup/0, fun teardown/1,
     {foreach, fun foreach_setup/0, fun foreach_teardown/1,
      [{"Add group",        fun add_group/0},
       {"Add invalid group", add_invalid_group()},
       {"Modify group",     fun modify_group/0},
       {"Delete group",     fun delete_group/0},
       {"Chain deletion",   fun chain_delete_group/0},
       {"Apply to packet",  fun apply_to_packet/0},
       {"Stats & features", fun stats_and_features/0},
       {"is_valid",         fun is_valid/0}
      ]}}.

%% TODO: Test 32 and 64bit counters wrapping to 0

%%--------------------------------------------------------------------
add_group() ->
    Bkt1 = make_test_bucket(2),
    M1 = call_group_mod(add, 1, all, [Bkt1]),
    ?assertEqual(ok, M1),
    ?assertEqual(true, group_exists(1)),

    linc_us4_groups:update_reference_count(?SWITCH_ID, 1, 333),

    %% Inserting duplicate group should fail
    MDup = call_group_mod(add, 1, all, []),
    ?assertMatch({error, #ofp_error_msg{}}, MDup),

    %% check that counters are zero
    G1Stats = linc_us4_groups:get_stats(?SWITCH_ID,
                                        #ofp_group_stats_request{ group_id = 1 }),
    ?assertEqual(333, stats_get(G1Stats, 1, reference_count)),
    ?assertEqual(0, stats_get(G1Stats, 1, packet_count)),
    ?assertEqual(0, stats_get(G1Stats, 1, byte_count)),

    %% check that time elapsed isn't zero
    G1StatsTime = stats_get(G1Stats, 1, time),
    ?assert(0 < G1StatsTime),

    %% send a random package
    Pkt2 = test_packet_vlan(),
    linc_us4_groups:apply(1, Pkt2),

    %% check that counters changed
    G2Stats = linc_us4_groups:get_stats(?SWITCH_ID,
                                        #ofp_group_stats_request{ group_id = 1 }),
    ?assertEqual(1, stats_get(G2Stats, 1, packet_count)),

    %% Sleep 1 msec and assert that group stats time is advanced by atleast 1000 microsec
    timer:sleep(1),
    G3Stats = linc_us4_groups:get_stats(?SWITCH_ID,
                                        #ofp_group_stats_request{ group_id = 1 }),
    G2StatsTime = stats_get(G2Stats, 1, time),
    G3StatsTime = stats_get(G3Stats, 1, time),
    ?assertMatch(_ when G2StatsTime + 1000 =< G3StatsTime, {G2StatsTime, G3StatsTime}),

    ?assertEqual(Pkt2#linc_pkt.size, stats_get(G2Stats, 1, byte_count)).

add_invalid_group() ->
    OfpgAny = any,
    OfpgAll = all,
    InvalidGroupId = 16#ffffff0a,

    [{Description,
      inorder,
      [?_assertMatch({error, #ofp_error_msg{}},
                     call_group_mod(add, GroupId, all, [])),
       ?_assertNot(group_exists(GroupId))]}
     || {Description, GroupId} <-
            [{"adding group with id OFPG_ALL should give an error",
              OfpgAll},
             {"adding group with id OFPG_ANY should give an error",
              OfpgAny},
             {"adding group with id greater than OFPG_MAX should give an error",
              InvalidGroupId}]].

%%--------------------------------------------------------------------
modify_group() ->
    B1 = make_test_bucket(),
    M1 = call_group_mod(add, 1, all, [B1]),
    ?assertEqual(ok, M1),

    %% Duplicate group should fail
    M1Err = call_group_mod(add, 1, all, [B1]),
    ?assertMatch({error, #ofp_error_msg{}}, M1Err),

    %% Modifying non existing group should fail
    MUnk = call_group_mod(modify, 12345, all, []),
    ?assertMatch({error, #ofp_error_msg{}}, MUnk),

    %% Modify group, bucket counters should reset
    %% Send a modify group
    M2 = call_group_mod(modify, 1, all, [B1]),
    ?assertEqual(ok, M2),

    %% Send a modify nonexisting group
    M3 = call_group_mod(modify, 222, all, [B1]),
    ?assertMatch({error, _}, M3).

%%--------------------------------------------------------------------
delete_group() ->
    M1 = call_group_mod(add, 1, all, []),
    ?assertEqual(ok, M1),
    ?assertEqual(true, group_exists(1)),

    M2 = call_group_mod(delete, 1, undefined, []),
    ?assertEqual(ok, M2),
    ?assertEqual(false, group_exists(1)),

    %% Deleting a nonexisting group produces no error
    M3 = call_group_mod(delete, 1, undefined, []),
    ?assertEqual(ok, M3),

    %% Trying delete all
    M4 = call_group_mod(add, 2, all, []),
    ?assertEqual(ok, M4),
    ?assertEqual(true, group_exists(2)),

    M5 = call_group_mod(delete, all, all, []),
    ?assertEqual(false, group_exists(2)),
    ?assertEqual(ok, M5).

%%--------------------------------------------------------------------
%% @doc Create 3 chained groups then delete first, ensure all 3 are gone
chain_delete_group() ->
    %% add group 10003 which doesn't refer to any other
    CM3 = call_group_mod(add, 10003, all, []),
    ?assertEqual(ok, CM3),

    %% add group 10002 which refers to 10003
    CB2 = make_test_bucket(10003),
    CM2 = call_group_mod(add, 10002, all, [CB2]),
    ?assertEqual(ok, CM2),

    %% add group 10001 which refers to 10002
    CB1 = make_test_bucket(10002),
    CM1 = call_group_mod(add, 10001, all, [CB1]),
    ?assertEqual(ok, CM1),

    ?assertEqual(true, group_exists(10001)),
    ?assertEqual(true, group_exists(10002)),
    ?assertEqual(true, group_exists(10003)),

    %% delete group 10003 which is chain-referred by 10001->10002->10003
    CM4 = call_group_mod(delete, 10003, all, []),
    ?assertEqual(ok, CM4),
    ?assertEqual(false, group_exists(10001)),
    ?assertEqual(false, group_exists(10002)),
    ?assertEqual(false, group_exists(10003)).

%%--------------------------------------------------------------------
%% @doc Test various paths for packet inside Groups module, this should
%% add a big percent to coverage
apply_to_packet() ->
    %% A random packet
    Pkt = test_packet_vlan(),

    %% Apply to nonexisting group is not an error, makes no effect
    ?assertEqual(ok, linc_us4_groups:apply(12345, Pkt)),

    B1 = make_test_bucket(),

    %% try SELECT group type
    M1 = call_group_mod(add, 2, select, [B1]),
    ?assertEqual(ok, M1),
    ?assertEqual(ok, linc_us4_groups:apply(2, Pkt)),

    %% try INDIRECT group type
    M2 = call_group_mod(add, 3, indirect, [B1]),
    ?assertEqual(ok, M2),
    ?assertEqual(ok, linc_us4_groups:apply(3, Pkt)),

    %% test FF with empty bucket list
    M41 = call_group_mod(add, 41, ff, []),
    ?assertEqual(ok, M41),
    ?assertEqual(ok, linc_us4_groups:apply(41, Pkt)),

    %% test FF with nonempty bucket list
    M42 = call_group_mod(add, 42, ff, [B1]),
    ?assertEqual(ok, M42),
    ?assertEqual(ok, linc_us4_groups:apply(42, Pkt)).

%%--------------------------------------------------------------------
stats_and_features() ->
    %% create test group
    B1 = make_test_bucket(),
    M1 = call_group_mod(add, 1, select, [B1]),
    ?assertEqual(ok, M1),

    D1 = linc_us4_groups:get_desc(?SWITCH_ID, #ofp_group_desc_request{}),
    ?assertMatch(#ofp_group_desc_reply{}, D1),

    D2 = linc_us4_groups:get_features(#ofp_group_features_request{}),
    ?assertMatch(#ofp_group_features_reply{}, D2),

    S1 = linc_us4_groups:get_stats(?SWITCH_ID,
                                   #ofp_group_stats_request{ group_id = 1 }),
    ?assertMatch(#ofp_group_stats_reply{body = [_]}, S1),

    %% try stats for nonexisting group
    S2 = linc_us4_groups:get_stats(?SWITCH_ID,
                                   #ofp_group_stats_request{
                                       group_id = 332211 }),
    ?assertMatch(#ofp_group_stats_reply{body = []}, S2),

    %% try stats for ALL groups
    S3 = linc_us4_groups:get_stats(?SWITCH_ID,
                                   #ofp_group_stats_request{ group_id = all }),
    ?assertMatch(#ofp_group_stats_reply{body = [_]}, S3).

%%--------------------------------------------------------------------
is_valid() ->
    ?assertEqual(false, linc_us4_groups:is_valid(?SWITCH_ID, 1)),
    M1 = call_group_mod(add, 1, all, []),
    ?assertEqual(ok, M1),
    ?assertEqual(true, linc_us4_groups:is_valid(?SWITCH_ID, 1)).

%%%
%%% Fixtures --------------------------------------------------------------------
%%%

setup() ->
    linc:create(?SWITCH_ID),
    mock(?MOCKED).

teardown(_) ->
    linc:delete(?SWITCH_ID),
    unmock(?MOCKED).

foreach_setup() ->
    linc_us4_groups:initialize(?SWITCH_ID).

foreach_teardown(_) ->
    linc_us4_groups:terminate(?SWITCH_ID).

%%%
%%% Tools --------------------------------------------------------------------
%%%

%% @internal
%% @doc Peeks to group_table checking if group exists
group_exists(GroupId) ->
    case ets:lookup(linc:lookup(?SWITCH_ID, group_table), GroupId) of
        [] -> false;
        L when is_list(L) -> true
    end.

call_group_mod(Command, GroupId, Type, Buckets) ->
    linc_us4_groups:modify(?SWITCH_ID, #ofp_group_mod{
                                          command = Command, group_id = GroupId,
                                          type = Type, buckets = Buckets
                                         }).

%% @doc In #ofp_group_stats_reply{} searches for reply with a given GroupId,
%% and returns a field Key from it.
stats_get(#ofp_group_stats_reply{ body = Stats }, GroupId, Key) ->
    case lists:keyfind(GroupId, #ofp_group_stats.group_id, Stats) of
        false -> {not_found, group, GroupId};
        GroupStats ->
            case Key of
                reference_count ->
                    GroupStats#ofp_group_stats.ref_count;
                packet_count ->
                    GroupStats#ofp_group_stats.packet_count;
                byte_count ->
                    GroupStats#ofp_group_stats.byte_count;
                time ->
                    S = GroupStats#ofp_group_stats.duration_sec,
                    NS = GroupStats#ofp_group_stats.duration_nsec,
                    %% ensure nanosec is in range 0..(1 billion - 1)
                    ?assert(NS >= 0),
                    ?assert(NS =< 999999999),
                    S * 1000000 + NS / 1000
            end
    end.

%% @doc Creates a test ICMP packet with 2 VLAN headers in it (122 bytes total)
test_packet_vlan() ->
    P = [{ether,<<0,27,212,27,164,216>>,<<0,19,195,223,174,24>>,33024,0},
         {ieee802_1q_tag,0,0,<<7,6:4>>,33024},
         {ieee802_1q_tag,0,0,<<0,10:4>>,2048},
         {ipv4,4,5,0,0,100,15,0,0,0,255,1,37531,<<10,118,10,1>>,<<10,118,10,2>>,<<>>},
         {icmp,8,0,52919,3,0,<<127,0,0,1>>,<<0,0,0,0>>,0,0,0,0,0},
         <<0,0,0,0,0,31,175,112,171,205,171,205,171,205,171,205,171,205,171,205,171,
           205,171,205,171,205,171,205,171,205,171,205,171,205,171,205,171,205,171,
           205,171,205,171,205,171,205,171,205,171,205,171,205,171,205,171,205,171,
           205,171,205,171,205,171,205,171,205,171,205,171,205,171,205>>],
    #linc_pkt{
       in_port = 1,
       packet = P,
       size = 122
      }.

%% @doc Creates a test bucket with few simple actions
make_test_bucket() -> make_test_bucket(1).

make_test_bucket(G) ->
    Act1 = #ofp_action_pop_vlan{},
    Act2 = #ofp_action_group{ group_id = G },
    #ofp_bucket{
       weight=1, watch_port=1, watch_group=1,
       actions=[Act1, Act2]
      }.
