-module(ofs_userspace_convert).

-export([ofp_field/2,
         packet_fields/1]).

-include_lib("pkt/include/pkt.hrl").
-include("ofs_userspace.hrl").

%%% Packet conversion functions ------------------------------------------------

-spec ofp_field(atom(), binary() | integer()) -> ofp_field().
ofp_field(Field, Value) ->
    #ofp_field{class = openflow_basic,
               field = Field,
               has_mask = false,
               value = Value}.

-spec packet_fields([pkt:packet()]) -> [ofp_field()].
packet_fields(Packet) ->
    lists:flatmap(fun header_fields/1, Packet).

%%%-----------------------------------------------------------------------------
%%% Helpers
%%%-----------------------------------------------------------------------------

-spec header_fields([pkt:packet()]) -> [ofp_field()].
header_fields(#ether{type = Type,
                     dhost = DHost,
                     shost = SHost}) ->
    [ofp_field(eth_type, <<Type:16>>),
     ofp_field(eth_dst, DHost),
     ofp_field(eth_src, SHost)];
header_fields(#ieee802_1q_tag{vid = VID,
                              pcp = PCP}) ->
    [ofp_field(vlan_vid, VID),
     ofp_field(vlan_pcp, <<PCP:3>>)];
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
     ofp_field(sctp_src, <<Dst:16>>)];
header_fields(#mpls_tag{stack = [#mpls_stack_entry{label = L,
                                                   qos = QOS,
                                                   pri = PRI,
                                                   ecn = ECN}]}) ->
    [ofp_field(mpls_label, L),
     ofp_field(mpls_tc, <<QOS:1, PRI:1, ECN:1>>)];
header_fields(#ipv4{p = Proto,
                    saddr = SAddr,
                    daddr = DAddr}) ->
    [ofp_field(ip_proto, <<Proto:8>>),
     ofp_field(ipv4_src, SAddr),
     ofp_field(ipv4_dst, DAddr)];
header_fields(#ipv6{next = Proto,
                    saddr = SAddr,
                    daddr = DAddr,
                    flow = Flow}) ->
    [ofp_field(ip_proto, <<Proto:8>>),
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
    [ofp_field(ipv6_nd_sll, TLL) || TLL =/= undefined];
header_fields(#tcp{sport = SPort,
                   dport = DPort}) ->
    [ofp_field(tcp_src, <<SPort:16>>),
     ofp_field(tcp_dst, <<DPort:16>>)];
header_fields(#udp{sport = SPort,
                   dport = DPort}) ->
    [ofp_field(udp_src, <<SPort:16>>),
     ofp_field(udp_dst, <<DPort:16>>)].
