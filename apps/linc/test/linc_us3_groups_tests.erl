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
-module(linc_us3_groups_tests).

-import(linc_test_utils, [mock/1,
                          unmock/1]).

-include_lib("eunit/include/eunit.hrl").
-include_lib("linc/include/linc_us3.hrl").

-define(MOCKED, [port, actions]).

%%%
%%% Tests -----------------------------------------------------------------------
%%%

group_test_() ->
    {foreach,
     fun setup/0,
     fun teardown/1,
     [{"Add group", fun add_group/0},
      {"Modify group", fun modify_group/0},
      {"Delete group", fun delete_group/0},
      {"is_valid", fun is_valid/0}]}.

%%--------------------------------------------------------------------
add_group() ->
    M1 = linc_us3_groups:modify(#ofp_group_mod{
                                   command = add, group_id = 1,
                                   type = all, buckets = []
                                  }),
    ?assertEqual(ok, M1),

    linc_us3_groups:update_reference_count(1, 333),

    %% check that counters are zero
    G1Stats = linc_us3_groups:get_stats(#ofp_group_stats_request{ group_id = 1 }),
    ?assertEqual(333, stats_get(G1Stats, 1, reference_count)),
    ?assertEqual(0, stats_get(G1Stats, 1, packet_count)),
    ?assertEqual(0, stats_get(G1Stats, 1, byte_count)),

    %% send a random package
    Pkt2 = test_packet_vlan(),
    linc_us3_groups:apply(1, Pkt2),

    %% check that counters changed
    G2Stats = linc_us3_groups:get_stats(#ofp_group_stats_request{ group_id = 1 }),
    ?assertEqual(1, stats_get(G2Stats, 1, packet_count)),
    ?assertEqual(Pkt2#ofs_pkt.size, stats_get(G2Stats, 1, byte_count)).

%%--------------------------------------------------------------------
modify_group() ->
    M1 = linc_us3_groups:modify(#ofp_group_mod{
                                   command = add, group_id = 1,
                                   type = all, buckets = []
                                  }),
    ?assertEqual(ok, M1),

    %% Modify group, bucket counters should reset
    B1 = #ofp_bucket{ watch_port = 1, watch_group = 1, actions = []},
    %% Send a modify group
    M2 = linc_us3_groups:modify(#ofp_group_mod{
                                   command = modify, group_id = 1,
                                   type = all, buckets = [B1]
                                  }),
    ?assertEqual(ok, M2),

    %% Send a modify nonexisting group
    M3 = linc_us3_groups:modify(#ofp_group_mod{
                                   command = modify, group_id = 222,
                                   type = all, buckets = [B1]
                                  }),
    ?assertMatch({error, _}, M3).

%%--------------------------------------------------------------------
delete_group() ->
    M1 = linc_us3_groups:modify(#ofp_group_mod{
                                   command = add, group_id = 1,
                                   type = all, buckets = []
                                  }),
    ?assertEqual(ok, M1),

    M2 = linc_us3_groups:modify(#ofp_group_mod{
                                   command = delete, group_id = 1
                                  }),
    ?assertEqual(ok, M2),

    %% Deleting a nonexisting group produces no error
    M3 = linc_us3_groups:modify(#ofp_group_mod{
                                   command = delete, group_id = 1
                                  }),
    ?assertEqual(ok, M3).
    %%?assertMatch({error, _}, M3).

%%--------------------------------------------------------------------
is_valid() ->
    ?assertEqual(false, linc_us3_groups:is_valid(1)),
    M1 = linc_us3_groups:modify(#ofp_group_mod{
                                   command = add, group_id = 1,
                                   type = all, buckets = []
                                  }),
    ?assertEqual(ok, M1),
    ?assertEqual(true, linc_us3_groups:is_valid(1)).
    
%%%
%%% Fixtures --------------------------------------------------------------------
%%%

setup() ->
    %%mock(?MOCKED),
    linc_us3_groups:create(),
    ok.

teardown(ok) ->
    %%unmock(?MOCKED),
    linc_us3_groups:destroy(),
    ok.

%%%
%%% Tools --------------------------------------------------------------------
%%%

%% @doc In #ofp_group_stats_reply{} searches for reply with a given GroupId,
%% and returns a field Key from it.
stats_get(#ofp_group_stats_reply{ stats = Stats }, GroupId, Key) ->
    case lists:keyfind(GroupId, #ofp_group_stats.group_id, Stats) of
        false -> {not_found, group, GroupId};
        GroupStats ->
            case Key of
                reference_count -> GroupStats#ofp_group_stats.ref_count;
                packet_count -> GroupStats#ofp_group_stats.packet_count;
                byte_count -> GroupStats#ofp_group_stats.byte_count
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
    #ofs_pkt{
       in_port = 1,
       packet = P,
       size = 122
      }.
