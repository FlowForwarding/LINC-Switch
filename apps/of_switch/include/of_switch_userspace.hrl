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
          config = drop :: drop | controller | continue
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
          size = 0 :: integer()
         }).

-type ofs_port_type() :: physical | logical | reserved.

-record(ofs_port, {
          number :: integer(),
          type :: ofs_port_type(),
          handle :: term(),
          %% --- Counters ---
          received_packets :: integer(),
          transmitted_packets :: integer(),
          received_bytes :: integer(),
          transmitted_bytes :: integer(),
          receive_drops :: integer(),
          transmit_drops :: integer(),
          receive_errors :: integer(),
          transmit_errors :: integer(),
          receive_frame_alignment_errors :: integer(),
          receive_overrun_errors :: integer(),
          receive_crc_errors :: integer(),
          collisions :: integer()
         }).
