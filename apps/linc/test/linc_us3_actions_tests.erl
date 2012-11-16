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
-module(linc_us3_actions_tests).

-import(linc_test_utils, [mock/1,
                          unmock/1,
                          check_if_called/1,
                          check_output_on_ports/0]).

-include_lib("eunit/include/eunit.hrl").
-include_lib("linc/include/linc_us3.hrl").
-include_lib("pkt/include/pkt.hrl").

-define(MOCKED, [port, group]).
-define(INIT_VAL, 100).
-define(NEW_VAL, 200).

%% Tests -----------------------------------------------------------------------

actions_set_test_() ->
    {setup,
     fun setup/0,
     fun teardown/1,
     []}.

actions_test_() ->
    {setup,
     fun setup/0,
     fun teardown/1,
     [%% Required actions
      {"Action Output", fun action_output/0},
      {"Action Drop", fun action_drop/0},
      {"Action Group", fun action_group/0},
      %% Optional actions
      {"Action Set-Field", fun action_set_field/0},
      {"Action Set-Queue", fun action_set_queue/0},

      {"Action Push-Tag: VLAN", fun action_push_tag_vlan/0},
      {"Action Pop-Tag: VLAN", fun action_pop_tag_vlan/0},
      {"Action Push-Tag: MPLS", fun action_push_tag_mpls/0},
      {"Action Pop-Tag: MPLS", fun action_pop_tag_mpls/0},

      {"Action Change-TTL: set MPLS TTL", fun action_set_mpls_ttl/0},
      {"Action Change-TTL: decrement MPLS TTL", fun action_decrement_mpls_ttl/0},
      {"Action Change-TTL: set IP TTL", fun action_set_ip_ttl/0},
      {"Action Change-TTL: decrement IP TTL", fun action_decrement_ip_ttl/0},
      {"Action Change-TTL: copy TTL outwards", fun action_copy_ttl_outwards/0},
      {"Action Change-TTL: copy_ttl_inwards", fun action_copy_ttl_inwards/0}]}.

action_output() ->
    Pkt = #ofs_pkt{},
    Port = 500,
    Action = #ofp_action_output{port = Port},
    ?assertEqual({output, Port, Pkt},
                 linc_us3_actions:apply_list(Pkt, [Action])),
    ?assert(check_if_called({linc_us3_port, send, 2})),
    ?assertEqual([{Pkt, Port}], check_output_on_ports()).

action_drop() ->
    ok.

action_group() ->
    GroupId = 300,
    Pkt = #ofs_pkt{},
    ActionGroup = #ofp_action_group{group_id = GroupId},
    ?assertEqual({group, GroupId, Pkt},
                 linc_us3_actions:apply_list(Pkt, [ActionGroup])),
    ?assert(check_if_called({linc_us3_groups, apply, 2})).

