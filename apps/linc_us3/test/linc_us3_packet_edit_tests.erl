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
-module(linc_us3_packet_edit_tests).

-import(linc_us3_test_utils, [mock/1,
                              unmock/1,
                              check_if_called/1,
                              check_output_on_ports/0]).

-include_lib("of_protocol/include/of_protocol.hrl").
-include_lib("of_protocol/include/ofp_v3.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("pkt/include/pkt.hrl").
-include("linc_us3.hrl").

-define(MOCKED, []).
-define(INIT_VAL, 100).
-define(NEW_VAL, 200).

%% Tests -----------------------------------------------------------------------

basic_packet_edit_test_() ->
    {setup,
     fun setup/0,
     fun teardown/1,
     [{"Edit packet: Ethernet", fun ethernet/0},
      {"Edit packet: VLAN", fun vlan/0},
      {"Edit packet: ARP", fun arp/0},
      {"Edit packet: SCTP", fun sctp/0},
      {"Edit packet: ICMPv4", fun icmp_v4/0},
      {"Edit packet: ICMPv6", fun icmp_v6/0},
      {"Edit packet: TCP", fun tcp/0},
      {"Edit packet: UDP", fun udp/0},
      {"Edit packet: MPLS", fun mpls/0},
      {"Edit packet: IPv4", fun ip_v4/0},
      {"Edit packet: IPv6", fun ip_v6/0}
     ]}.

corner_cases_packet_edit_test_() ->
    {setup,
     fun setup/0,
     fun teardown/1,
     [{"Edit packet: no header", fun no_header/0},
      {"Edit packet: bad field", fun bad_field/0},
      {"Edit packet: duplicated header", fun duplicated_header/0},
      {"Edit packet: nested header", fun nested_header/0},
      {"Edit packet: skip header", fun skip_header/0},
      {"Edit packet: outermost header", fun outermost_header/0}
     ]}.

no_header() ->
    EmptyHeader = {[], {eth_type, ?NEW_VAL}, []},
    set_field([EmptyHeader]).

bad_field() ->
    Packet = [#ether{type = ?INIT_VAL}],
    BadField = {Packet, {bad_field, ?NEW_VAL}, Packet},
    set_field([BadField]).

duplicated_header() ->
    Packet = [#ether{type = ?INIT_VAL}, #ether{type = ?INIT_VAL}],
    NewPacket = [#ether{type = ?NEW_VAL}, #ether{type = ?INIT_VAL}],
    DuplicatedHeader = {Packet, {eth_type, ?NEW_VAL}, NewPacket},
    set_field([DuplicatedHeader]).

nested_header() ->
    Packet = [#arp{op = ?INIT_VAL}, #ether{type = ?INIT_VAL}],
    NewPacket = [#arp{op = ?INIT_VAL}, #ether{type = ?NEW_VAL}],
    EditField = {eth_type, ?NEW_VAL},
    set_field([{Packet, EditField, NewPacket}]).

skip_header() ->
    Packet = [#ether{type = ?INIT_VAL}, #ether{type = ?INIT_VAL}],
    NewPacket = [#ether{type = ?INIT_VAL}, #ether{type = ?NEW_VAL}],
    SkipCount = 1,
    EditFun = fun(T) ->
                      T#ether{type = ?NEW_VAL}
              end,
    Packet2 = linc_us3_packet_edit:find_and_edit_skip(Packet, ether,
                                                      EditFun, SkipCount),
    ?assertEqual(NewPacket, Packet2).

outermost_header() ->
    EmptyOutermostHeader = {[], {ip_proto, ?NEW_VAL}, []},
    set_field([EmptyOutermostHeader]),
    
    Packet = [#ether{}, #ipv4{}],
    Header = ipv4,
    Header2 = linc_us3_packet_edit:find_outermost_header(Packet, [ipv4]),
    ?assertEqual(Header, Header2).

ethernet() ->
    EthType = {[#ether{type = ?INIT_VAL}], {eth_type, ?NEW_VAL}, [#ether{type = ?NEW_VAL}]},
    EthDst = {[#ether{dhost = ?INIT_VAL}], {eth_dst, ?NEW_VAL}, [#ether{dhost = ?NEW_VAL}]},
    EthSrc = {[#ether{shost = ?INIT_VAL}], {eth_src, ?NEW_VAL}, [#ether{shost = ?NEW_VAL}]},
    set_field([EthType, EthDst, EthSrc]).

vlan() ->
    VlanVid = {[#ieee802_1q_tag{vid = ?INIT_VAL}], {vlan_vid, ?NEW_VAL}, [#ieee802_1q_tag{vid = ?NEW_VAL}]},
    VlanPcp = {[#ieee802_1q_tag{pcp = ?INIT_VAL}], {vlan_pcp, ?NEW_VAL}, [#ieee802_1q_tag{pcp = ?NEW_VAL}]},
    set_field([VlanVid, VlanPcp]).

arp() ->
    ArpOp = {[#arp{op = ?INIT_VAL}], {arp_op, ?NEW_VAL}, [#arp{op = ?NEW_VAL}]},
    ArpSpa = {[#arp{sip = ?INIT_VAL}], {arp_spa, ?NEW_VAL}, [#arp{sip = ?NEW_VAL}]},
    ArpTpa = {[#arp{tip = ?INIT_VAL}], {arp_tpa, ?NEW_VAL}, [#arp{tip = ?NEW_VAL}]},
    ArpSha = {[#arp{sha = ?INIT_VAL}], {arp_sha, ?NEW_VAL}, [#arp{sha = ?NEW_VAL}]},
    ArpTha = {[#arp{tha = ?INIT_VAL}], {arp_tha, ?NEW_VAL}, [#arp{tha = ?NEW_VAL}]},
    set_field([ArpOp, ArpSpa, ArpTpa, ArpSha, ArpTha]).

sctp() ->
    SctpSrc = {[#sctp{sport = ?INIT_VAL}], {sctp_src, ?NEW_VAL}, [#sctp{sport = ?NEW_VAL}]},
    SctpDst = {[#sctp{dport = ?INIT_VAL}], {sctp_dst, ?NEW_VAL}, [#sctp{dport = ?NEW_VAL}]},
    set_field([SctpSrc, SctpDst]).

icmp_v4() ->
    Icmp4Type = {[#icmp{type = ?INIT_VAL}], {icmpv4_type, ?NEW_VAL}, [#icmp{type = ?NEW_VAL}]},
    Icmp4Code = {[#icmp{code = ?INIT_VAL}], {icmpv4_code, ?NEW_VAL}, [#icmp{code = ?NEW_VAL}]},
    set_field([Icmp4Type, Icmp4Code]).

icmp_v6() ->
    Icmp6Type = {[#icmpv6{type = ?INIT_VAL}], {icmpv6_type, ?NEW_VAL}, [#icmpv6{type = ?NEW_VAL}]},
    Icmp6Code = {[#icmpv6{code = ?INIT_VAL}], {icmpv6_code, ?NEW_VAL}, [#icmpv6{code = ?NEW_VAL}]},
    set_field([Icmp6Type, Icmp6Code]).

tcp() ->
    TcpSrc = {[#tcp{sport = ?INIT_VAL}], {tcp_src, ?NEW_VAL}, [#tcp{sport = ?NEW_VAL}]},
    TcpDst = {[#tcp{dport = ?INIT_VAL}], {tcp_dst, ?NEW_VAL}, [#tcp{dport = ?NEW_VAL}]},
    set_field([TcpSrc, TcpDst]).

udp() ->
    UdpSrc = {[#udp{sport = ?INIT_VAL}], {udp_src, ?NEW_VAL}, [#udp{sport = ?NEW_VAL}]},
    UdpDst = {[#udp{dport = ?INIT_VAL}], {udp_dst, ?NEW_VAL}, [#udp{dport = ?NEW_VAL}]},
    set_field([UdpSrc, UdpDst]).

mpls() ->
    MplsLabel = {[#mpls_tag{stack = [#mpls_stack_entry{label = ?INIT_VAL},
                                     #mpls_stack_entry{label = ?INIT_VAL}]}],
                 {mpls_label, ?NEW_VAL},
                 [#mpls_tag{stack = [#mpls_stack_entry{label = ?NEW_VAL},
                                     #mpls_stack_entry{label = ?INIT_VAL}]}]},
    MplsTc = {[#mpls_tag{stack = [#mpls_stack_entry{qos = 0, pri = 0, ecn = 0},
                                  #mpls_stack_entry{qos = 0, pri = 0, ecn = 0}
                                 ]}],
              {mpls_tc, <<1:1,1:1,1:1>>},
              [#mpls_tag{stack = [#mpls_stack_entry{qos = 1, pri = 1, ecn = 1},
                                  #mpls_stack_entry{qos = 0, pri = 0, ecn = 0}
                                 ]}]},
    set_field([MplsLabel, MplsTc]).

ip_v4() ->
    Ip4Proto = {[#ipv4{p = ?INIT_VAL}], {ip_proto, ?NEW_VAL}, [#ipv4{p = ?NEW_VAL}]},
    Ip4Dscp = {[#ipv4{dscp = ?INIT_VAL}], {ip_dscp, ?NEW_VAL}, [#ipv4{dscp = ?NEW_VAL}]},
    Ip4Ecn = {[#ipv4{ecn = ?INIT_VAL}], {ip_ecn, ?NEW_VAL}, [#ipv4{ecn = ?NEW_VAL}]},
    Ip4Src = {[#ipv4{saddr = ?INIT_VAL}], {ipv4_src, ?NEW_VAL}, [#ipv4{saddr = ?NEW_VAL}]},
    Ip4Dst = {[#ipv4{daddr = ?INIT_VAL}], {ipv4_dst, ?NEW_VAL}, [#ipv4{daddr = ?NEW_VAL}]},
    set_field([Ip4Proto, Ip4Dscp, Ip4Ecn, Ip4Src, Ip4Dst]).

ip_v6() ->
    Ip6Proto = {[#ipv6{next = ?INIT_VAL}], {ip_proto, ?NEW_VAL}, [#ipv6{next = ?NEW_VAL}]},
    Ip6Dscp = {[#ipv6{class = <<0:6, 0:2>>}], {ip_dscp, <<1:6>>}, [#ipv6{class = <<1:6, 0:2>>}]},
    Ip6Ecn = {[#ipv6{class = <<0:6, 0:2>>}], {ip_ecn, <<1:2>>}, [#ipv6{class = <<0:6, 1:2>>}]},
    Ip6Src = {[#ipv6{saddr = ?INIT_VAL}], {ipv6_src, ?NEW_VAL}, [#ipv6{saddr = ?NEW_VAL}]},
    Ip6Dst = {[#ipv6{daddr = ?INIT_VAL}], {ipv6_dst, ?NEW_VAL}, [#ipv6{daddr = ?NEW_VAL}]},
    Ip6Flabel = {[#ipv6{flow = ?INIT_VAL}], {ipv6_flabel, ?NEW_VAL}, [#ipv6{flow = ?NEW_VAL}]},
    Ip6NdTarget1 = {[#ndp_ns{tgt_addr = ?INIT_VAL}, #ndp_na{src_addr = ?INIT_VAL}],
                    {ipv6_nd_target, ?NEW_VAL},
                    [#ndp_ns{tgt_addr = ?NEW_VAL}, #ndp_na{src_addr = ?INIT_VAL}]},
    Ip6NdTarget2 = {[#ndp_na{src_addr = ?INIT_VAL}, #ndp_ns{tgt_addr = ?INIT_VAL}],
                    {ipv6_nd_target, ?NEW_VAL},
                    [#ndp_na{src_addr = ?NEW_VAL}, #ndp_ns{tgt_addr = ?INIT_VAL}]},
    Ip6NdSll1 = {[#ndp_ns{sll = ?INIT_VAL}, #ndp_na{tll = ?INIT_VAL}],
                 {ipv6_nd_sll, ?NEW_VAL},
                 [#ndp_ns{sll = ?NEW_VAL}, #ndp_na{tll = ?INIT_VAL}]},
    Ip6NdSll2 = {[#ndp_na{tll = ?INIT_VAL}, #ndp_ns{sll = ?INIT_VAL}],
                 {ipv6_nd_sll, ?NEW_VAL},
                 [#ndp_na{tll = ?NEW_VAL}, #ndp_ns{sll = ?INIT_VAL}]},
    set_field([Ip6Proto, Ip6Dscp, Ip6Ecn, Ip6Src, Ip6Dst, Ip6Flabel,
               Ip6NdTarget1, Ip6NdTarget2, Ip6NdSll1, Ip6NdSll2]).

%% Fixtures --------------------------------------------------------------------

setup() ->
    mock(?MOCKED).

teardown(_) ->
    unmock(?MOCKED).

set_field(TestData) ->
    [begin
         Field = #ofp_field{name = Name, value = Value},
         Packet2 = linc_us3_packet_edit:set_field(Field, Packet),
         ?assertEqual(NewPacket, Packet2)
     end || {Packet, {Name, Value}, NewPacket} <- TestData].
