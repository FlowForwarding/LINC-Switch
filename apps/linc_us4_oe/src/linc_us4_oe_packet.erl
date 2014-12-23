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
%% @doc Module defines tools and functions for packet manipulations
-module(linc_us4_oe_packet).

-export([binary_to_record/3,
         optical_packet_to_record/3,
         strip_optical_headers/1,
         find/2,
         find_and_edit/3,
         find_and_edit_skip/4,
         find_outermost_header/2,
         set_field/2,
         decrement_dscp/2]).

-include_lib("of_protocol/include/of_protocol.hrl").
-include_lib("of_protocol/include/ofp_v4.hrl").
-include_lib("linc/include/linc_logger.hrl").
-include_lib("linc/include/linc_oe.hrl").
-include_lib("pkt/include/pkt.hrl").
-include("linc_us4_oe.hrl").

%%------------------------------------------------------------------------------
%% @doc Parse binary representation of OF-Protocol packets and convert them
%% to record representation.
-spec binary_to_record(binary(), integer(), ofp_port_no()) -> #linc_pkt{}.
binary_to_record(Binary, SwitchId, Port) ->
    try
        Packet = pkt:decapsulate(Binary),
        %% From OFP 1.3.1 spec, page 78:
        %% When a packet is received directly on a physical port and not
        %% processed by a logical port, OFPXMT_OFB_IN_PORT and
        %% OFPXMT_OFB_IN_PHY_PORT have the same value, the OpenFlow port no
        %% of this physical port. OFPXMT_OFB_IN_PHY_PORT may be omitted if it
        %% has the same value as OFPXMT_OFB_IN_PORT.
        Fields = [linc_us4_oe_convert:ofp_field(in_port, <<Port:32>>)
                  || is_integer(Port)]
            ++ linc_us4_oe_convert:packet_fields(Packet),
        #linc_pkt{packet = Packet,
                  fields =
                      #ofp_match{fields = Fields},
                  in_port = Port,
                  size = byte_size(Binary),
                  switch_id = SwitchId}
    catch
        E1:E2 ->
            ?ERROR("Decapsulate failed for pkt: ~p because: ~p:~p",
                   [Binary, E1, E2]),
            #linc_pkt{}
    end.

optical_packet_to_record(Packet, SwitchId, Port) ->
    try
        Fields = [linc_us4_oe_convert:ofp_field(in_port, <<Port:32>>)
                  || is_integer(Port)]
            ++ linc_us4_oe_convert:packet_fields(Packet),
        #linc_pkt{packet = Packet,
                  fields =
                      #ofp_match{fields = Fields},
                  in_port = Port,
                  size = byte_size(term_to_binary(Packet)),
                  switch_id = SwitchId}
    catch
        E1:E2 ->
            ?ERROR("Decapsulate failed for pkt: ~p because: ~p:~p",
                   [Packet, E1, E2]),
            #linc_pkt{}
    end.

