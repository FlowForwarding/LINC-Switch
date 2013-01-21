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
%% @doc OF-Config module for userspace v4 backend.
-module(linc_us4_ofconfig).

-export([get/1]).

-include_lib("of_config/include/of_config.hrl").
-include_lib("of_protocol/include/of_protocol.hrl").
-include_lib("of_protocol/include/ofp_v4.hrl").
-include("linc_us4.hrl").

-spec get(integer()) -> tuple(list(resource()), #logical_switch{}).
get(SwitchId) ->
    LogicalSwitchId = "LogicalSwitch" ++ integer_to_list(SwitchId),
    Ports = get_ports(SwitchId),
    Queues = get_queues(SwitchId),
    Certificates = get_certificates(SwitchId),
    FlowTables = get_flow_tables(SwitchId),
    Resources = Ports ++ Queues ++ Certificates ++ FlowTables,
    Refs = get_ports_refs(Ports)
        ++ get_queues_refs(Queues)
        ++ get_certificates_refs(Certificates)
        ++ get_flow_tables_refs(FlowTables),
    LogicalSwitch = #logical_switch{
                       id = LogicalSwitchId,
                       datapath_id = linc_logic:get_datapath_id(SwitchId),
                       enabled = true,
                       check_controller_certificate = false,
                       lost_connection_behavior = failSecureMode,
                       capabilities = get_capabilities(),
                       controllers = get_controllers(SwitchId),
                       resources = Refs
                      },
    {Resources, LogicalSwitch}.

get_ports(SwitchId) ->
    PortsStates = linc_us4_port:get_all_ports_state(SwitchId),
    lists:map(fun({ResourceId, #ofp_port{port_no = PortNo,
                                         name = Name,
                                         config = Config,
                                         state = State,
                                         curr = Curr,
                                         advertised = Advertised,
                                         supported = Supported,
                                         peer = Peer,
                                         curr_speed = CurrSpeed,
                                         max_speed = MaxSpeed}}) ->
                      AdminState = is_present(port_down, Config, up, down),
                      NoReceive = is_present(no_recv, Config, true, false),
                      NoForward = is_present(no_fwd, Config, true, false),
                      NoPacketIn = is_present(no_packet_in, Config, true, false),
                      Configuration = #port_configuration{
                                         admin_state = AdminState,
                                         no_receive = NoReceive,
                                         no_forward = NoForward,
                                         no_packet_in = NoPacketIn
                                        },
                      OperState = is_present(link_down, State, down, up),
                      Blocked = is_present(blocked, State, true, false),
                      Live = is_present(live, State, true, false),
                      PortState = #port_state{
                                     oper_state = OperState,
                                     blocked = Blocked,
                                     live = Live
                                    },
                      PortFeatures = #port_features{
                                        current = features(Curr),
                                        advertised = features(Advertised),
                                        supported = features(Supported),
                                        advertised_peer = features(Peer)
                                       },
                      #port{resource_id = ResourceId,
                            number = PortNo,
                            name = Name,
                            current_rate = CurrSpeed,
                            max_rate = MaxSpeed,
                            configuration = Configuration,
                            state = PortState,
                            features = PortFeatures,
                            tunnel = undefined}
              end, PortsStates).

get_ports_refs(Ports) ->
    lists:map(fun(#port{resource_id = ResourceId}) ->
                      {port, ResourceId}
              end, Ports).

get_queues(SwitchId) ->
    linc_us4_port:get_all_queues_state(SwitchId).

get_queues_refs(Queues) ->
    lists:map(fun(#queue{resource_id = ResourceId}) ->
                      {queue, ResourceId}
              end, Queues).

get_certificates(_SwitchId) ->
    %% TODO: Get certificate configuration.
    %% PrivateKey = #private_key_rsa{
    %%   modulus = "AEF134F56EDB667DFA4320AEF134F56EDB667DFA4320",
    %%   exponent = "DFA4320AEF134F56EDB6SSS"},
    %% #certificate{resource_id = "ownedCertificate3",
    %%              type = owned,
    %%              certificate =
    %%                  "AEF134F56EDB667DFA4320AEF134F56EDB667DFA4320",
    %%              private_key = PrivateKey},
    %% #certificate{resource_id = "externalCertificate2",
    %%              type = external,
    %%              certificate =
    %%                  "AEF134F56EDB667DFA4320AEF134F56EDB667DFA4320",
    %%              private_key = undefined},
    [].

