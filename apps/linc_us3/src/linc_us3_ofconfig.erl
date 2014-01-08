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
%% @doc OF-Config module for userspace v3 backend.
-module(linc_us3_ofconfig).

-export([%% Setters
         set_port_features/3,
         set_port_config/3,
         set_queue_min_rate/4,
         set_queue_max_rate/4,
         %% Getters
         get_ports/1,
         get_flow_tables/2,
         get_capabilities/0,
         get_port_config/2,
         get_port_features/2,
         get_queues/1]).

-include_lib("of_config/include/of_config.hrl").
-include_lib("of_protocol/include/of_protocol.hrl").
-include_lib("of_protocol/include/ofp_v3.hrl").
-include("linc_us3.hrl").

-spec set_port_features(integer(), ofp_port_no(),
                        #features{} | undefined) -> ok.
set_port_features(_SwitchId, _PortNo, undefined) ->
    ok;
set_port_features(SwitchId, PortNo, Features) ->
    Features2 = linc_ofconfig:convert_port_features(Features),
    linc_us3_port:set_advertised_features(SwitchId, PortNo, Features2).

-spec set_port_config(integer(), ofp_port_no(),
                      #port_configuration{} | undefined) -> ok.
set_port_config(_SwitchId, _PortNo, undefined) ->
    ok;
set_port_config(SwitchId, PortNo, Config) ->
    Config2 = linc_ofconfig:convert_port_config(Config),
    linc_us3_port:set_config(SwitchId, PortNo, Config2).

-spec set_queue_min_rate(integer(), ofp_port_no(),
                         ofp_queue_id(), integer() | undefined) -> ok.
set_queue_min_rate(_SwitchId, _PortNo, _QueueId, undefined) ->
    ok;
set_queue_min_rate(SwitchId, PortNo, QueueId, MinRate) ->
    linc_us3_queue:set_min_rate(SwitchId, PortNo, QueueId, MinRate).

-spec set_queue_max_rate(integer(), ofp_port_no(),
                         ofp_queue_id(), integer() | undefined) -> ok.
set_queue_max_rate(_SwitchId, _PortNo, _QueueId, undefined) ->
    ok;
set_queue_max_rate(SwitchId, PortNo, QueueId, MaxRate) ->
    linc_us3_queue:set_max_rate(SwitchId, PortNo, QueueId, MaxRate).

-spec get_ports(integer()) -> list(#port{}).
get_ports(SwitchId) ->
    PortsStates = linc_us3_port:get_all_ports_state(SwitchId),
    lists:map(fun({ResourceId, #ofp_port{port_no = PortNo,
                                         name = Name,
                                         config = Config,
                                         state = State,
                                         curr = Current,
                                         advertised = Advertised,
                                         supported = Supported,
                                         peer = Peer,
                                         curr_speed = CurrSpeed,
                                         max_speed = MaxSpeed}}) ->
                      Configuration = linc_ofconfig:convert_port_config(Config),
                      Features = linc_ofconfig:convert_port_features({Current,
                                                                      Advertised,
                                                                      Supported,
                                                                      Peer}),
                      PortState = linc_ofconfig:convert_port_state(State),
                      #port{resource_id = ResourceId,
                            number = PortNo,
                            name = Name,
                            current_rate = CurrSpeed,
                            max_rate = MaxSpeed,
                            configuration = Configuration,
                            state = PortState,
                            features = Features,
                            tunnel = undefined}
              end, PortsStates).

-spec get_flow_tables(integer(), string()) -> list(#flow_table{}).
get_flow_tables(SwitchId, DatapathId) ->
    [#flow_table{resource_id = linc_ofconfig:flow_table_name(SwitchId,
                                                             DatapathId,
                                                             TableId),
                 max_entries = ?MAX_FLOW_TABLE_ENTRIES,
                 next_tables = lists:seq(TableId + 1, ?OFPTT_MAX),
                 instructions = instructions(?SUPPORTED_INSTRUCTIONS),
                 matches = fields(?SUPPORTED_MATCH_FIELDS),
                 write_actions = actions(?SUPPORTED_WRITE_ACTIONS),
                 apply_actions = actions(?SUPPORTED_APPLY_ACTIONS),
                 write_setfields = fields(?SUPPORTED_WRITE_SETFIELDS),
                 apply_setfields = fields(?SUPPORTED_APPLY_SETFIELDS),
                 wildcards = fields(?SUPPORTED_WILDCARDS),
                 metadata_match = ?SUPPORTED_METADATA_MATCH,
                 metadata_write = ?SUPPORTED_METADATA_WRITE}
     || TableId <- lists:seq(0, ?OFPTT_MAX)].