action_set_field() ->
    EthType = {[#ether{type = ?INIT_VAL}], {eth_type, ?NEW_VAL}, [#ether{type = ?NEW_VAL}]},
    EthDst = {[#ether{dhost = ?INIT_VAL}], {eth_dst, ?NEW_VAL}, [#ether{dhost = ?NEW_VAL}]},
    EthSrc = {[#ether{shost = ?INIT_VAL}], {eth_src, ?NEW_VAL}, [#ether{shost = ?NEW_VAL}]},
    [begin
         Pkt = #ofs_pkt{packet = Packet},
         Field = #ofp_field{name = Name, value = Value},
         ActionSetField = #ofp_action_set_field{field = Field},
         Pkt2 = linc_us3_actions:apply_list(Pkt, [ActionSetField]),
         ?assertEqual(NewPacket, Pkt2#ofs_pkt.packet)
     end || {Packet, {Name, Value}, NewPacket} <- [EthType, EthDst, EthSrc]].

action_set_queue() ->
    Pkt = #ofs_pkt{},
    ActionSetQueue = #ofp_action_set_queue{queue_id = ?INIT_VAL},
    Pkt2 = linc_us3_actions:apply_list(Pkt, [ActionSetQueue]),
    ?assertEqual(?INIT_VAL, Pkt2#ofs_pkt.queue_id).

action_push_tag_vlan() ->
    %% No initial VLAN
    VLAN1 = 16#8100,
    Action1 = #ofp_action_push_vlan{ethertype = VLAN1},
    Packet1 = [#ether{}],
    NewPacket1 = [#ether{},
                  #ieee802_1q_tag{pcp = 0, vid = 1, ether_type = VLAN1}],
    check_action(Action1, Packet1, NewPacket1),

    %% %% Initial VLAN present
    VLAN2 = 16#88a8,
    Action2 = #ofp_action_push_vlan{ethertype = VLAN2},
    Packet2 = [#ether{},
               #ieee802_1q_tag{pcp = 100, vid = 100, ether_type = VLAN1}],
    NewPacket2 = [#ether{},
                  #ieee802_1q_tag{pcp = 100, vid = 100, ether_type = VLAN2},
                  #ieee802_1q_tag{pcp = 100, vid = 100, ether_type = VLAN1}],
    check_action(Action2, Packet2, NewPacket2).

action_pop_tag_vlan() ->
    Action = #ofp_action_pop_vlan{},

    %% Pop with only one VLAN
    VLAN1 = 16#8100,
    Packet1 = [#ether{},
               #ieee802_1q_tag{pcp = 100, vid = 100, ether_type = VLAN1}],
    NewPacket1 = [#ether{}],
    check_action(Action, Packet1, NewPacket1),

    %% Pop with two VLANs
    VLAN2 = 16#88a8,
    Packet2 = [#ether{},
               #ieee802_1q_tag{pcp = 100, vid = 100, ether_type = VLAN2},
               #ieee802_1q_tag{pcp = 100, vid = 100, ether_type = VLAN1}],
    NewPacket2 = [#ether{},
                  #ieee802_1q_tag{pcp = 100, vid = 100, ether_type = VLAN1}],
    check_action(Action, Packet2, NewPacket2).

action_push_tag_mpls() ->
    ok.

action_pop_tag_mpls() ->
    ok.

action_set_mpls_ttl() ->
    Packet = [#mpls_tag{stack = [#mpls_stack_entry{ttl = ?INIT_VAL}]}],
    NewPacket = [#mpls_tag{stack = [#mpls_stack_entry{ttl = ?NEW_VAL}]}],
    Action = #ofp_action_set_mpls_ttl{mpls_ttl = ?NEW_VAL},
    check_action(Action, Packet, NewPacket).

action_decrement_mpls_ttl() ->
    Packet = [#mpls_tag{stack = [#mpls_stack_entry{ttl = ?INIT_VAL}]}],
    NewPacket = [#mpls_tag{stack = [#mpls_stack_entry{ttl = ?INIT_VAL - 1}]}],
    Action = #ofp_action_dec_mpls_ttl{},
    check_action(Action, Packet, NewPacket).

action_set_ip_ttl() ->
    Packet = [#ipv4{ttl = ?INIT_VAL}],
    NewPacket = [#ipv4{ttl = ?NEW_VAL}],
    Action = #ofp_action_set_nw_ttl{nw_ttl = ?NEW_VAL},
    check_action(Action, Packet, NewPacket).

action_decrement_ip_ttl() ->
    Packet = [#ipv4{ttl = ?INIT_VAL}],
    NewPacket = [#ipv4{ttl = ?INIT_VAL - 1}],
    Action = #ofp_action_dec_nw_ttl{},
    check_action(Action, Packet, NewPacket).

action_copy_ttl_outwards() ->
    ok.

action_copy_ttl_inwards() ->
    ok.

%% Fixtures --------------------------------------------------------------------

setup() ->
    mock(?MOCKED).

teardown(_) ->
    unmock(?MOCKED).

check_action(Action, Packet, NewPacket) ->
    Pkt = #ofs_pkt{packet = Packet},
    NewPkt = #ofs_pkt{packet = NewPacket},
    Pkt2 = linc_us3_actions:apply_list(Pkt, [Action]),
    ?assertEqual(NewPkt, Pkt2).
