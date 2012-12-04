%%%
%%% @doc Tests for OXM field related issues (#2 and #3) and possibly other
%%%
-module(unit_issue_2_3).

-include_lib("of_protocol/include/of_protocol.hrl").
-include_lib("of_protocol/include/ofp_v3.hrl").
-include_lib("linc/include/linc.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("pkt/include/pkt.hrl").
-include("linc_us4.hrl").

%%--------------------------------------------------------------------
%% @doc https://github.com/FlowForwarding/LINC-Switch/issues/2
%% OXM Ethertype field generated for packets ignores VLAN tags
issue2_test() ->
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

%%--------------------------------------------------------------------
%% @doc https://github.com/FlowForwarding/LINC-Switch/issues/3
%% OXM VLAN fields should match on outer VLAN tag only
issue3_test() ->
    P1 = [#ether{}, #ieee802_1q_tag{vid=333}, #ieee802_1q_tag{vid=444}],
    Fields1 = linc_us4_convert:packet_fields(P1),
    F1 = lists:filter(fun(X) -> X#ofp_field.name == vlan_vid end, Fields1),
    ?assert(length(F1) =:= 1), % exactly 1 field added
    [VLAN1 | _] = F1,
    ?assert(VLAN1 =/= false),
    ?assert(VLAN1#ofp_field.value =:= 333).
