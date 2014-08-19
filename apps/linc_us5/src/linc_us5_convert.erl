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
%% @doc Module with helpers for converting packets.
-module(linc_us5_convert).

-export([ofp_field/2,
         packet_fields/1]).

-include_lib("of_protocol/include/of_protocol.hrl").
-include_lib("of_protocol/include/ofp_v5.hrl").
-include_lib("linc/include/linc_logger.hrl").
-include_lib("pkt/include/pkt.hrl").
-include("linc_us5.hrl").

%%% Packet conversion functions ------------------------------------------------

-spec ofp_field(atom(), binary() | integer()) -> ofp_field().
ofp_field(Field, Value) ->
    #ofp_field{class = openflow_basic,
               name = Field,
               has_mask = false,
               value = Value}.

-spec packet_fields([pkt:packet()]) -> [ofp_field()].
packet_fields(Packet) ->
    eth_and_vlan_fields(Packet)
        ++ lists:flatmap(fun header_fields/1, Packet).

%%%-----------------------------------------------------------------------------
%%% Helpers
%%%-----------------------------------------------------------------------------

%% @doc Does special handling for eth and vlan fields (because of eth_type).
-spec eth_and_vlan_fields(pkt:packet()) -> [ofp_field()].
eth_and_vlan_fields(P) ->
    case linc_us5_packet:find(P, ether) of
        not_found ->
            [];
        {_, #ether{type = EtherType,
                   dhost = DHost,
                   shost = SHost}} ->
            case linc_us5_packet:find(P, ieee802_1q_tag) of
                not_found ->
                    [ofp_field(eth_type, <<EtherType:16>>),
                     ofp_field(eth_dst, DHost),
                     ofp_field(eth_src, SHost)];
                {_, #ieee802_1q_tag{ether_type = VlanType,
                                    vid = <<VID:12>>,
                                    pcp = PCP}} ->
                    [ofp_field(eth_dst, DHost),
                     ofp_field(eth_src, SHost),
                     ofp_field(eth_type, <<VlanType:16>>),
                     ofp_field(vlan_vid,
                               <<(?OFPVID_PRESENT bor VID):13>>),
                     ofp_field(vlan_pcp, <<PCP:3>>)]
            end
    end.

%% @doc Extracts known fields from different packet header types
header_fields(#pbb{i_sid = ISID, i_uca = UCA}) ->
    [ofp_field(pbb_isid, <<ISID:24>>),
     ofp_field(pbb_uca, <<UCA:1>>)];
header_fields(#arp{op = Op,
                   sip = SPA,
                   tip = TPA,
                   sha = SHA,
                   tha = THA}) ->
    [ofp_field(arp_op, <<Op:16>>),
     ofp_field(arp_spa, SPA),
     ofp_field(arp_tpa, TPA),
     ofp_field(arp_sha, SHA),
     ofp_field(arp_tha, THA)];
header_fields(#sctp{sport = Src,
                    dport = Dst}) ->
    [ofp_field(sctp_src, <<Src:16>>),
     ofp_field(sctp_dst, <<Dst:16>>)];
header_fields(#mpls_tag{stack = [#mpls_stack_entry{label = L,
                                                   qos = QOS,
                                                   pri = PRI,
                                                   ecn = ECN,
                                                   bottom = BOS} | _Rest]}) ->
    [ofp_field(mpls_label, L),
     ofp_field(mpls_tc, <<QOS:1, PRI:1, ECN:1>>),
     ofp_field(mpls_bos, <<BOS:1>>)];
header_fields(#ipv4{p = Proto,
                    dscp = DSCP,
                    ecn = ECN,
                    saddr = SAddr,
                    daddr = DAddr}) ->
    [ofp_field(ip_proto, <<Proto:8>>),
     ofp_field(ip_dscp, <<DSCP:6>>),
     ofp_field(ip_ecn, <<ECN:2>>),
     ofp_field(ipv4_src, SAddr),
     ofp_field(ipv4_dst, DAddr)];
header_fields(#ipv6{next = Proto,
                    saddr = SAddr,
                    daddr = DAddr,
                    class = Class,
                    flow = Flow}) ->
    <<DSCP:6/bits, ECN:2/bits>> = <<Class:8>>,
    [ofp_field(ip_proto, <<Proto:8>>),
     ofp_field(ip_dscp, DSCP),
     ofp_field(ip_ecn, ECN),
     ofp_field(ipv6_src, SAddr),
     ofp_field(ipv6_dst, DAddr),
     ofp_field(ipv6_flabel, <<Flow:20>>)];
header_fields(#icmp{type = Type, code = Code}) ->
    [ofp_field(icmpv4_type, <<Type:8>>),
     ofp_field(icmpv4_code, <<Code:8>>)];
header_fields(#icmpv6{type = Type, code = Code}) ->
    [ofp_field(icmpv6_type, <<Type:8>>),
     ofp_field(icmpv6_code, <<Code:8>>)];
header_fields(#ndp_ns{tgt_addr = Addr, sll = SLL}) ->
    [ofp_field(ipv6_nd_target, Addr)] ++
    [ofp_field(ipv6_nd_sll, SLL) || SLL =/= undefined];
header_fields(#ndp_na{src_addr = Addr, tll = TLL}) ->
    [ofp_field(ipv6_nd_target, Addr)] ++ %% not a typo, target = src_addr
    [ofp_field(ipv6_nd_tll, TLL) || TLL =/= undefined];
header_fields(#tcp{sport = SPort,
                   dport = DPort}) ->
    [ofp_field(tcp_src, <<SPort:16>>),
     ofp_field(tcp_dst, <<DPort:16>>)];
header_fields(#udp{sport = SPort,
                   dport = DPort}) ->
    [ofp_field(udp_src, <<SPort:16>>),
     ofp_field(udp_dst, <<DPort:16>>)];
header_fields(_Other) ->
    [].
