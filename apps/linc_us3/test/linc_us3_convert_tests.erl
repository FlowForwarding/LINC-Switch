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
-module(linc_us3_convert_tests).

-import(linc_us3_test_utils, [mock/1,
                              unmock/1]).

-include_lib("of_protocol/include/of_protocol.hrl").
-include_lib("of_protocol/include/ofp_v3.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("pkt/include/pkt.hrl").

-define(MOCKED, []).

%% Tests -----------------------------------------------------------------------

convert_test_() ->
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
    Fields1 = linc_us3_convert:packet_fields(P1),
    F1 = lists:filter(fun(X) -> X#ofp_field.name == eth_type end, Fields1),
    ?assert(length(F1) =:= 1), % exactly 1 field added
    [EthType1 | _] = F1,
    ?assert(EthType1 =/= false),
    ?assert(EthType1#ofp_field.value =:= <<12345:16>>),

    P2 = [#ether{type = 12345}, #ieee802_1q_tag{ether_type = 22222}],
    Fields2 = linc_us3_convert:packet_fields(P2),
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
    Fields1 = linc_us3_convert:packet_fields(P1),
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
