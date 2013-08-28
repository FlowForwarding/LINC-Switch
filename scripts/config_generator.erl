-module(config_generator).

-export([generate/2]).

-spec generate(PortsCnt :: non_neg_integer(),
      LogicalSwitchesCnt :: non_neg_integer()) ->
                      Result :: term().
generate(PortsCnt, LogicalSwitchesCnt) ->
    [
     {linc,
      [
       {of_config, enabled},
       {capable_switch_ports, generate_ports(PortsCnt * LogicalSwitchesCnt)},
       {capable_switch_queues, []},
       {logical_switches,
        generate_logical_switches(PortsCnt, LogicalSwitchesCnt)}
      ]},
     {enetconf,
      [
       {capabilities, [{base, {1, 1}},
                       {startup, {1, 0}},
                       {'writable-running', {1, 0}}]},
       {callback_module, linc_ofconfig},
       {sshd_ip, any},
       {sshd_port, 1830},
       {sshd_user_passwords,
        [
         {"linc", "linc"}
        ]}
      ]},
     {lager,
      [
       {handlers,
        [
         {lager_console_backend, info},
         {lager_file_backend,
          [
           {"log/error.log", error, 10485760, "$D0", 5},
           {"log/console.log", info, 10485760, "$D0", 5}
          ]}
        ]}
      ]},
     {sasl,
      [
       {sasl_error_logger, {file, "log/sasl-error.log"}},
       {errlog_type, error},
       {error_logger_mf_dir, "log/sasl"},      % Log directory
       {error_logger_mf_maxbytes, 10485760},   % 10 MB max file size
       {error_logger_mf_maxfiles, 5}           % 5 files max
      ]},
     {sync,
      [
       {excluded_modules, [procket]}
      ]}
    ].

generate_ports(PortsCnt) ->
    [{port, N, [{interface, "tap" ++ integer_to_list(N)}]}
     || N <- lists:seq(1, PortsCnt)].

generate_logical_switches(_, 0) ->
    [];
generate_logical_switches(PortsCnt, LogicalSwitchesCnt) ->
    [
     {switch, N,
      [
       {backend, linc_us4},
       {controllers,[]},
       {queues_status, disabled},
       {ports, generate_logical_switch_ports(PortsCnt, (N - 1) * PortsCnt + 1)}
      ]}
     || N <- lists:seq(1, LogicalSwitchesCnt)].

generate_logical_switch_ports(PortsCnt, StartPortNo) ->
    [{port, N, {queues, []}} || N <- lists:seq(StartPortNo,
                                               StartPortNo + PortsCnt - 1)].