-spec get_capabilities() -> #capabilities{}.
get_capabilities() ->
    #capabilities{max_buffered_packets = ?MAX_BUFFERED_PACKETS,
                  max_tables = ?MAX_TABLES,
                  max_ports = ?MAX_PORTS,
                  flow_statistics = true,
                  table_statistics = true,
                  port_statistics = true,
                  group_statistics = true,
                  queue_statistics = true,
                  reassemble_ip_fragments = false,
                  block_looping_ports = false,
                  reserved_port_types = ?SUPPORTED_RESERVED_PORTS,
                  group_types =
                      group_types(?SUPPORTED_GROUP_TYPES),
                  group_capabilities =
                      group_caps(?SUPPORTED_GROUP_CAPABILITIES),
                  action_types = actions(?SUPPORTED_WRITE_ACTIONS),
                  instruction_types =
                      instructions(?SUPPORTED_INSTRUCTIONS)}.

-spec get_port_config(integer(), ofp_port_no()) -> #port_configuration{}.
get_port_config(SwitchId, PortNo) ->
    Config = linc_us3_port:get_config(SwitchId, PortNo),
    linc_ofconfig:convert_port_config(Config).

-spec get_port_features(integer(), ofp_port_no()) -> #features{}.
get_port_features(SwitchId, PortNo) ->
    {Current, Advertised,
     Supported, Peer} = linc_us3_port:get_features(SwitchId, PortNo),
    linc_ofconfig:convert_port_features({Current, Advertised, Supported, Peer}).

-spec get_queues(integer()) -> list(#queue{}).
get_queues(SwitchId) ->
    lists:map(fun({ResourceId, QueueId, PortNo, MinRate, MaxRate}) ->
                      #queue{resource_id = ResourceId,
                             id = QueueId,
                             port = PortNo,
                             properties = #queue_properties{
                                             min_rate = MinRate,
                                             max_rate = MaxRate,
                                             experimenters = []
                                            }}
              end, linc_us3_port:get_all_queues_state(SwitchId)).

%%------------------------------------------------------------------------------
%% Helper conversion functions
%%------------------------------------------------------------------------------

instructions(Instructions) ->
    instructions(Instructions, []).

instructions([], Instructions) ->
    lists:reverse(Instructions);
instructions([apply_actions | Rest], Instructions) ->
    instructions(Rest, ['apply-actions' | Instructions]);
instructions([clear_actions | Rest], Instructions) ->
    instructions(Rest, ['clear-actions' | Instructions]);
instructions([write_actions | Rest], Instructions) ->
    instructions(Rest, ['write-actions' | Instructions]);
instructions([write_metadata | Rest], Instructions) ->
    instructions(Rest, ['write-metadata' | Instructions]);
instructions([goto_table | Rest], Instructions) ->
    instructions(Rest, ['goto-table' | Instructions]).

fields(Fields) ->
    fields(Fields, []).

fields([], Fields) ->
    lists:reverse(Fields);
fields([in_port | Rest], Fields) ->
    fields(Rest, ['input-port' | Fields]);
fields([in_phy_port | Rest], Fields) ->
    fields(Rest, ['physical-input-port' | Fields]);
fields([metadata | Rest], Fields) ->
    fields(Rest, ['metadata' | Fields]);
fields([eth_dst | Rest], Fields) ->
    fields(Rest, ['ethernet-dest' | Fields]);
fields([eth_src | Rest], Fields) ->
    fields(Rest, ['ethernet-src' | Fields]);
fields([eth_type | Rest], Fields) ->
    fields(Rest, ['ethernet-frame-type' | Fields]);
fields([vlan_vid | Rest], Fields) ->
    fields(Rest, ['vlan-id' | Fields]);
fields([vlan_pcp | Rest], Fields) ->
    fields(Rest, ['vlan-priority' | Fields]);
fields([ip_dscp | Rest], Fields) ->
    fields(Rest, ['ip-dscp' | Fields]);
fields([ip_ecn | Rest], Fields) ->
    fields(Rest, ['ip-ecn' | Fields]);
fields([ip_proto | Rest], Fields) ->
    fields(Rest, ['ip-protocol' | Fields]);
fields([ipv4_src | Rest], Fields) ->
    fields(Rest, ['ipv4-src' | Fields]);
fields([ipv4_dst | Rest], Fields) ->
    fields(Rest, ['ipv4-dest' | Fields]);
fields([tcp_src | Rest], Fields) ->
    fields(Rest, ['tcp-src' | Fields]);
fields([tcp_dst | Rest], Fields) ->
    fields(Rest, ['tcp-dest' | Fields]);
fields([udp_src | Rest], Fields) ->
    fields(Rest, ['udp-src' | Fields]);
fields([udp_dst | Rest], Fields) ->
    fields(Rest, ['udp-dest' | Fields]);
fields([sctp_src | Rest], Fields) ->
    fields(Rest, ['sctp-src' | Fields]);
fields([sctp_dst | Rest], Fields) ->
    fields(Rest, ['sctp-dest' | Fields]);
fields([icmpv4_type | Rest], Fields) ->
    fields(Rest, ['icmpv4-type' | Fields]);