get_certificates_refs(Certificates) ->
    lists:map(fun(#certificate{resource_id = ResourceId}) ->
                      {certificate, ResourceId}
              end, Certificates).

get_flow_tables(SwitchId) ->
    [#flow_table{resource_id = flow_table_name(SwitchId, I),
                 max_entries = ?MAX_FLOW_TABLE_ENTRIES,
                 next_tables = lists:seq(I + 1, ?OFPTT_MAX),
                 instructions = instructions(?SUPPORTED_INSTRUCTIONS),
                 matches = fields(?SUPPORTED_MATCH_FIELDS),
                 write_actions = actions(?SUPPORTED_WRITE_ACTIONS),
                 apply_actions = actions(?SUPPORTED_APPLY_ACTIONS),
                 write_setfields = fields(?SUPPORTED_WRITE_SETFIELDS),
                 apply_setfields = fields(?SUPPORTED_APPLY_SETFIELDS),
                 wildcards = fields(?SUPPORTED_WILDCARDS),
                 metadata_match = 16#ffff,
                 metadata_write = 16#ffff}
     || I <- lists:seq(0, ?OFPTT_MAX)].

get_flow_tables_refs(FlowTables) ->
    lists:map(fun(#flow_table{resource_id = ResourceId}) ->
                      {flow_table, ResourceId}
              end, FlowTables).

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

get_controllers(SwitchId) ->
    lists:map(fun({ControllerId, Role,
                   {ControllerIP, ControllerPort},
                   {LocalIP, LocalPort},
                   Protocol, ConnectionState,
                   CurrentVersion, SupportedVersions}) ->
                      Id = "Switch"
                          ++ integer_to_list(SwitchId)
                          ++ "Controller"
                          ++ integer_to_list(ControllerId),
                      #controller{
                         id = Id,
                         role = Role,
                         ip_address = ip(ControllerIP),
                         port = ControllerPort,
                         local_ip_address = ip(LocalIP),
                         local_port = LocalPort,
                         protocol = Protocol,
                         state = #controller_state{
                                    connection_state = ConnectionState,
                                    current_version =
                                        version(CurrentVersion),
                                    supported_versions =
                                        [version(V) || V <- SupportedVersions]
                                   }
                        }
              end, ofp_client:get_controllers_state(SwitchId)).

%%------------------------------------------------------------------------------
%% Helper conversion functions
%%------------------------------------------------------------------------------

is_present(Value, List, IfPresent, IfAbsent) ->
    case lists:member(Value, List) of
        true ->
            IfPresent;
        false ->
            IfAbsent
    end.

rate(Features) ->
    Rates = lists:map(fun('10mb_hd') ->
                              '10mb-hd';
                         ('10mb_fd') ->
                              '10mb-fd';
                         ('100mb_hd') ->
                              '100mb-hd';
                         ('100mb_fd') ->
                              '100mb-fd';
                         ('1gb_hd') ->
                              '1gb-hd';
                         ('1gb_fd') ->
                              '1gb-fd';
                         ('10gb_fd') ->
                              '10gb-fd';
                         ('40gb_fd') ->
                              '40gb-fd';
                         ('100gb_fd') ->
                              '100gb-fd';
                         ('1tb_fd') ->
                              '1tb-fd';
                         (other) ->
                              other;
                         (_) ->
                              invalid
                      end, Features),
    lists:filter(fun(invalid) ->
                         true;
                    (_) ->
                         false
                 end, Rates),
    hd(Rates).

features(Features) ->
    Rate = rate(Features),
    AutoNegotiate = is_present(autoneg, Features, true, false),
    Medium = is_present(fiber, Features, fiber, copper),
    Pause = case lists:member(pause, Features) of
                true ->
                    symmetric;
                false ->
                    case lists:member(pause_asym, Features) of
                        true ->
                            asymmetric;
                        false ->
                            unsupported
                    end
            end,
    #features{rate = Rate,
              auto_negotiate = AutoNegotiate,
              medium = Medium,
              pause = Pause}.

instructions(Instructions) ->
    instructions(Instructions, []).

instructions([], Instructions) ->
    lists:reverse(Instructions);
instructions([meter | Rest], Instructions) ->
    instructions(Rest, ['meter' | Instructions]);
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
    fields(Rest, ['mpls-tc' | Fields]);
fields([mpls_bos | Rest], Fields) ->
    fields(Rest, ['mpls-bos' | Fields]);
fields([pbb_isid | Rest], Fields) ->
    fields(Rest, ['pbb-isid' | Fields]).

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
    group_caps(Rest, ['select_liveness' | Capabilities]);
group_caps([chaining | Rest], Capabilities) ->
    group_caps(Rest, [chaining | Capabilities]);
group_caps([chaining_check | Rest], Capabilities) ->
    group_caps(Rest, ['chaining-check' | Capabilities]).

-spec flow_table_name(integer(), integer()) -> string().
flow_table_name(SwitchId, TableId) ->
    DatapathId = linc_logic:get_datapath_id(SwitchId),
    DatapathId ++ "FlowTable" ++ integer_to_list(TableId).

ip({A, B, C, D}) ->
    integer_to_list(A) ++ "."
        ++ integer_to_list(B) ++ "."
        ++ integer_to_list(C) ++ "."
        ++ integer_to_list(D).

version(1) ->
    '1.0';
version(2) ->
    '1.1';
version(3) ->
    '1.2';
version(4) ->
    '1.3'.
