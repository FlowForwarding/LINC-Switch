%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2012, Erlang Solutions Ltd.
%%% @doc Header file for userspace implementation of OpenFlow switch.
%%% @end
%%%-----------------------------------------------------------------------------

-record(flow_entry, {
          priority :: integer(),
          match :: of_protocol:match(),
          instructions = [] :: ordsets:ordered_set(of_protocol:instruction())
         }).

-record(flow_entry_counter, {
          key :: {FlowTableId :: integer(), #flow_entry{}},
          received_packets = 0 :: integer(),
          received_bytes = 0 :: integer(),
          install_time :: tuple(calendar:date(), calendar:time())
         }).

-record(flow_table, {
          id :: integer(),
          entries = [] :: [#flow_entry{}],
          config = drop :: of_protocol:table_config()
         }).

-record(flow_table_counter, {
          id :: integer(),
          %% Reference count is dynamically generated for the sake of simplicity
          %% reference_count = 0 :: integer(),
          packet_lookups = 0 :: integer(),
          packet_matches = 0 :: integer()
         }).

-record(ofs_pkt, {
          fields :: of_protocol:match(),
          actions = [] :: ordsets:ordset(ofp_structures:action()),
          metadata = << 0:64/integer >> :: binary(),
          size = 0 :: integer(),
          in_port :: integer(),
          packet :: pkt:packet()
         }).

-type ofs_port_type() :: physical | logical | reserved.

-record(ofs_port, {
          number :: integer(),
          type :: ofs_port_type(),
          handle :: term()
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
