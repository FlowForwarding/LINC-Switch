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
    packet_fields(Packet, []).

%%%-----------------------------------------------------------------------------
%%% Helpers
%%%-----------------------------------------------------------------------------

-spec packet_fields([pkt:packet()], [ofp_field()]) -> [ofp_field()].
packet_fields([], Fields) ->
    Fields;
packet_fields([#ether{type = Type,
                      dhost = DHost,
                      shost = SHost} | Rest], Fields) ->
    NewFields = [ofp_field(eth_type, <<Type:16>>),
                 ofp_field(eth_dst, DHost),
                 ofp_field(eth_src, SHost)],
    packet_fields(Rest, Fields ++ NewFields);
packet_fields([#ipv4{p = Proto,
                     saddr = SAddr,
                     daddr = DAddr} | Rest], Fields) ->
    NewFields = [ofp_field(ip_proto, <<Proto:8>>),
                 ofp_field(ipv4_src, SAddr),
                 ofp_field(ipv4_dst, DAddr)],
    packet_fields(Rest, Fields ++ NewFields);
packet_fields([#ipv6{next = Proto,
                     saddr = SAddr,
                     daddr = DAddr} | Rest], Fields) ->
    NewFields = [ofp_field(ip_proto, <<Proto:8>>),
                 ofp_field(ipv6_src, SAddr),
                 ofp_field(ipv6_dst, DAddr)],
    packet_fields(Rest, Fields ++ NewFields);
packet_fields([#tcp{sport = SPort,
                    dport = DPort} | Rest], Fields) ->
    NewFields = [ofp_field(tcp_src, <<SPort:16>>),
                 ofp_field(tcp_dst, <<DPort:16>>)],
    packet_fields(Rest, Fields ++ NewFields);
packet_fields([#udp{sport = SPort,
                    dport = DPort} | Rest], Fields) ->
    NewFields = [ofp_field(udp_src, <<SPort:16>>),
                 ofp_field(udp_dst, <<DPort:16>>)],
    packet_fields(Rest, Fields ++ NewFields);
packet_fields([_Other | Rest], Fields) ->
    packet_fields(Rest, Fields).
