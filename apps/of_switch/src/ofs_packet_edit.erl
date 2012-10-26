%%%-----------------------------------------------------------------------------
%%% @doc Module defines tools and functions for packet manipulations
%%%-----------------------------------------------------------------------------

-module(ofs_packet_edit).
-author("Erlang Solutions Ltd. <openflow@erlang-solutions.com>").

-export([find/2,
		 find_and_edit/3,
		 find_and_edit_skip/4,
		 find_outermost_header/2,
		 set_field/2]).

-include_lib("pkt/include/pkt.hrl").
-include("ofs_userspace.hrl").

%%- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
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
	

%%- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
%% @doc Scans the packet Pkt until first element of type Tag found, runs fun() F on it,
%% returns modified packet with the return value of fun() F. Different actions are taken
%% if F() returns list of atom 'delete' (see code below)
-spec find_and_edit(Pkt :: pkt:packet(),
					Tag :: atom(),
					F :: fun()) -> pkt:packet().

find_and_edit(Pkt, Tag, F) ->
	find_and_edit_2(Pkt, Tag, F, [], 0).

%%- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
%% @doc Scans the packet Pkt until first element of type Tag found, runs fun() F on it,
%% returns modified packet with the return value of fun() F. Different actions are taken
%% if F() returns list of atom 'delete' (see code below)
-spec find_and_edit_skip(Pkt :: pkt:packet(),
						 Tag :: atom(),
						 F :: fun(),
						 Skips :: integer()) -> pkt:packet().

find_and_edit_skip(Pkt, Tag, F, Skips) ->
	find_and_edit_2(Pkt, Tag, F, [], Skips).

%%- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
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

%%- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
%% @doc Scans the Pkt looking for tags, the first tag in set is returned or
%% 'not_found' is returned if no tags in list
find_outermost_header(Pkt, TagList) ->
	find_outermost_header_2(Pkt, sets:from_list(TagList), 0).

find_outermost_header_2([], _, _) -> not_found;

find_outermost_header_2([Header | Rest], Set, Index) ->
	%% the next line assumes Header is one of pkt.hrl records (a tuple)
	case sets:is_element(element(1, Header), Set) of
		true ->
			{Index, Header};
		false ->
			find_outermost_header_2(Rest, Set, Index + 1)
	end.

%%- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
-spec set_field(F :: ofp_field(), Pkt :: pkt:packet()) -> pkt:packet().

%% @doc Changes given field to given value in packet. If there are multiple
%% locations for that field, the topmost tag is chosen.
%% @end

