%%%===================================================================
%%% @copyright (C) 2012, Erlang Solutions Ltd.
%%% @doc Records used by userspace implementation of OpenFlow switch
%%% @end
%%%===================================================================

-record(flow_entry, {
          priority :: integer(),
          match :: of_protocol:match(),
          instructions :: ordsets:ordered_set(of_protocol:instruction())
         }).

-record(flow_entry_counter, {
          key :: {FlowTableId :: integer(), #flow_entry{}},
          received_packets = 0 :: integer(),
          received_bytes = 0 :: integer(),
          install_time :: tuple(calendar:date(), calendar:time())
         }).

-record(flow_table, {
          id :: integer(),
          entries :: [#flow_entry{}],
          config :: drop | controller | continue,
          %% Reference count is dynamically generated for the sake of simplicity
          %% reference_count = 0 :: integer(),
          packet_lookups = 0 :: integer(),
          packet_matches = 0 :: integer()
         }).

-record(ofs_pkt, {
          fields       :: of_protocol:match(),
          actions = [] :: ordsets:ordset(ofp_structures:action()),
          metadata     :: binary(),
          size = 0     :: integer()
         }).
