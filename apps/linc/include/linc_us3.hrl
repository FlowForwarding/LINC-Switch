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
%% @doc Header file for userspace implementation of OpenFlow switch.

-include_lib("of_protocol/include/of_protocol.hrl").
-include_lib("of_protocol/include/ofp_v3.hrl").
-include("linc.hrl").

-define(SUPPORTED_ACTIONS, [output,
                            group,
                            set_queue,
                            set_mpls_ttl,
                            dec_mpls_ttl,
                            set_nw_ttl,
                            dec_nw_ttl,
                            copy_ttl_out,
                            copy_ttl_in,
                            push_vlan,
                            pop_vlan,
                            push_mpls,
                            pop_mpls,
                            %% push_pbb,
                            %% pop_pbb,
                            set_field
                           ]).
-define(SUPPORTED_WRITE_ACTIONS, ?SUPPORTED_ACTIONS).
-define(SUPPORTED_APPLY_ACTIONS, ?SUPPORTED_ACTIONS).
-define(SUPPORTED_MATCH_FIELDS, [in_port,
                                 %% in_phy_port,
                                 %% metadata,
                                 eth_dst,
                                 eth_src,
                                 eth_type,
                                 vlan_vid,
                                 vlan_pcp,
                                 ip_dscp,
                                 ip_ecn,
                                 ip_proto,
                                 ipv4_src,
                                 ipv4_dst,
                                 tcp_src,
                                 tcp_dst,
                                 udp_src,
                                 udp_dst,
                                 sctp_src,
                                 sctp_dst,
                                 icmpv4_type,
                                 icmpv4_code,
                                 arp_op,
                                 arp_spa,
                                 arp_tpa,
                                 arp_sha,
                                 arp_tha,
                                 ipv6_src,
                                 ipv6_dst,
                                 ipv6_flabel,
                                 icmpv6_type,
                                 icmpv6_code,
                                 ipv6_nd_target,
                                 ipv6_nd_sll,
                                 ipv6_nd_tll,
                                 mpls_label,
                                 mpls_tc]).
-define(SUPPORTED_WILDCARDS, ?SUPPORTED_MATCH_FIELDS).
-define(SUPPORTED_WRITE_SETFIELDS, []).
-define(SUPPORTED_APPLY_SETFIELDS, ?SUPPORTED_WRITE_SETFIELDS).
-define(SUPPORTED_INSTRUCTIONS, [goto_table,
                                 %% write_metadata,
                                 write_actions,
                                 apply_actions,
                                 clear_actions]).
-define(SUPPORTED_GROUP_TYPES, [all
                                %% select,
                                %% indirect,
                                %% ff
                               ]).
-define(SUPPORTED_GROUP_CAPABILITIES, [%% select_weight,
                                       %% select_liveness,
                                       %% chaining,
                                       %% chaining-check
                                      ]).
-define(SUPPORTED_RESERVED_PORTS, [all,
                                   controller,
                                   table,
                                   inport,
                                   any
                                   %% normal
                                   %% flood
                                  ]).

-define(MAX, (1 bsl 24)). %% some arbitrary big number
-define(MAX_FLOW_TABLE_ENTRIES, ?MAX).
-define(MAX_TABLES, 255).
-define(MAX_PORTS, ?MAX).
-define(MAX_GROUP_ENTRIES, {?MAX, 0, 0, 0}).
-define(MAX_BUFFERED_PACKETS, 0).

-type priority() :: non_neg_integer().
-type flow_id() :: {priority(),reference()}.

-record(flow_table_config, {
          id                 :: non_neg_integer(),
          config = controller:: ofp_table_config()
         }).

-record(flow_entry, {
          id                       :: flow_id(),
          priority                 :: priority(),
          match                    :: ofp_match(),
          cookie                   :: binary(),
          install_time             :: erlang:timestamp(),
          expires = {infinity,0,0} :: erlang:timestamp(),
          idle = {infinity,0,0}    :: erlang:timestamp(),
          instructions = []        :: ordsets:ordset(ofp_instruction())
         }).

-record(flow_entry_counter, {
          id                   :: {FlowTableId :: integer(), #flow_entry{}},
          received_packets = 0 :: integer(),
          received_bytes   = 0 :: integer()
         }).

-record(linc_flow_table, {
          id                   :: integer(),
          entries = []         :: [#flow_entry{}],
          config  = controller :: ofp_table_config()
         }).

-record(flow_table_counter, {
          id :: integer(),
          %% Reference count is dynamically generated for the sake of simplicity
          %% reference_count = 0 :: integer(),
          packet_lookups = 0 :: integer(),
          packet_matches = 0 :: integer()
         }).

-record(ofs_pkt, {
          in_port             :: ofp_port_no(),
          fields              :: ofp_match(),
          actions = []        :: ordsets:ordset(ofp_action()),
          metadata = <<0:64>> :: binary(),
          packet              :: pkt:packet(),
          size                :: integer(),
          queue_id = default  :: integer() | default
         }).
-type ofs_pkt() :: #ofs_pkt{}.

-type ofs_port_type() :: physical | logical | reserved.

-record(ofs_port, {
          number             :: ofp_port_no(),
          type               :: ofs_port_type(),
          pid                :: pid(),
          iface              :: string(),
          port = #ofp_port{} :: ofp_port()
         }).

%% OF port configuration stored in sys.config
-type ofs_port_config() :: tuple(interface, string()) |
                           tuple(ofs_port_no, integer()) |
                           tuple(ip, string()).

%% We use '_' as a part of the type to avoid dialyzer warnings when using
%% match specs in ets:match_object in linc_us3_port:get_queue_stats/1
%% For detailed explanation behind this please read:
%% http://erlang.org/pipermail/erlang-questions/2009-September/046532.html
-record(ofs_port_queue, {
          key            :: {ofp_port_no(), ofp_queue_id()} | {'_', '_'} | '_',
          queue_pid      :: pid()                  | '_',
          properties     :: [ofp_queue_property()] | '_',
          tx_bytes   = 0 :: integer()              | '_',
          tx_packets = 0 :: integer()              | '_',
          tx_errors  = 0 :: integer()              | '_'
         }).

-record(ofs_queue_throttling, {
          queue_no               :: integer(),
          min_rate = 0           :: integer() | no_qos, % rates in b/window
          max_rate = no_max_rate :: integer() | no_max_rate,
          rate = 0               :: integer()
         }).

%% This is removed from linc_us3 as internal to linc_us3_groups module
%% -record(ofs_bucket, {
%%           value   :: ofp_bucket(),
%%           counter :: ofp_bucket_counter()
%%          }).

-type match() :: tuple(match, output | group | drop, #ofs_pkt{}) |
                 tuple(match, goto, integer(), #ofs_pkt{}).

-type miss() :: tuple(table_miss, drop | controller) |
                tuple(table_miss, continue, integer()).