%% -define(SETFIELD(RecordTag, OXMField, RecField),
%% 		set_field(#ofp_field{ field = OXMField, value = Value, has_mask = _M }, Pkt) ->
%% 			   find_and_edit(Pkt, RecordTag,
%% 							 fun(H) -> H#RecordTag.RecField = Value end).

%% ?SETFIELD(ether, eth_type, type);

set_field(#ofp_field{ field = eth_type, value = Value }, Pkt) ->
	find_and_edit(Pkt, ether, fun(H) -> H#ether{type = Value} end);
set_field(#ofp_field{ field = eth_dst, value = Value }, Pkt) ->
	find_and_edit(Pkt, ether, fun(H) -> H#ether{dhost = Value} end);
set_field(#ofp_field{ field = eth_src, value = Value }, Pkt) ->
	find_and_edit(Pkt, ether, fun(H) -> H#ether{shost = Value} end);

set_field(#ofp_field{ field = vlan_vid, value = Value }, Pkt) ->
	find_and_edit(Pkt, ieee802_1q_tag, fun(H) -> H#ieee802_1q_tag{vid = Value} end);
set_field(#ofp_field{ field = vlan_pcp, value = Value }, Pkt) ->
	find_and_edit(Pkt, ieee802_1q_tag, fun(H) -> H#ieee802_1q_tag{pcp = Value} end);

set_field(#ofp_field{ field = arp_op, value = Value }, Pkt) ->
	find_and_edit(Pkt, arp, fun(H) -> H#arp{op = Value} end);
set_field(#ofp_field{ field = arp_spa, value = Value }, Pkt) ->
	find_and_edit(Pkt, arp, fun(H) -> H#arp{sip = Value} end);
set_field(#ofp_field{ field = arp_tpa, value = Value }, Pkt) ->
	find_and_edit(Pkt, arp, fun(H) -> H#arp{tip = Value} end);
set_field(#ofp_field{ field = arp_sha, value = Value }, Pkt) ->
	find_and_edit(Pkt, arp, fun(H) -> H#arp{sha = Value} end);
set_field(#ofp_field{ field = arp_tha, value = Value }, Pkt) ->
	find_and_edit(Pkt, arp, fun(H) -> H#arp{tha = Value} end);

set_field(#ofp_field{ field = sctp_src, value = Value }, Pkt) ->
	find_and_edit(Pkt, sctp, fun(H) -> H#sctp{sport = Value} end);
set_field(#ofp_field{ field = sctp_dst, value = Value }, Pkt) ->
	find_and_edit(Pkt, sctp, fun(H) -> H#sctp{dport = Value} end);

set_field(#ofp_field{ field = mpls_label, value = Value }, Pkt) ->
	find_and_edit(Pkt, mpls_tag,
				  fun(H) ->
						  [S1 | S] = H#mpls_tag.stack, 
						  S1b = S1#mpls_stack_entry{label = Value},
						  H#mpls_tag{stack = [S1b | S]}
				  end);
set_field(#ofp_field{ field = mpls_tc, value = Value }, Pkt) ->
	find_and_edit(Pkt, mpls_tag,
				  fun(H) ->
						  [S1 | S] = H#mpls_tag.stack,
						  <<QOS:1, PRI:1, ECN:1>> = Value,
						  S1b = S1#mpls_stack_entry{qos = QOS, pri = PRI, ecn = ECN},
						  H#mpls_tag{stack = [S1b | S]}
				  end);

% general IP fields, outermost ipv4 or ipv6 tag is chosen
set_field(#ofp_field{ field = ip_proto, value = Value }, Pkt) ->
	case find_outermost_header(Pkt, [ipv4, ipv6]) of
		not_found ->
			Pkt;
		ipv4 ->
			find_and_edit(Pkt, ipv4, fun(H) -> H#ipv4{p = Value} end);
		ipv6 ->
			find_and_edit(Pkt, ipv6, fun(H) -> H#ipv6{next = Value} end)
	end;
set_field(#ofp_field{ field = ip_dscp, value = Value }, Pkt) ->
	case find_outermost_header(Pkt, [ipv4, ipv6]) of
		not_found -> Pkt;
		ipv4 -> find_and_edit(Pkt, ipv4, fun(H) -> H#ipv4{dscp = Value} end);
		ipv6 -> find_and_edit(
				  Pkt, ipv6, fun(H) ->
									 <<_:6/bits, ECN:2/bits>> = H#ipv6.class,
									 H#ipv6{class = <<Value:6/bits, ECN:2/bits>>}
							 end )
	end;
set_field(#ofp_field{ field = ip_ecn, value = Value }, Pkt) ->
	case find_outermost_header(Pkt, [ipv4, ipv6]) of
		not_found -> Pkt;
		ipv4 -> find_and_edit(Pkt, ipv4, fun(H) -> H#ipv4{ecn = Value} end);
		ipv6 -> find_and_edit(
				  Pkt, ipv6, fun(H) ->
									 <<DSCP:6/bits, _:2/bits>> = H#ipv6.class,
									 H#ipv6{class = <<DSCP:6/bits, Value:2/bits>>}
							 end )
	end;

set_field(#ofp_field{ field = ipv4_src, value = Value }, Pkt) ->
	find_and_edit(Pkt, ipv4, fun(H) -> H#ipv4{saddr = Value} end);
set_field(#ofp_field{ field = ipv4_dst, value = Value }, Pkt) ->
	find_and_edit(Pkt, ipv4, fun(H) -> H#ipv4{daddr = Value} end);

set_field(#ofp_field{ field = ipv6_src, value = Value }, Pkt) ->
	find_and_edit(Pkt, ipv6, fun(H) -> H#ipv6{saddr = Value} end);
set_field(#ofp_field{ field = ipv6_dst, value = Value }, Pkt) ->
	find_and_edit(Pkt, ipv6, fun(H) -> H#ipv6{daddr = Value} end);
set_field(#ofp_field{ field = ipv6_flabel, value = Value }, Pkt) ->
	find_and_edit(Pkt, ipv6, fun(H) -> H#ipv6{flow = Value} end);

set_field(#ofp_field{ field = icmpv4_type, value = Value }, Pkt) ->
	find_and_edit(Pkt, icmp, fun(H) -> H#icmp{type = Value} end);
set_field(#ofp_field{ field = icmpv4_code, value = Value }, Pkt) ->
	find_and_edit(Pkt, icmp, fun(H) -> H#icmp{code = Value} end);

set_field(#ofp_field{ field = icmpv6_type, value = Value }, Pkt) ->
	find_and_edit(Pkt, icmpv6, fun(H) -> H#icmpv6{type = Value} end);
set_field(#ofp_field{ field = icmpv6_code, value = Value }, Pkt) ->
	find_and_edit(Pkt, icmpv6, fun(H) -> H#icmpv6{code = Value} end);

set_field(#ofp_field{ field = ipv6_nd_target, value = Value }, Pkt) ->
	case find_outermost_header(Pkt, [ndp_ns, ndp_na]) of
		not_found -> Pkt;
		ndp_ns -> find_and_edit(Pkt, ndp_ns, fun(H) -> H#ndp_ns{tgt_addr = Value} end);
		ndp_na -> find_and_edit(Pkt, ndp_na, fun(H) -> H#ndp_na{src_addr = Value} end)
	end;

set_field(#ofp_field{ field = ipv6_nd_sll, value = Value }, Pkt) ->
	%% TODO: a special value for SLL and TLL is 'undefined', how do we set it?
	case find_outermost_header(Pkt, [ndp_ns, ndp_na]) of
		not_found -> Pkt;
		ndp_ns -> find_and_edit(Pkt, ndp_ns, fun(H) -> H#ndp_ns{sll = Value} end);
		ndp_na -> find_and_edit(Pkt, ndp_na, fun(H) -> H#ndp_na{tll = Value} end)
	end;

set_field(#ofp_field{ field = tcp_src, value = Value }, Pkt) ->
	find_and_edit(Pkt, tcp, fun(H) -> H#tcp{sport = Value} end);
set_field(#ofp_field{ field = tcp_dst, value = Value }, Pkt) ->
	find_and_edit(Pkt, tcp, fun(H) -> H#tcp{dport = Value} end);

set_field(#ofp_field{ field = udp_src, value = Value }, Pkt) ->
	find_and_edit(Pkt, udp, fun(H) -> H#udp{sport = Value} end);
set_field(#ofp_field{ field = udp_dst, value = Value }, Pkt) ->
	find_and_edit(Pkt, udp, fun(H) -> H#udp{dport = Value} end);

set_field(_, Pkt) ->
	Pkt. %% default do nothing

%% @---doc If Value is integer, just returns it. If value is binary interprets it as
%% string of bits and extracts a value of Bits size
%% integer_or_bin(_, Value) when is_integer(Value) ->
%% 	Value;
%% integer_or_bin(Bits, Value) ->
%% 	<<IntValue:Bits>> = Value,
%% 	IntValue.
