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

-record(flow_table, {
          id :: integer(),
          entries :: [#flow_entry{}],
          config :: drop | controller | continue
         }).

-record(ofs_pkt, {
          fields       :: of_protocol:match(),
          actions = [] :: ordsets:ordset(ofp_structures:action()),
          metadata     :: binary()
         }).
