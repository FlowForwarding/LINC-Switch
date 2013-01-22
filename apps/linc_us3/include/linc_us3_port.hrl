-define(PORT_SPEED, 5000). %% Port speed in kbps = 5Mbps

-record(linc_port, {
          port_no :: ofp_port_no(),
          pid     :: pid()
         }).

%% LINC swich port configuration stored in sys.config
-type linc_port_config() :: tuple(interface, string()) |
                            tuple(ip, string()).

-type linc_port_type() :: physical | logical | reserved.
-type linc_queues_state() :: enabled | disabled.

-record(state, {
          resource_id        :: string(),
          %% Common state of tap and eth interfaces
          interface          :: string(),
          type = physical    :: linc_port_type(),
          switch_id = 0      :: integer(),
          port = #ofp_port{} :: ofp_port(),
          %% State of tap interface
          erlang_port        :: port(),
          port_ref           :: pid(),
          %% State of eth interface
          socket             :: integer(),
          ifindex            :: integer(),
          epcap_pid          :: pid(),
          %% Queue subsystem state
          queues = disabled  :: linc_queues_state()
         }).
