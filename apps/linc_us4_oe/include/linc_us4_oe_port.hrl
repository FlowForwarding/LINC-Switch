-define(PORT_SPEED, 5000). %% Port speed in kbps = 5Mbps
-define(FEATURES, ['100mb_fd', copper, autoneg]).

%% Macros used by linc_us4_port_load_regulation
-define(ACCEPTABLE_DELAY_IN_MILSECS, 100).
-define(ACCEPTABLE_DELAY_IN_MILSECS_BEFORE_RECOVERY, 50).
-define(PERIODIC_CHECK_INTERVAL_IN_MILISECS, 250).

-define(PKTS_RATIO_BETWEEN_RX_AND_SUM_WITHOUT_PROTECTION, 0.6).
-define(PKTS_RATIO_BETWEEN_RX_AND_SUM_WITH_DROP_TX, 0.9).

-define(PKTS_RATIO_BETWEEN_TX_AND_SUM_WITHOUT_PROTECTION, 0.6).
-define(PKTS_RATIO_BETWEEN_TX_AND_SUM_WITH_DROP_RX, 0.9).

-record(linc_port, {
          port_no :: ofp_port_no(),
          pid     :: pid(),
          drop_tx = false :: boolean()
         }).

%% LINC swich port configuration stored in sys.config
-type linc_port_config() :: tuple(interface, string())
                          | tuple(ip, string())
                          | tuple(config, tuple())
                          | tuple(features, tuple())
                          | tuple(queues, tuple()).

-type linc_port_type() :: physical | logical | reserved.
-type linc_queues_state() :: enabled | disabled.
-type linc_overload_protection() :: none | drop_rx | drop_tx | drop_all.

-record(state, {
          resource_id        :: string(),
          sync_routing = true :: boolean(),
          %% Common state of tap and eth interfaces
          interface          :: string(),
          type = physical    :: linc_port_type(),
          switch_id = 0      :: integer(),
          port = #ofp_port{} :: ofp_port(),
          operstate_changes_ref :: reference(),
          %% State of tap interface
          erlang_port        :: port(),
          port_ref           :: pid(),
          %% State of eth interface
          socket             :: integer(),
          ifindex            :: integer(),
          epcap_pid          :: pid(),
          %% State of simulated optical interface
          optical_port_pid   :: pid(),
          %% Queue subsystem state
          queues = disabled  :: linc_queues_state(),
          %% Overload protection state
          periodic_load_checker_ref  :: timer:tref(),
          overload_protection = none :: linc_overload_protection()
         }).
-type state() :: #state{}.

-record(load_control_message, {
          timestamp :: os:timestamp(),
          rx_packets :: integer(),
          tx_packets :: integer()
         }).
-type load_control_message() :: #load_control_message{}.
