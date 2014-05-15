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
-module(linc_us5_packet_tests).

-import(linc_us5_test_utils, [mock/1,
                              unmock/1,
                              check_if_called/1,
                              check_output_on_ports/0]).

-include_lib("of_protocol/include/of_protocol.hrl").
-include_lib("of_protocol/include/ofp_v5.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("pkt/include/pkt.hrl").
-include("linc_us5.hrl").

-define(MOCKED, []).
-define(INIT_VAL, 100).
-define(NEW_VAL, 200).
-define(INIT_VAL(Bits), <<100:Bits>>).
-define(NEW_VAL(Bits), <<200:Bits>>).


%% Tests -----------------------------------------------------------------------

basic_packet_edit_test_() ->
    {setup,
     fun setup/0,
     fun teardown/1,
     [{"Edit packet: Ethernet", ethernet()},
      {"Edit packet: VLAN", vlan()},
      {"Edit packet: ARP", arp()},
      {"Edit packet: SCTP", sctp()},
      {"Edit packet: ICMPv4", icmp_v4()},
      {"Edit packet: ICMPv6", icmp_v6()},
      {"Edit packet: TCP", tcp()},
      {"Edit packet: UDP", udp()},
      {"Edit packet: MPLS", mpls()},
      {"Edit packet: IPv4", ip_v4()},
      {"Edit packet: IPv6", ip_v6()}
     ]}.

corner_cases_packet_edit_test_() ->
    {setup,
     fun setup/0,
     fun teardown/1,
     [{"Edit packet: no header", no_header()},
      {"Edit packet: bad field", bad_field()},
      {"Edit packet: duplicated header", duplicated_header()},
      {"Edit packet: nested header", nested_header()},
      {"Edit packet: skip header", skip_header()},
      {"Edit packet: outermost header", outermost_header()}
     ]}.

no_header() ->
    EmptyHeader = {[], {eth_type, ?NEW_VAL(16)}, []},
    set_field([EmptyHeader]).

bad_field() ->
    Packet = [#ether{type = ?INIT_VAL}],
    BadField = {Packet, {bad_field, ?NEW_VAL(16)}, Packet},
    set_field([BadField]).

duplicated_header() ->
    Packet = [#ether{type = ?INIT_VAL}, #ether{type = ?INIT_VAL}],
    NewPacket = [#ether{type = ?NEW_VAL}, #ether{type = ?INIT_VAL}],
    DuplicatedHeader = {Packet, {eth_type, ?NEW_VAL(16)}, NewPacket},
    set_field([DuplicatedHeader]).

nested_header() ->
    Packet = [#arp{op = ?INIT_VAL}, #ether{type = ?INIT_VAL}],
    NewPacket = [#arp{op = ?INIT_VAL}, #ether{type = ?NEW_VAL}],
    EditField = {eth_type, ?NEW_VAL(16)},
    set_field([{Packet, EditField, NewPacket}]).

skip_header() ->
    ?_test(
       begin
           Packet = [#ether{type = ?INIT_VAL}, #ether{type = ?INIT_VAL}],
           NewPacket = [#ether{type = ?INIT_VAL}, #ether{type = ?NEW_VAL}],
           SkipCount = 1,
           EditFun = fun(T) ->
                             T#ether{type = ?NEW_VAL}
                     end,
           Packet2 = linc_us5_packet:find_and_edit_skip(Packet, ether,
                                                        EditFun, SkipCount),
           ?assertEqual(NewPacket, Packet2)
       end).

outermost_header() ->
    [
     begin
         EmptyOutermostHeader = {[], {ip_proto, ?NEW_VAL(8)}, []},
         set_field([EmptyOutermostHeader])
     end,
     ?_test(
        begin
           Packet = [#ether{}, #ipv4{}],
           Header = ipv4,
           Header2 = linc_us5_packet:find_outermost_header(Packet, [ipv4]),
           ?assertEqual(Header, Header2)
        end)
    ].

ethernet() ->
    EthType = {[#ether{type = ?INIT_VAL}], {eth_type, ?NEW_VAL(16)}, [#ether{type = ?NEW_VAL}]},
    EthDst = {[#ether{dhost = ?INIT_VAL(48)}], {eth_dst, ?NEW_VAL(48)}, [#ether{dhost = ?NEW_VAL(48)}]},
    EthSrc = {[#ether{shost = ?INIT_VAL(48)}], {eth_src, ?NEW_VAL(48)}, [#ether{shost = ?NEW_VAL(48)}]},
    set_field([EthType, EthDst, EthSrc]).

vlan() ->
    VlanVid = {[#ieee802_1q_tag{vid = <<(16#30A):12>>}],
               %% The least significat bit of 16#01 indicates vlan presence bit
               {vlan_vid, <<(16#01 bor 16#30B):13>>},
               [#ieee802_1q_tag{vid = <<(16#30B):12>>}]},
    VlanPcp = {[#ieee802_1q_tag{pcp = 1}], {vlan_pcp, <<2:3>>},
               [#ieee802_1q_tag{pcp = 2}]},
    set_field([VlanVid, VlanPcp]).

arp() ->
    ArpOp = {[#arp{op = ?INIT_VAL}], {arp_op, ?NEW_VAL(16)}, [#arp{op = ?NEW_VAL}]},
    ArpSpa = {[#arp{sip = ?INIT_VAL(32)}], {arp_spa, ?NEW_VAL(32)}, [#arp{sip = ?NEW_VAL(32)}]},
    ArpTpa = {[#arp{tip = ?INIT_VAL(32)}], {arp_tpa, ?NEW_VAL(32)}, [#arp{tip = ?NEW_VAL(32)}]},
    ArpSha = {[#arp{sha = ?INIT_VAL(48)}], {arp_sha, ?NEW_VAL(48)}, [#arp{sha = ?NEW_VAL(48)}]},
    ArpTha = {[#arp{tha = ?INIT_VAL(48)}], {arp_tha, ?NEW_VAL(48)}, [#arp{tha = ?NEW_VAL(48)}]},
    set_field([ArpOp, ArpSpa, ArpTpa, ArpSha, ArpTha]).

sctp() ->
    SctpSrc = {[#sctp{sport = ?INIT_VAL}], {sctp_src, ?NEW_VAL(16)}, [#sctp{sport = ?NEW_VAL}]},
    SctpDst = {[#sctp{dport = ?INIT_VAL}], {sctp_dst, ?NEW_VAL(16)}, [#sctp{dport = ?NEW_VAL}]},
    set_field([SctpSrc, SctpDst]).

icmp_v4() ->
    %% The default value for #icmp.un is a binary, but the encoding
    %% function only accepts integers.
    Icmp = #icmp{un = 0},
    Icmp4Type = {[Icmp#icmp{type = ?INIT_VAL}], {icmpv4_type, ?NEW_VAL(8)}, [Icmp#icmp{type = ?NEW_VAL}]},
    Icmp4Code = {[#icmp{code = ?INIT_VAL}], {icmpv4_code, ?NEW_VAL(8)}, [#icmp{code = ?NEW_VAL}]},
    set_field([Icmp4Type, Icmp4Code]).

icmp_v6() ->
    Icmp6Type = {[#icmpv6{type = ?INIT_VAL}], {icmpv6_type, ?NEW_VAL(8)}, [#icmpv6{type = ?NEW_VAL}]},
    Icmp6Code = {[#icmpv6{code = ?INIT_VAL}], {icmpv6_code, ?NEW_VAL(8)}, [#icmpv6{code = ?NEW_VAL}]},
    set_field([Icmp6Type, Icmp6Code]).

tcp() ->
    TcpSrc = {[#tcp{sport = ?INIT_VAL}], {tcp_src, ?NEW_VAL(16)}, [#tcp{sport = ?NEW_VAL}]},
    TcpDst = {[#tcp{dport = ?INIT_VAL}], {tcp_dst, ?NEW_VAL(16)}, [#tcp{dport = ?NEW_VAL}]},
    set_field([TcpSrc, TcpDst]).

udp() ->
    UdpSrc = {[#udp{sport = ?INIT_VAL}], {udp_src, ?NEW_VAL(16)}, [#udp{sport = ?NEW_VAL}]},
    UdpDst = {[#udp{dport = ?INIT_VAL}], {udp_dst, ?NEW_VAL(16)}, [#udp{dport = ?NEW_VAL}]},
    set_field([UdpSrc, UdpDst]).

mpls() ->
    MplsLabel = {[#mpls_tag{stack = [#mpls_stack_entry{label = ?INIT_VAL(20)},
                                     #mpls_stack_entry{label = ?INIT_VAL(20)}]}],
                 {mpls_label, ?NEW_VAL(20)},
                 [#mpls_tag{stack = [#mpls_stack_entry{label = ?NEW_VAL(20)},
                                     #mpls_stack_entry{label = ?INIT_VAL(20)}]}]},
    MplsTc = {[#mpls_tag{stack = [#mpls_stack_entry{qos = 0, pri = 0, ecn = 0},
                                  #mpls_stack_entry{qos = 0, pri = 0, ecn = 0}
                                 ]}],
              {mpls_tc, <<1:1,1:1,1:1>>},
              [#mpls_tag{stack = [#mpls_stack_entry{qos = 1, pri = 1, ecn = 1},
                                  #mpls_stack_entry{qos = 0, pri = 0, ecn = 0}
                                 ]}]},
    set_field([MplsLabel, MplsTc]).

ip_v4() ->
    Ip4Proto = {[#ipv4{p = ?INIT_VAL}], {ip_proto, ?NEW_VAL(8)}, [#ipv4{p = ?NEW_VAL}]},
    Ip4Dscp = {[#ipv4{dscp = 1}], {ip_dscp, <<2:6>>}, [#ipv4{dscp = 2}]},
    Ip4Ecn = {[#ipv4{ecn = 1}], {ip_ecn, <<2:2>>}, [#ipv4{ecn = 2}]},
    Ip4Src = {[#ipv4{saddr = ?INIT_VAL(32)}], {ipv4_src, ?NEW_VAL(32)}, [#ipv4{saddr = ?NEW_VAL(32)}]},
    Ip4Dst = {[#ipv4{daddr = ?INIT_VAL(32)}], {ipv4_dst, ?NEW_VAL(32)}, [#ipv4{daddr = ?NEW_VAL(32)}]},
    set_field([Ip4Proto, Ip4Dscp, Ip4Ecn, Ip4Src, Ip4Dst]).

ip_v6() ->
    %% The #ipv6 record has no default values for the saddr and daddr
    %% fields.
    Ipv6 = #ipv6{saddr = <<0:128>>, daddr = <<0:128>>},
    Ip6Proto = {[Ipv6#ipv6{next = ?INIT_VAL}], {ip_proto, ?NEW_VAL(8)}, [Ipv6#ipv6{next = ?NEW_VAL}]},
    Ip6Dscp = {[Ipv6#ipv6{class = 0}], {ip_dscp, <<1:6>>}, [Ipv6#ipv6{class = 1 bsl 2}]},
    Ip6Ecn = {[Ipv6#ipv6{class = 0}], {ip_ecn, <<1:2>>}, [Ipv6#ipv6{class = 1}]},
    Ip6Src = {[Ipv6#ipv6{saddr = ?INIT_VAL(128)}], {ipv6_src, ?NEW_VAL(128)}, [Ipv6#ipv6{saddr = ?NEW_VAL(128)}]},
    Ip6Dst = {[Ipv6#ipv6{daddr = ?INIT_VAL(128)}], {ipv6_dst, ?NEW_VAL(128)}, [Ipv6#ipv6{daddr = ?NEW_VAL(128)}]},
    Ip6Flabel = {[Ipv6#ipv6{flow = ?INIT_VAL}], {ipv6_flabel, ?NEW_VAL(20)}, [Ipv6#ipv6{flow = ?NEW_VAL}]},
    Ip6NdTarget1 = {[#ndp_ns{tgt_addr = ?INIT_VAL(128)}, #ndp_na{src_addr = ?INIT_VAL(128)}],
                    {ipv6_nd_target, ?NEW_VAL(128)},
                    [#ndp_ns{tgt_addr = ?NEW_VAL(128)}, #ndp_na{src_addr = ?INIT_VAL(128)}]},
    Ip6NdTarget2 = {[#ndp_na{src_addr = ?INIT_VAL(128)}, #ndp_ns{tgt_addr = ?INIT_VAL(128)}],
                    {ipv6_nd_target, ?NEW_VAL(128)},
                    [#ndp_na{src_addr = ?NEW_VAL(128)}, #ndp_ns{tgt_addr = ?INIT_VAL(128)}]},
    Ip6NdSll1 = {[#ndp_ns{sll = ?INIT_VAL(16)}, #ndp_na{tll = ?INIT_VAL(16)}],
                 {ipv6_nd_sll, ?NEW_VAL(16)},
                 [#ndp_ns{sll = ?NEW_VAL(16)}, #ndp_na{tll = ?INIT_VAL(16)}]},
    Ip6NdSll2 = {[#ndp_na{tll = ?INIT_VAL(16)}, #ndp_ns{sll = ?INIT_VAL(16)}],
                 {ipv6_nd_sll, ?NEW_VAL(16)},
                 [#ndp_na{tll = ?NEW_VAL(16)}, #ndp_ns{sll = ?INIT_VAL(16)}]},
    set_field([Ip6Proto, Ip6Dscp, Ip6Ecn, Ip6Src, Ip6Dst, Ip6Flabel,
               Ip6NdTarget1, Ip6NdTarget2, Ip6NdSll1, Ip6NdSll2]).

%% Fixtures --------------------------------------------------------------------

setup() ->
    mock(?MOCKED).

teardown(_) ->
    unmock(?MOCKED).

set_field(TestData) ->
    [{"set field " ++ atom_to_list(Name),
      ?_test(
         begin
             %% only binaries are allowed in #ofp_field.value
             case Value of
                 _ when is_bitstring(Value) -> ok
             end,
             %% check that the packet can be encoded before the change
             Packet =/= [] andalso (_ = encode(hd(Packet))),
             %% perform the change
             Field = #ofp_field{name = Name, value = Value},
             Packet2 = linc_us5_packet:set_field(Field, Packet),
             %% check that the packet can be encoded after the change
             Packet2 =/= [] andalso (_ = encode(hd(Packet2))),
             %% check that the result matches what we expected
             ?assertEqual(NewPacket, Packet2)
         end)} || {Packet, {Name, Value}, NewPacket} <- TestData].

encode(Packet = #ieee802_1q_tag{}) ->
    pkt:encapsulate([Packet, #ipv4{}, #tcp{}]);
encode(Packet = #mpls_tag{}) ->
    pkt:encapsulate([Packet, #ipv4{}, #tcp{}]);
encode(Packet = #ndp_na{}) ->
    Ipv6 = #ipv6{saddr = <<0:128>>, daddr = <<0:128>>},
    pkt:encapsulate([Ipv6, #icmpv6{}, Packet]);
encode(Packet = #ndp_ns{}) ->
    Ipv6 = #ipv6{saddr = <<0:128>>, daddr = <<0:128>>},
    pkt:encapsulate([Ipv6, #icmpv6{}, Packet]);
encode(Packet = #tcp{}) ->
    pkt_tcp:encapsulate(Packet, #ipv4{}, <<>>);
encode(Packet = #udp{}) ->
    pkt_udp:encapsulate(Packet, #ipv4{}, <<>>);
encode(_Packet = #sctp{}) ->
    %% pkt.erl cannot encode SCTP packets
    ignore;
encode(Packet) when is_tuple(Packet) ->
    Type = element(1, Packet),
    pkt:Type(Packet).
