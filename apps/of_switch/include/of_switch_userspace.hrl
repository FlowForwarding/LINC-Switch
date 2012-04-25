%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2012, Erlang Solutions Ltd.
%%% @doc Header file for userspace implementation of OpenFlow switch.
%%% @end
%%%-----------------------------------------------------------------------------

-include_lib("of_protocol/include/of_protocol.hrl").

-record(flow_entry, {
          priority :: integer(),
          match :: ofp_match(),
          cookie :: binary(),
          install_time :: tuple(calendar:date(), calendar:time()),
          instructions = [] :: ordsets:ordset(ofp_instruction())
         }).

-record(flow_entry_counter, {
          key :: {FlowTableId :: integer(), #flow_entry{}},
          received_packets = 0 :: integer(),
          received_bytes = 0 :: integer()
         }).

-record(flow_table, {
          id :: integer(),
          entries = [] :: [#flow_entry{}],
          config = drop :: ofp_table_config()
         }).

-record(flow_table_counter, {
          id :: integer(),
          %% Reference count is dynamically generated for the sake of simplicity
          %% reference_count = 0 :: integer(),
          packet_lookups = 0 :: integer(),
          packet_matches = 0 :: integer()
         }).

-record(ofs_pkt, {
          fields :: ofp_match(),
          actions = [] :: ordsets:ordset(ofp_action()),
          metadata = << 0:64/integer >> :: binary(),
          size = 0 :: integer(),
          in_port :: integer(),
          packet :: pkt:packet()
         }).

-type ofs_port_type() :: physical | logical | reserved.

-record(ofs_port, {
          number :: integer(),
          type :: ofs_port_type(),
          handle :: term(),
          config  = [] :: [atom()]
         }).

-record(ofs_port_counter, {
          number :: integer(),
          received_packets = 0 :: integer(),
          transmitted_packets = 0 :: integer(),
          received_bytes = 0 :: integer(),
          transmitted_bytes = 0 :: integer(),
          receive_drops = 0 :: integer(),
          transmit_drops = 0 :: integer(),
          receive_errors = 0 :: integer(),
          transmit_errors = 0 :: integer(),
          receive_frame_alignment_errors = 0 :: integer(),
          receive_overrun_errors = 0 :: integer(),
          receive_crc_errors = 0 :: integer(),
          collisions = 0 :: integer()
         }).

-record(ofs_bucket, {
          value :: ofp_bucket(),
          counter :: ofp_bucket_counter()
         }).

-record(group_entry, {
          id :: ofp_group_id(),
          type = all :: ofp_group_type(),
          buckets = [] :: [#ofs_bucket{}]
         }).

-record(group_entry_counters, {
          id :: ofp_group_id(),
          ref_count :: integer(),
          packet_count :: integer(),
          byte_count :: integer()
         }).
