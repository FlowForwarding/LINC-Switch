-define(PORT_SPEED, 5000). %% Port speed in kbps = 5Mbps

-record(linc_port, {
          port_no :: ofp_port_no(),
          pid     :: pid()
         }).

%% LINC swich port configuration stored in sys.config
-type linc_port_config() :: tuple(interface, string()) |
                            tuple(ip, string()).

%% We use '_' as a part of the type to avoid dialyzer warnings when using
%% match specs in ets:match_object in linc_us3_port:get_queue_stats/1
%% For detailed explanation behind this please read:
%% http://erlang.org/pipermail/erlang-questions/2009-September/046532.html
-record(linc_port_queue, {
          key            :: {ofp_port_no(), ofp_queue_id()} | {'_', '_'} | '_',
          queue_pid      :: pid()                  | '_',
          properties     :: [ofp_queue_property()] | '_',
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

-type linc_port_type() :: physical | logical | reserved.

-record(state, {
          %% Common state of tap and eth interfaces
          interface          :: string(),
          type               :: linc_port_type(),
          port = #ofp_port{} :: ofp_port(),
          %% State of tap interface
          erlang_port        :: port(),
          port_ref           :: pid(),
          %% State of eth interface
          socket             :: integer(),
          ifindex            :: integer(),
          epcap_pid          :: pid(),
          %% Queue subsystem state
          rate_bps           :: integer(),
          throttling_ets     :: ets:tid()
         }).
