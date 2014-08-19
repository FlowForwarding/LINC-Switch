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
-module(linc_us4_convert_tests).

-import(linc_us4_test_utils, [mock/1,
                              unmock/1]).

-include_lib("of_protocol/include/of_protocol.hrl").
-include_lib("of_protocol/include/ofp_v4.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("pkt/include/pkt.hrl").

-define(MOCKED, []).

%% Tests -----------------------------------------------------------------------

convert_test_() ->
    {setup,
     fun setup/0,
     fun teardown/1,
     [{"Convert pkt:packet() to ofp_field(): PBB", fun pbb/0},
      {"Convert pkt:packet() to ofp_field(): Ethernet", fun ether/0},
      {"Convert pkt:packet() to ofp_field(): VLAN", fun vlan/0},
      {"Convert pkt:packet() to ofp_field(): ARP", fun arp/0},
      {"Convert pkt:packet() to ofp_field(): SCTP", fun sctp/0},
      {"Convert pkt:packet() to ofp_field(): MPLS", fun mpls/0},
      {"Convert pkt:packet() to ofp_field(): IPv4", fun ipv4/0},
      {"Convert pkt:packet() to ofp_field(): IPv6", fun ipv6/0},
      {"Convert pkt:packet() to ofp_field(): ICMPv4", fun icmpv4/0},
      {"Convert pkt:packet() to ofp_field(): ICMPv6", fun icmpv6/0},
      {"Convert pkt:packet() to ofp_field(): TCP", fun tcp/0},
      {"Convert pkt:packet() to ofp_field(): UDP", fun udp/0},
      {"Convert pkt:packet() to ofp_field(): unknown", fun unknown/0}
     ]}.

pbb() ->
    Packet = [#pbb{i_sid = 100}],
    check_packet(Packet, [{pbb_isid, <<100:24>>}]).

ether() ->
    Packet = [#ether{dhost = dhost, shost = shost, type = 1}],
    check_packet(Packet, [{eth_type, <<1:16>>},
                          {eth_dst, dhost},
                          {eth_src, shost}]).

vlan() ->
    Packet = [#ether{dhost = dhost, shost = shost, type = 1},
              #ieee802_1q_tag{vid = <<(VID = 16#0050):12>>,
                              pcp = 2, ether_type = 2}],
    check_packet(Packet, [{eth_dst, dhost},
                          {eth_src, shost},
                          {eth_type, <<2:16>>},
                          {vlan_vid, <<(?OFPVID_PRESENT bor VID):13>>},
                          {vlan_pcp, <<2:3>>}]).

arp() ->
    Packet = [#arp{op = 1, sip = sip, tip = tip, sha = sha, tha = tha}],
    check_packet(Packet, [{arp_op, <<1:16>>},
                          {arp_spa, sip},
                          {arp_tpa, tip},
                          {arp_sha, sha},
                          {arp_tha, tha}]).

sctp() ->
    Packet = [#sctp{sport = 1, dport = 2}],
    check_packet(Packet, [{sctp_src, <<1:16>>},
                          {sctp_dst, <<2:16>>}]).

mpls() ->
    Label1 = #mpls_stack_entry{label = l1,
                               qos = 1, pri = 1, ecn = 1,
                               bottom = 0, ttl = 100},
    Label2 = #mpls_stack_entry{label = l2,
                               qos = 0, pri = 0, ecn = 0,
                               bottom = 1, ttl = 200},
    Packet = [#mpls_tag{stack = [Label1, Label2]}],
    check_packet(Packet, [{mpls_label, l1},
                          {mpls_tc, <<1:1, 1:1, 1:1>>},
                          {mpls_bos, <<0:1>>}]).

ipv4() ->
    Packet = [#ipv4{p = 1, dscp = 2, ecn = 1, saddr = saddr, daddr = daddr}],
    check_packet(Packet, [{ip_proto, <<1:8>>},
                          {ip_dscp, <<2:6>>},
                          {ip_ecn, <<1:2>>},
                          {ipv4_src, saddr},
                          {ipv4_dst, daddr}]).

ipv6() ->
    %% IPv6 packets
    Packet1 = [#ipv6{next = 1, saddr = saddr, daddr = daddr,
                     class = 9, flow = 100}],
    check_packet(Packet1, [{ip_proto, <<1:8>>},
                           {ip_dscp, <<2:6>>},
                           {ip_ecn, <<1:2>>},
                           {ipv6_src, saddr},
                           {ipv6_dst, daddr},
                           {ipv6_flabel, <<100:20>>}]),
    
    %% IPv6 neighbour discovery messages
    Packet2 = [#ndp_ns{tgt_addr = addr, sll = sll}],
    check_packet(Packet2, [{ipv6_nd_target, addr},
                           {ipv6_nd_sll, sll}]),
    
    Packet3 = [#ndp_na{src_addr = addr, tll = tll}],
    check_packet(Packet3, [{ipv6_nd_target, addr},
                           {ipv6_nd_tll, tll}]).

icmpv4() ->
    Packet = [#icmp{type = 1, code = 2}],
    check_packet(Packet, [{icmpv4_type, <<1>>},
                          {icmpv4_code, <<2:8>>}]).

icmpv6() ->
    Packet = [#icmpv6{type = 1, code = 2}],
    check_packet(Packet, [{icmpv6_type, <<1>>},
                          {icmpv6_code, <<2:8>>}]).

tcp() ->
    Packet = [#tcp{sport = 1, dport = 2}],
    check_packet(Packet, [{tcp_src, <<1:16>>},
                          {tcp_dst, <<2:16>>}]).

udp() ->
    Packet = [#udp{sport = 1, dport = 2}],
    check_packet(Packet, [{udp_src, <<1:16>>},
                          {udp_dst, <<2:16>>}]).

unknown() ->
    ok.

constraints_test_() ->
    {setup,
     fun setup/0,
     fun teardown/1,
     [{"OXM Ethertype field generated for packets shouldn't ignore VLAN tags",
       fun ether_ignore_vlan/0},
      {"OXM VLAN fields should match on outer VLAN tag only",
       fun vlan_match_only_outer/0}]}.

%% Issue reported and described here:
%% https://github.com/FlowForwarding/LINC-Switch/issues/2
ether_ignore_vlan() ->
    P1 = [#ether{type = 12345}],
    Fields1 = linc_us4_convert:packet_fields(P1),
    F1 = lists:filter(fun(X) -> X#ofp_field.name == eth_type end, Fields1),
    ?assert(length(F1) =:= 1), % exactly 1 field added
    [EthType1 | _] = F1,
    ?assert(EthType1 =/= false),
    ?assert(EthType1#ofp_field.value =:= <<12345:16>>),

    P2 = [#ether{type = 12345}, #ieee802_1q_tag{ether_type = 22222}],
    Fields2 = linc_us4_convert:packet_fields(P2),
    F2 = lists:filter(fun(X) -> X#ofp_field.name == eth_type end, Fields2),
    ?assert(length(F2) =:= 1), % exactly 1 field added
    [EthType2 | _] = F2,
    ?assert(EthType2 =/= false),
    ?assert(EthType2#ofp_field.value =:= <<22222:16>>).

%% Issue reported and described here:
%% https://github.com/FlowForwarding/LINC-Switch/issues/3
vlan_match_only_outer() ->
    P1 = [#ether{}, #ieee802_1q_tag{vid = <<333:12>>},
          #ieee802_1q_tag{vid = <<444:12>>}],
    Fields1 = linc_us4_convert:packet_fields(P1),
    F1 = lists:filter(fun(X) -> X#ofp_field.name == vlan_vid end, Fields1),
    ?assert(length(F1) =:= 1), % exactly 1 field added
    [VLAN1 | _] = F1,
    ?assert(VLAN1 =/= false),
    ?assert(VLAN1#ofp_field.value =:= <<(?OFPVID_PRESENT bor 333):13>>).

%% Fixtures --------------------------------------------------------------------

setup() ->
    mock(?MOCKED).

teardown(_) ->
    unmock(?MOCKED).

check_packet(Packet, Expected) ->
    Fields = linc_us4_convert:packet_fields(Packet),
    check_fields(Fields, Expected).

check_fields([], []) ->
    ok;
check_fields([Converted | Rest1], [{Name, Value} | Rest2]) ->
    Expected = #ofp_field{name = Name, value = Value},
    ?assertEqual(Expected, Converted),
    check_fields(Rest1, Rest2).
