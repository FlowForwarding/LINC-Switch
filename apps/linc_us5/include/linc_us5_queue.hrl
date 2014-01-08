%% We use '_' as a part of the type to avoid dialyzer warnings when using
%% match specs in ets:match_object in linc_us3_port:get_queue_stats/1
%% For detailed explanation behind this please read:
%% http://erlang.org/pipermail/erlang-questions/2009-September/046532.html
-record(linc_port_queue, {
          key            :: {ofp_port_no(), ofp_queue_id()} | {'_', '_'} | '_',
          queue_pid      :: pid()                  | '_',
          properties     :: [{min_rate, non_neg_integer() | no_qos} |
                             {max_rate, non_neg_integer() | no_max_rate}] | '_',
          tx_bytes   = 0 :: integer()              | '_',
          tx_packets = 0 :: integer()              | '_',
          tx_errors  = 0 :: integer()              | '_',
          install_time   :: erlang:timestamp()     | '_'
         }).

-record(linc_queue_throttling, {
          queue_no               :: integer(),
          min_rate = 0           :: integer() | no_qos, % rates in b/window
          max_rate = no_max_rate :: integer() | no_max_rate,
          rate = 0               :: integer()
         }).