strip_optical_headers(Packet) ->
    Filter = fun(#och_sigtype{}) ->
                     false;
                (#och_sigid{}) ->
                     false;
                (_) ->
                     true
             end,
    lists:filter(Filter, Packet).

%%------------------------------------------------------------------------------
%% @doc Looks for given element/tag in packet, returns 'not_found' or the
%% tuple {index where found, element which was found}. The index is to find
%% which element occured before other while doing searches for different tags.
-spec find(Pkt :: pkt:packet(), Tag :: atom()) ->
                  not_found | {integer(), tuple()}.

find(Pkt, Tag) -> find_2(Pkt, Tag, 0).

find_2([], _, _) ->
    not_found;
find_2([X | _], Tag, Index) when element(1, X) =:= Tag ->
    {Index, X};
find_2([_ | Rest], Tag, Index) ->
    find_2(Rest, Tag, Index+1).

%%------------------------------------------------------------------------------
%% @doc Scans the packet Pkt until first element of type Tag found, runs
%% fun() F on it, returns modified packet with the return value of fun() F.
%% Different actions are taken if F() returns list of atom 'delete'.
-spec find_and_edit(Pkt :: pkt:packet(),
                    Tag :: atom(),
                    F :: fun()) -> pkt:packet().

find_and_edit(Pkt, Tag, F) ->
    find_and_edit_2(Pkt, Tag, F, [], 0).

%%------------------------------------------------------------------------------
%% @doc Scans the packet Pkt until first element of type Tag found, runs
%% fun() F on it, returns modified packet with the return value of fun() F.
%% Different actions are taken if F() returns list or atom 'delete'.
-spec find_and_edit_skip(Pkt :: pkt:packet(),
                         Tag :: atom(),
                         F :: fun(),
                         Skips :: integer()) -> pkt:packet().

find_and_edit_skip(Pkt, Tag, F, Skips) ->
    find_and_edit_2(Pkt, Tag, F, [], Skips).

%%------------------------------------------------------------------------------
-spec find_and_edit_2(Pkt :: pkt:packet(),
                      Tag :: atom(),
                      F :: fun(),
                      Accum :: pkt:packet(),
                      Skips :: integer()) -> pkt:packet().

find_and_edit_2([], _, _, Accum, _) ->
    lists:reverse(Accum);

%% When match found and Skip count is 0 (no skip)
%% NOTE: the following code abuses the fact records are tuples
find_and_edit_2([PktFirst | Rest], Tag, F, Accum, 0)
  when element(1, PktFirst) =:= Tag ->
    %% F() should return new tag to replace the one we're processing,
    %% a list of tags (to replace and insert) or a special atom 'delete'.
    case F(PktFirst) of
        L when is_list(L) ->
            %% TODO: can this be done faster? Like lists:flatten or something?
            lists:reverse(Accum) ++ L ++ Rest;
        'delete' ->
            lists:reverse(Accum) ++ Rest;
        NewPktElement ->
            %% return it and the rest plus accumulator
            %% TODO: can this be done faster? Like lists:flatten or something?
            lists:reverse(Accum) ++ [NewPktElement | Rest]
    end;

%% When match found but skip is requested, just decrement skip and continue
find_and_edit_2([PktFirst | Rest], Tag, F, Accum, Skips)
  when element(1, PktFirst) =:= Tag ->
    find_and_edit_2(Rest, Tag, F, [PktFirst | Accum], Skips-1);

find_and_edit_2([PktFirst | Rest], Tag, F, Accum, Skips) ->
    find_and_edit_2(Rest, Tag, F, [PktFirst | Accum], Skips).

%%------------------------------------------------------------------------------
%% @doc Scans the Pkt looking for tags, the first tag in set is returned or
%% 'not_found' is returned if no tags in list
find_outermost_header([], _) ->
    not_found;
find_outermost_header([Header | Rest], TagList) ->
    TagName = element(1, Header),
    case lists:member(TagName, TagList) of
        true ->
            TagName;
        false ->
            find_outermost_header(Rest, TagList)
    end.

%%------------------------------------------------------------------------------
%% @doc Changes given field to given value in packet. If there are multiple
%% locations for that field, the topmost tag is chosen.
%% @end

-spec set_field(F :: ofp_field(), Pkt :: pkt:packet()) -> pkt:packet().
set_field(#ofp_field{ name = eth_type, value = <<Value:16>> }, Pkt) ->
    find_and_edit(Pkt, ether, fun(H) -> H#ether{type = Value} end);
set_field(#ofp_field{ name = eth_dst, value = Value }, Pkt) ->
    find_and_edit(Pkt, ether, fun(H) -> H#ether{dhost = Value} end);
set_field(#ofp_field{ name = eth_src, value = Value }, Pkt) ->
    find_and_edit(Pkt, ether, fun(H) -> H#ether{shost = Value} end);

set_field(#ofp_field{ name = vlan_vid,
                      value = <<_VLANPresence:1, Value:12/bits>>}, Pkt) ->
    find_and_edit(Pkt, ieee802_1q_tag, fun(H) ->
                                               H#ieee802_1q_tag{vid = Value}
                                       end);
set_field(#ofp_field{ name = vlan_pcp, value = <<Value:3>> }, Pkt) ->
    find_and_edit(Pkt, ieee802_1q_tag, fun(H) ->
                                               H#ieee802_1q_tag{pcp = Value}
                                       end);

set_field(#ofp_field{ name = arp_op, value = <<Value:16>> }, Pkt) ->
    find_and_edit(Pkt, arp, fun(H) -> H#arp{op = Value} end);
set_field(#ofp_field{ name = arp_spa, value = Value }, Pkt) ->
    find_and_edit(Pkt, arp, fun(H) -> H#arp{sip = Value} end);
set_field(#ofp_field{ name = arp_tpa, value = Value }, Pkt) ->
    find_and_edit(Pkt, arp, fun(H) -> H#arp{tip = Value} end);
set_field(#ofp_field{ name = arp_sha, value = Value }, Pkt) ->
    find_and_edit(Pkt, arp, fun(H) -> H#arp{sha = Value} end);
set_field(#ofp_field{ name = arp_tha, value = Value }, Pkt) ->
    find_and_edit(Pkt, arp, fun(H) -> H#arp{tha = Value} end);

set_field(#ofp_field{ name = sctp_src, value = <<Value:16>> }, Pkt) ->
    find_and_edit(Pkt, sctp, fun(H) -> H#sctp{sport = Value} end);
set_field(#ofp_field{ name = sctp_dst, value = <<Value:16>> }, Pkt) ->
    find_and_edit(Pkt, sctp, fun(H) -> H#sctp{dport = Value} end);

set_field(#ofp_field{ name = mpls_label, value = Value }, Pkt) ->
    find_and_edit(Pkt, mpls_tag,
                  fun(H) ->
                          [S1 | S] = H#mpls_tag.stack,
                          S1b = S1#mpls_stack_entry{label = Value},
                          H#mpls_tag{stack = [S1b | S]}
                  end);
set_field(#ofp_field{ name = mpls_tc, value = Value }, Pkt) ->
    find_and_edit(Pkt, mpls_tag,
                  fun(H) ->
                          [S1 | S] = H#mpls_tag.stack,
                          <<QOS:1, PRI:1, ECN:1>> = Value,
                          S1b = S1#mpls_stack_entry{qos = QOS, pri = PRI,
                                                    ecn = ECN},
                          H#mpls_tag{stack = [S1b | S]}
                  end);

%% general IP fields, outermost ipv4 or ipv6 tag is chosen
set_field(#ofp_field{ name = ip_proto, value = <<Value:8>> }, Pkt) ->
    case find_outermost_header(Pkt, [ipv4, ipv6]) of
        not_found ->
            Pkt;
        ipv4 ->
            find_and_edit(Pkt, ipv4, fun(H) -> H#ipv4{p = Value} end);
        ipv6 ->
            find_and_edit(Pkt, ipv6, fun(H) -> H#ipv6{next = Value} end)
    end;
set_field(#ofp_field{ name = ip_dscp, value = <<Value:6>> }, Pkt) ->
    case find_outermost_header(Pkt, [ipv4, ipv6]) of
        not_found ->
            Pkt;
        ipv4 ->
            find_and_edit(Pkt, ipv4, fun(H) -> H#ipv4{dscp = Value} end);
        ipv6 ->
            find_and_edit(
              Pkt, ipv6, fun(H) ->
                                 <<_:6, ECN:2>> = <<(H#ipv6.class):8>>,
                                 <<NewClass:8>> = <<Value:6, ECN:2>>,
                                 H#ipv6{class = NewClass}
                         end)
    end;
set_field(#ofp_field{ name = ip_ecn, value = <<Value:2>> }, Pkt) ->
    case find_outermost_header(Pkt, [ipv4, ipv6]) of
        not_found ->
            Pkt;
        ipv4 ->
            find_and_edit(Pkt, ipv4, fun(H) -> H#ipv4{ecn = Value} end);
        ipv6 ->
            find_and_edit(
              Pkt, ipv6, fun(H) ->
                                 <<DSCP:6, _:2>> = <<(H#ipv6.class):8>>,
                                 <<NewClass:8>> = <<DSCP:6, Value:2>>,
                                 H#ipv6{class = NewClass}
                         end)
    end;

set_field(#ofp_field{ name = ipv4_src, value = Value }, Pkt) ->
    find_and_edit(Pkt, ipv4, fun(H) -> H#ipv4{saddr = Value} end);
set_field(#ofp_field{ name = ipv4_dst, value = Value }, Pkt) ->
    find_and_edit(Pkt, ipv4, fun(H) -> H#ipv4{daddr = Value} end);

set_field(#ofp_field{ name = ipv6_src, value = Value }, Pkt) ->
    find_and_edit(Pkt, ipv6, fun(H) -> H#ipv6{saddr = Value} end);
set_field(#ofp_field{ name = ipv6_dst, value = Value }, Pkt) ->
    find_and_edit(Pkt, ipv6, fun(H) -> H#ipv6{daddr = Value} end);
set_field(#ofp_field{ name = ipv6_flabel, value = <<Value:20>> }, Pkt) ->
    find_and_edit(Pkt, ipv6, fun(H) -> H#ipv6{flow = Value} end);

set_field(#ofp_field{ name = ipv6_nd_target, value = Value }, Pkt) ->
    case find_outermost_header(Pkt, [ndp_ns, ndp_na]) of
        not_found ->
            Pkt;
        ndp_ns ->
            find_and_edit(Pkt, ndp_ns, fun(H) ->
                                               H#ndp_ns{tgt_addr = Value}
                                       end);
        ndp_na ->
            find_and_edit(Pkt, ndp_na, fun(H) ->
                                               H#ndp_na{src_addr = Value}
                                       end)
    end;

set_field(#ofp_field{ name = ipv6_nd_sll, value = Value }, Pkt) ->
    %% TODO: a special value for SLL and TLL is 'undefined', how do we set it?
    case find_outermost_header(Pkt, [ndp_ns, ndp_na]) of
        not_found ->
            Pkt;
        ndp_ns ->
            find_and_edit(Pkt, ndp_ns, fun(H) -> H#ndp_ns{sll = Value} end);
        ndp_na ->
            find_and_edit(Pkt, ndp_na, fun(H) -> H#ndp_na{tll = Value} end)
    end;

set_field(#ofp_field{ name = icmpv4_type, value = <<Value:8>> }, Pkt) ->
    find_and_edit(Pkt, icmp, fun(H) -> H#icmp{type = Value} end);
set_field(#ofp_field{ name = icmpv4_code, value = <<Value:8>> }, Pkt) ->
    find_and_edit(Pkt, icmp, fun(H) -> H#icmp{code = Value} end);

set_field(#ofp_field{ name = icmpv6_type, value = <<Value:8>> }, Pkt) ->
    find_and_edit(Pkt, icmpv6, fun(H) -> H#icmpv6{type = Value} end);
set_field(#ofp_field{ name = icmpv6_code, value = <<Value:8>> }, Pkt) ->
    find_and_edit(Pkt, icmpv6, fun(H) -> H#icmpv6{code = Value} end);

set_field(#ofp_field{ name = tcp_src, value = <<Value:16>> }, Pkt) ->
    find_and_edit(Pkt, tcp, fun(H) -> H#tcp{sport = Value} end);
set_field(#ofp_field{ name = tcp_dst, value = <<Value:16>> }, Pkt) ->
    find_and_edit(Pkt, tcp, fun(H) -> H#tcp{dport = Value} end);

set_field(#ofp_field{ name = udp_src, value = <<Value:16>> }, Pkt) ->
    find_and_edit(Pkt, udp, fun(H) -> H#udp{sport = Value} end);
set_field(#ofp_field{ name = udp_dst, value = <<Value:16>> }, Pkt) ->
    find_and_edit(Pkt, udp, fun(H) -> H#udp{dport = Value} end);

%% Optical extension set field
set_field(#ofp_field{name = och_sigid = Key, value = <<Value:6/bytes>>},
          Pkt) ->
    <<GridType:1/bytes, ChannelSpacing:1/bytes,
      ChannelNumber:2/bytes, SpectralWidth:2/bytes>> = Value,
    Header = #och_sigid{grid_type = GridType,
                        channel_spacing = ChannelSpacing,
                        channel_number = ChannelNumber,
                        spectral_width = SpectralWidth},
    case find(Pkt, Key) of
        not_found ->
            [Header | Pkt];
        {_Idx, _H} ->
            %% Assumption that #och_sigid can occur once
            lists:keyreplace(Key, 1, Pkt, Header)
    end;

set_field(_, Pkt) ->
    Pkt.

decrement_dscp(Pkt, _N) ->
    %% TODO: Implement
    Pkt.