fields([icmpv4_code | Rest], Fields) ->
    fields(Rest, ['icmpv4-code' | Fields]);
fields([arp_op | Rest], Fields) ->
    fields(Rest, ['arp-op' | Fields]);
fields([arp_spa | Rest], Fields) ->
    fields(Rest, ['arp-src-ip-address' | Fields]);
fields([arp_tpa | Rest], Fields) ->
    fields(Rest, ['arp-target-ip-address' | Fields]);
fields([arp_sha | Rest], Fields) ->
    fields(Rest, ['arp-src-hardware-address' | Fields]);
fields([arp_tha | Rest], Fields) ->
    fields(Rest, ['arp-target-hardware-address' | Fields]);
fields([ipv6_src | Rest], Fields) ->
    fields(Rest, ['ipv6-src' | Fields]);
fields([ipv6_dst | Rest], Fields) ->
    fields(Rest, ['ipv6-dest' | Fields]);
fields([ipv6_flabel | Rest], Fields) ->
    fields(Rest, ['ipv6-flow-label' | Fields]);
fields([icmpv6_type | Rest], Fields) ->
    fields(Rest, ['icmpv6-type' | Fields]);
fields([icmpv6_code | Rest], Fields) ->
    fields(Rest, ['icmpv6-code' | Fields]);
fields([ipv6_nd_target | Rest], Fields) ->
    fields(Rest, ['ipv6-nd-target' | Fields]);
fields([ipv6_nd_sll | Rest], Fields) ->
    fields(Rest, ['ipv6-nd-source-link-layer' | Fields]);
fields([ipv6_nd_tll | Rest], Fields) ->
    fields(Rest, ['ipv6-nd-target-link-layer' | Fields]);
fields([mpls_label | Rest], Fields) ->
    fields(Rest, ['mpls-label' | Fields]);
fields([mpls_tc | Rest], Fields) ->
    fields(Rest, ['mpls-tc' | Fields]).

actions(Actions) ->
    actions(Actions, []).

actions([], Actions) ->
    lists:reverse(Actions);
actions([output | Rest], Actions) ->
    actions(Rest, [output | Actions]);
actions([copy_ttl_out | Rest], Actions) ->
    actions(Rest, ['copy-ttl-out' | Actions]);
actions([copy_ttl_in | Rest], Actions) ->
    actions(Rest, ['copy-ttl-in' | Actions]);
actions([set_mpls_ttl | Rest], Actions) ->
    actions(Rest, ['set-mpls-ttl' | Actions]);
actions([dec_mpls_ttl | Rest], Actions) ->
    actions(Rest, ['dec-mpls-ttl' | Actions]);
actions([push_vlan | Rest], Actions) ->
    actions(Rest, ['push-vlan' | Actions]);
actions([pop_vlan | Rest], Actions) ->
    actions(Rest, ['pop-vlan' | Actions]);
actions([push_mpls | Rest], Actions) ->
    actions(Rest, ['push-mpls' | Actions]);
actions([pop_mpls | Rest], Actions) ->
    actions(Rest, ['pop-mpls' | Actions]);
actions([push_pbb | Rest], Actions) ->
    actions(Rest, ['push-pbb' | Actions]);
actions([pop_pbb | Rest], Actions) ->
    actions(Rest, ['pop-pbb' | Actions]);
actions([set_queue | Rest], Actions) ->
    actions(Rest, ['set-queue' | Actions]);
actions([group | Rest], Actions) ->
    actions(Rest, [group | Actions]);
actions([set_nw_ttl | Rest], Actions) ->
    actions(Rest, ['set-nw-ttl' | Actions]);
actions([dec_nw_ttl | Rest], Actions) ->
    actions(Rest, ['dec-nw-ttl' | Actions]);
actions([set_field | Rest], Actions) ->
    actions(Rest, ['set-field' | Actions]).

group_types(Types) ->
    group_types(Types, []).

group_types([], Types) ->
    lists:reverse(Types);
group_types([all | Rest], Types) ->
    group_types(Rest, [all | Types]);
group_types([select | Rest], Types) ->
    group_types(Rest, [select | Types]);
group_types([indirect | Rest], Types) ->
    group_types(Rest, [indirect | Types]);
group_types([ff | Rest], Types) ->
    group_types(Rest, ['fast-failover' | Types]).

group_caps(Capabilities) ->
    group_caps(Capabilities, []).

group_caps([], Capabilities) ->
    lists:reverse(Capabilities);
group_caps([select_weight | Rest], Capabilities) ->
    group_caps(Rest, ['select-weight' | Capabilities]);
group_caps([select_liveness | Rest], Capabilities) ->
    group_caps(Rest, ['select-liveness' | Capabilities]);
group_caps([chaining | Rest], Capabilities) ->
    group_caps(Rest, [chaining | Capabilities]);
group_caps([chaining_check | Rest], Capabilities) ->
    group_caps(Rest, ['chaining-check' | Capabilities]).
