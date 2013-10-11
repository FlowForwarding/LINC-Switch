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
-module(linc_us4_actions_tests).

-import(linc_us4_test_utils, [mock/1,
                              unmock/1,
                              mock_reset/1,
                              check_if_called/1,
                              check_output_on_ports/0]).

-include_lib("of_protocol/include/of_protocol.hrl").
-include_lib("of_protocol/include/ofp_v4.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("pkt/include/pkt.hrl").
-include("linc_us4.hrl").

-define(MOCKED, [port, group]).
-define(INIT_VAL, 100).
-define(NEW_VAL, 200).
-define(INIT_VAL(Bits), <<100:Bits>>).
-define(NEW_VAL(Bits), <<200:Bits>>).
-define(NO_SIDE_EFFECTS, []).

%% Tests -----------------------------------------------------------------------

actions_set_test_() ->
    {setup,
     fun setup/0,
     fun teardown/1,
     [{"Action Set: precedence of Group action", fun action_set_precedence/0},
      {"Action Set: drop if no Group or Output action", fun action_set_drop/0},
      {"Action Set: Output action", fun action_set_output/0}
     ]}.

action_set_precedence() ->
    ActionSet = [#ofp_action_group{group_id = ?INIT_VAL},
                 #ofp_action_output{port = ?INIT_VAL}],
    Pkt = #linc_pkt{actions = ActionSet},
    Output = linc_us4_actions:apply_set(Pkt),
    ?assertEqual({group, ?INIT_VAL, Pkt}, Output).

action_set_drop() ->
    %% No actions in Action Set
    ActionSet1 = [],
    Pkt1 = #linc_pkt{actions = ActionSet1},
    Output1 = linc_us4_actions:apply_set(Pkt1),
    ?assertEqual({drop, Pkt1}, Output1),

    %% No Group or Output actions in Action Set
    ActionSet2 = [#ofp_action_set_queue{queue_id = ?NEW_VAL}],
    Pkt2 = #linc_pkt{actions = ActionSet2, queue_id = ?INIT_VAL},
    NewPkt2 = #linc_pkt{queue_id = ?NEW_VAL},
    Output2 = linc_us4_actions:apply_set(Pkt2),
    ?assertEqual({drop, NewPkt2}, Output2).

action_set_output() ->
    ActionSet = [#ofp_action_output{port = ?INIT_VAL}],
    Pkt = #linc_pkt{actions = ActionSet},
    Output = linc_us4_actions:apply_set(Pkt),
    ?assertEqual({output, ?INIT_VAL, Pkt}, Output).

actions_test_() ->
    {setup, fun setup/0, fun teardown/1,
     {foreach, fun foreach_setup/0, fun foreach_teardown/1,
      [%% Required actions
       {"Action Output", fun action_output/0},
       {"Action Output: controller with reason 'action'",
        fun action_output_controller_action/0},
       {"Action Output: controller with reason 'no_match'",
        fun action_output_controller_nomatch/0},
       {"Action Group", fun action_group/0},
       {"Action Experimenter", fun action_experimenter/0},
       %% Optional actions
       {"Action Set-Field", fun action_set_field/0},
       {"Action Set-Queue", fun action_set_queue/0},

       {"Action Push-Tag: PBB", fun action_push_tag_pbb/0},
       {"Action Pop-Tag: PBB", fun action_pop_tag_pbb/0},
       {"Action Push-Tag: VLAN", fun action_push_tag_vlan/0},
       {"Action Pop-Tag: VLAN", fun action_pop_tag_vlan/0},
       {"Action Push-Tag: MPLS", fun action_push_tag_mpls/0},
       {"Action Pop-Tag: MPLS", fun action_pop_tag_mpls/0},

       {"Action Change-TTL: set MPLS TTL", fun action_set_mpls_ttl/0},
       {"Action Change-TTL: decrement MPLS TTL", fun action_decrement_mpls_ttl/0},
       {"Action Change-TTL: invalid MPLS TTL", fun invalid_mpls_ttl/0},
       {"Action Change-TTL: set IP TTL", fun action_set_ip_ttl/0},
       {"Action Change-TTL: decrement IP TTL", fun action_decrement_ip_ttl/0},
       {"Action Change-TTL: invalid IP TTL", fun invalid_ip_ttl/0},
       {"Action Change-TTL: copy TTL outwards", fun action_copy_ttl_outwards/0},
       {"Action Change-TTL: copy TTL inwards", fun action_copy_ttl_inwards/0}
      ]}}.

action_output() ->
    Pkt = #linc_pkt{},
    Port = 500,
    Action = #ofp_action_output{port = Port},
    ?assertEqual({Pkt, [{output, Port, Pkt}]},
                 linc_us4_actions:apply_list(Pkt, [Action])),
    ?assert(check_if_called({linc_us4_port, send, 2})),
    ?assertEqual([{Pkt, Port}], check_output_on_ports()).

action_output_controller_action() ->
    Pkt = #linc_pkt{},
    Port = controller,
    Action = #ofp_action_output{port = Port},
    ?assertEqual({Pkt, [{output, Port, Pkt}]},
                 linc_us4_actions:apply_list(Pkt, [Action])),
    ?assert(check_if_called({linc_us4_port, send, 2})),
    ?assertEqual([{Pkt#linc_pkt{packet_in_reason = action}, Port}],
                 check_output_on_ports()).

action_output_controller_nomatch() ->
    Pkt = #linc_pkt{packet_in_reason = no_match},
    Port = controller,
    Action = #ofp_action_output{port = Port},
    ?assertEqual({Pkt, [{output, Port, Pkt}]},
                 linc_us4_actions:apply_list(Pkt, [Action])),
    ?assert(check_if_called({linc_us4_port, send, 2})),
    ?assertEqual([{Pkt, Port}], check_output_on_ports()).

action_group() ->
    GroupId = 300,
    Pkt = #linc_pkt{},
    ActionGroup = #ofp_action_group{group_id = GroupId},
    ?assertEqual({Pkt, [{group, GroupId, Pkt}]},
                 linc_us4_actions:apply_list(Pkt, [ActionGroup])),
    ?assert(check_if_called({linc_us4_groups, apply, 2})).

action_experimenter() ->
    Action = #ofp_action_experimenter{experimenter = 111},
    Packet = [],
    NewPacket = [],
    check_action(Action, Packet, NewPacket).

action_set_field() ->
    EthType = {[#ether{type = ?INIT_VAL}], {eth_type, ?NEW_VAL(16)}, [#ether{type = ?NEW_VAL}]},
    EthDst = {[#ether{dhost = ?INIT_VAL(48)}], {eth_dst, ?NEW_VAL(48)}, [#ether{dhost = ?NEW_VAL(48)}]},
    EthSrc = {[#ether{shost = ?INIT_VAL(48)}], {eth_src, ?NEW_VAL(48)}, [#ether{shost = ?NEW_VAL(48)}]},
    [begin
         Field = #ofp_field{name = Name, value = Value},
         Action = #ofp_action_set_field{field = Field},
         check_action(Action, Packet, NewPacket)
     end || {Packet, {Name, Value}, NewPacket} <- [EthType, EthDst, EthSrc]].

action_set_queue() ->
    Pkt = #linc_pkt{queue_id = ?INIT_VAL},
    Action = #ofp_action_set_queue{queue_id = ?NEW_VAL},
    {NewPkt, ?NO_SIDE_EFFECTS} =
        linc_us4_actions:apply_list(Pkt, [Action]),
    ?assertEqual(?NEW_VAL, NewPkt#linc_pkt.queue_id).

action_push_tag_pbb() ->
    Ethertype = 16#88e7,
    Action = #ofp_action_push_pbb{ethertype = Ethertype},

    %% No previous PBB nor VLAN
    Packet1 = [],
    NewPacket1 = [#pbb{i_sid = <<1:24>>}],
    check_action(Action, Packet1, NewPacket1),

    %% Previous PBB exists
    Packet2 = [#pbb{i_sid = <<100:24>>}],
    NewPacket2 = [#pbb{i_sid = <<100:24>>}],
    check_action(Action, Packet2, NewPacket2),

    %% Previous VLAN exists
    Packet3 = [#ieee802_1q_tag{pcp = 100}],
    NewPacket3 = [#pbb{i_pcp = 100, i_sid = <<1:24>>},
                  #ieee802_1q_tag{pcp = 100}],
    check_action(Action, Packet3, NewPacket3).

action_pop_tag_pbb() ->
    Action = #ofp_action_pop_pbb{},

    Packet1 = [#ether{}],
    NewPacket1 = [#ether{}],
    check_action(Action, Packet1, NewPacket1),

    Packet2 = [#pbb{}],
    NewPacket2 = [],
    check_action(Action, Packet2, NewPacket2).

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
    MPLS1 = 16#8847,
    Action = #ofp_action_push_mpls{ethertype = MPLS1},

    %% Single MPLS tag without VLAN and IP headers 
    Packet1 = [#ether{}],
    NewPacket1 = [#ether{},
                  #mpls_tag{stack = [#mpls_stack_entry{ttl = 0}]}],
    check_action(Action, Packet1, NewPacket1),

    %% Multiple MPLS tags without VLAN and IP headers
    Packet2 = [#ether{},
               #mpls_tag{stack = [#mpls_stack_entry{}]}],
    NewPacket2 = [#ether{},
                  #mpls_tag{stack = [#mpls_stack_entry{},
                                     #mpls_stack_entry{}]}],
    check_action(Action, Packet2, NewPacket2),

    %% Single MPLS tag with VLAN but whithout IP headers.
    %% Should insert MPLS after VLAN.
    VLAN1 = 16#8100,
    Packet3 = [#ether{},
               #ieee802_1q_tag{pcp = 100, vid = 100, ether_type = VLAN1}],
    NewPacket3 = [#ether{},
                  #ieee802_1q_tag{pcp = 100, vid = 100, ether_type = VLAN1},
                  #mpls_tag{stack = [#mpls_stack_entry{ttl = 0}]}],
    check_action(Action, Packet3, NewPacket3),

    %% Single MPLS with IP header.
    %% Copy TTL from IP to MPLS.
    Packet4 = [#ether{},
               #ipv4{ttl = 500}],
    NewPacket4 = [#ether{},
                  #mpls_tag{stack = [#mpls_stack_entry{ttl = 500}]},
                  #ipv4{ttl = 500}],
    check_action(Action, Packet4, NewPacket4).

action_pop_tag_mpls() ->
    IPv4EtherType = 16#0800,
    MPLSEtherType = 16#8847,
    VLANEtherType = 16#8100,

    %% One MPLS label - delete whole header3
    Action1 = #ofp_action_pop_mpls{ethertype = IPv4EtherType},
    
    Packet1 = [#ether{type = MPLSEtherType},
               #mpls_tag{stack = [#mpls_stack_entry{}]},
               #ipv4{}],
    NewPacket1 = [#ether{type = IPv4EtherType}, #ipv4{}],
    check_action(Action1, Packet1, NewPacket1),

    %% Two MPLS labels - delete only the outermost one
    Action2 = #ofp_action_pop_mpls{ethertype = MPLSEtherType},

    Packet2 = [#ether{type = MPLSEtherType},
               #mpls_tag{stack = [#mpls_stack_entry{label = label1},
                                  #mpls_stack_entry{label = label2}]},
               #ipv4{}],
    NewPacket2 = [#ether{type = MPLSEtherType},
                  #mpls_tag{stack = [#mpls_stack_entry{label = label2}]},
                  #ipv4{}],
    check_action(Action2, Packet2, NewPacket2),

    %% One MPLS header after VLAN tag - delete whole MPLS header after VLAN tag
    Action3 = #ofp_action_pop_mpls{ethertype = IPv4EtherType},

    Packet3 = [#ether{type = VLANEtherType},
               #ieee802_1q_tag{vid = <<100:12>>, ether_type = MPLSEtherType},
               #mpls_tag{stack = [#mpls_stack_entry{label = label1}]},
               #ipv4{}],
    NewPacket3 = [#ether{type = VLANEtherType},
                  #ieee802_1q_tag{vid = <<100:12>>, ether_type = IPv4EtherType},
                  #ipv4{}],
    check_action(Action3, Packet3, NewPacket3).

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

invalid_mpls_ttl() ->
    Packet = [#mpls_tag{stack = [#mpls_stack_entry{ttl = 0}]}],
    Action = #ofp_action_dec_mpls_ttl{},
    check_action_error(Action, Packet, {error,invalid_ttl}).

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

invalid_ip_ttl() ->
    Packet = [#ipv4{ttl = 0}],
    Action = #ofp_action_dec_nw_ttl{},
    check_action_error(Action, Packet, {error,invalid_ttl}).

action_copy_ttl_outwards() ->
    Action  = #ofp_action_copy_ttl_out{},

    %% from IPv4 to IPv4
    Packet1 = [#ipv4{ttl = ?INIT_VAL}, #ipv4{ttl = ?NEW_VAL}],
    NewPacket1 = [#ipv4{ttl = ?NEW_VAL}, #ipv4{ttl = ?NEW_VAL}],
    check_action(Action, Packet1, NewPacket1),

    %% from IPv4 to MPLS
    Packet2 = [#mpls_tag{stack = [#mpls_stack_entry{ttl = ?INIT_VAL}]},
               #ipv4{ttl = ?NEW_VAL}],
    NewPacket2 = [#mpls_tag{stack = [#mpls_stack_entry{ttl = ?NEW_VAL}]},
                  #ipv4{ttl = ?NEW_VAL}],
    check_action(Action, Packet2, NewPacket2),

    %% from MPLS to MPLS
    Packet3 = [#mpls_tag{stack = [#mpls_stack_entry{ttl = ?INIT_VAL},
                                  #mpls_stack_entry{ttl = ?NEW_VAL}]},
               #ipv4{ttl = ?INIT_VAL}],
    NewPacket3 = [#mpls_tag{stack = [#mpls_stack_entry{ttl = ?NEW_VAL},
                                     #mpls_stack_entry{ttl = ?NEW_VAL}]},
                  #ipv4{ttl = ?INIT_VAL}],
    check_action(Action, Packet3, NewPacket3).

action_copy_ttl_inwards() ->
    Action  = #ofp_action_copy_ttl_in{},

    %% from IPv4 to IPv4
    Packet1 = [#ipv4{ttl = ?NEW_VAL}, #ipv4{ttl = ?INIT_VAL}],
    NewPacket1 = [#ipv4{ttl = ?NEW_VAL}, #ipv4{ttl = ?NEW_VAL}],
    check_action(Action, Packet1, NewPacket1),

    %% from MPLS to IPv4
    Packet2 = [#mpls_tag{stack = [#mpls_stack_entry{ttl = ?NEW_VAL}]},
               #ipv4{ttl = ?INIT_VAL}],
    NewPacket2 = [#mpls_tag{stack = [#mpls_stack_entry{ttl = ?NEW_VAL}]},
                  #ipv4{ttl = ?NEW_VAL}],
    check_action(Action, Packet2, NewPacket2),

    %% from MPLS to MPLS
    Packet3 = [#mpls_tag{stack = [#mpls_stack_entry{ttl = ?NEW_VAL},
                                  #mpls_stack_entry{ttl = ?INIT_VAL}]},
               #ipv4{ttl = ?INIT_VAL}],
    NewPacket3 = [#mpls_tag{stack = [#mpls_stack_entry{ttl = ?NEW_VAL},
                                     #mpls_stack_entry{ttl = ?NEW_VAL}]},
                  #ipv4{ttl = ?INIT_VAL}],
    check_action(Action, Packet3, NewPacket3).

actions_complex_test_() ->
    {setup, fun setup/0, fun teardown/1,
     {foreach, fun foreach_setup/0, fun foreach_teardown/1,
      [{"Change dest IP and output to egress port", fun action_complex_1/0}
      ]}}.

action_complex_1() ->
    Daddr1 = daddr1,
    Daddr2 = daddr2,
    Pkt = #linc_pkt{packet = [#ipv4{daddr = Daddr1}]},
    PktExpected = #linc_pkt{packet = [#ipv4{daddr = Daddr2}]},
    Port = 500,
    Field = #ofp_field{name = ipv4_dst, value = Daddr2},
    Action1 = #ofp_action_set_field{field = Field},
    Action2 = #ofp_action_output{port = Port},
    ?assertEqual({PktExpected, [{output, Port, PktExpected}]},
                 linc_us4_actions:apply_list(Pkt, [Action1, Action2])),
    ?assert(check_if_called({linc_us4_port, send, 2})),
    ?assertEqual([{PktExpected, Port}], check_output_on_ports()).

%% Fixtures --------------------------------------------------------------------

setup() ->
    mock(?MOCKED).

teardown(_) ->
    unmock(?MOCKED).

foreach_setup() ->
    mock_reset(?MOCKED).

foreach_teardown(_) ->
    ok.

check_action(Action, Packet, NewPacket) ->
    Pkt = #linc_pkt{packet = Packet},
    NewPkt = #linc_pkt{packet = NewPacket},
    {Pkt2, ?NO_SIDE_EFFECTS} = linc_us4_actions:apply_list(Pkt, [Action]),
    ?assertEqual(NewPkt, Pkt2).

check_action_error(Action, Packet, Error) ->
    Pkt = #linc_pkt{packet = Packet},
    ?assertEqual(Error, linc_us4_actions:apply_list(Pkt, [Action])).
