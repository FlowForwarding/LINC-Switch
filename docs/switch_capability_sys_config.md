#Switch Capability with sys.config

##What is this sys.config file and where is it located?

Defines switch capability (4-port or 8-port or n-port). Switch configuration is editable and is located at $LINC_ROOT/rel/linc/files/sys.config.

When you are building release from LINC source, the sys.config file is copied over to $LINC_ROOT/rel/linc/releases/<VERSION>/ replacing whatever changes you made in that folder.

## Structure of sys.config file
```erlang
[
 {linc,
  [
   {of_config, enabled},
   {logical_switches,
    [
     {switch, 0,
      [
       {backend, linc_us4},
       {controllers, []},
       {ports, []},
       {queues_status, disabled},
       {queues, []}
      ]}
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
  ]}
].
```

### Erlang configuration syntax
Configuration file of LINC is a value of Erlang language, and has the syntax of Erlang term. Configuration file must always end with period. Terms used in LINC configuration can be tuples (containing any amount of terms wrapped with curly braces), lists (containing any amount of terms, wrapped in square braces), strings (characters wrapped in double quotes), numbers and atoms (named lowercase constants without a specific numeric value).

>String example: “localhost”.

>Number example: 1234, or 1.234 (floating point number).

>Atom example: this_is_atom.

>Tuple example: {ofs_port_no, 1} -- tuple contains pair of atom ‘ofs_port’ and number 1. 

>Tuples containing just 2 values can sometimes be called “pairs”.

>List example: [1, 2, 3] -- contains three numbers, or [{“localhost”, 1234}] -- contains one tuple, which contains a string and a number.

### OF-Config Section
This setting enables or disables OF-Config subsystem which consists of three applications: ssh, enetconf and of_config. Allowed values: 'enabled' or 'disabled'

```erlang
   {of_config, enabled},
```

### OF-Capable Switch Model
LINC is a OF-Capable Switch.  This means that each Switch can host multiple logical switches at the same time and each logical switch can have its own controller, ports and queues.
```erlang
   {logical_switches,
    [
     {switch, 0,
      [ …..
      ]},
     {switch, 1,
      [ …..
      ]},
     {switch, 2,
      [ …..
      ]}
     ]}
```

### OF-Logical Switch a.k.a OpenFlow Switch
The OF-Logical Switch consists of several switch capability configuration parameters.
```erlang
     {switch, 0,
      [
       {backend, linc_us4},
       {controllers, []},
       {ports, []},
       {queues_status, disabled},
       {queues, []}
      ]}
```
#### Switch Backend section
Configuration of switch backend implementation used by ofs_logic process. By default an Erlang userspace OpenFlow version 1.3.1 implementation is selected.  Allowed values: 'linc_us3' for OpenFlow v1.2 or 'linc_us4' for OpenFlow v1.3.1.
```erlang
       {backend, linc_us4},
```

#### Controllers section
This section contains list of controllers to be used when switching traffic. Each value is a tuple containing pair of string, which should resolve to an IPv4 address, and numeric port, where the controller is listening.

Ideally this list should be empty and assignment should be handled by an OF-Config client. Default OFP controller port is 6633.
```erlang
       {controllers,
        [
          {"Switch0-DefaultController", "localhost", 6633, tcp}
        ]},
```

#### Ports section
This section contains lists of ingress (incoming) and egress (outgoing) ports, which are used for receiving and sending traffic by the switch. There is no configuration option to distinguish input and output ports, they are all same. Each port definition is a property list, containing values for port number, interface name, queues definitions and port bandwidth (rate).

Configure ports available to the switch when using the userspace backend according to your system setup.  Under Linux all TAP interfaces must be set up beforehand as persistent.  Under MacOSX TAP interfaces are created during node startup (which requires setting an ip parameter).

"port" defines logical port number, as its seen in routing rules and log output. Key "interface" defines system-wide name of the network interface, which this port is
attached to.

*Note: A statement starting with "%%" in Erlang is a comment.*
```erlang
       {ports,
        [
         %% {port, 1, [{interface, "eth0"}]},
         %% {port, 2, [{interface, "tap0"}]},
         %% {port, 3, [{interface, "tap1"}, {ip, "10.0.0.1"}]}
        ]},
```

#### Queues Configuration Section
Queue configuration is not part of the OpenFlow specification and as such should be considered EXPERIMENTAL. This feature is disabled by default.  Allowed values: 'enabled' or 'disabled'
```erlang
       {queues_status, disabled},
```
If queues are enabled, assign them to ports and set appropriate rates. Queue configuration is not part of the OpenFlow specification and as such should be considered EXPERIMENTAL.
```erlang
       {queues,
        [
          {port, 1, [{port_rate, {100, kbps}},
                     {port_queues, [
                                    {1, [{min_rate, 100}, {max_rate, 100}]},
                                    {2, [{min_rate, 100}, {max_rate, 100}]}
                                   ]}]},
          {port, 2, [{port_rate, {100, kbps}},
                     {port_queues, [
                                    {1, [{min_rate, 100}, {max_rate, 100}]},
                                    {2, [{min_rate, 100}, {max_rate, 100}]}
                                   ]}]}
        ]}
      ]}
```

### TLS Configuration
This section configures the necessary certificates and keys required for setting up a TLS connection between the Logical Switch and Controller.  Here, the switch certificate and private RSA keys are stored. Values should be base64 encoded, DER encoded strings.

```erlang
     {certificate, ""},
     {rsa_private_key, ""}
```

### OF-Configuration Point via NetConf
Port parameters and authentication credentials necessary for communicating to the OF-Capable Switch via NetConf is configured in this section

```erlang
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
```

### Logging
Lagger is a logging framework for Erlang/OTP.  This provides users/developers friendly error messaging when bad things do happen.  This section is about configuring such logging.
*Note: If you more debug output on console, replace "info" with "debug" in the below section of the code*

```erlang
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
```

Sasl is another logging mechanism that is built into Erlang.
```erlang
 {sasl,
  [
   {sasl_error_logger, {file, "log/sasl-error.log"}},
   {errlog_type, error},
   {error_logger_mf_dir, "log/sasl"},      % Log directory
   {error_logger_mf_maxbytes, 10485760},   % 10 MB max file size
   {error_logger_mf_maxfiles, 5}           % 5 files max
  ]}
```
## Examples of sys.config in real switches
### 1 Logical Switch (or Standard OpenFlow Switch)
```erlang
[
 {linc,
  [
   {of_config, enabled},
   {logical_switches,
    [
     {switch, 0,
      [
       {backend, linc_us4},
       {controllers,
        [
          {"Switch0-DefaultController", "10.48.11.5", 6633, tcp}
        ]},
       {ports,
        [
         {port, 1, [{interface, "eth1"}]},
         {port, 2, [{interface, "eth2"}]},
         {port, 3, [{interface, "eth3"}]},
         {port, 4, [{interface, "eth4"}]}
        ]},
       {queues_status, disabled},
       {queues, []}
      ]}
    ]}
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
  ]}
].
```
### 2 Logical Switches
```erlang
[
 {linc,
  [
   {of_config, enabled},
   {logical_switches,
    [
     {switch, 0,
      [
       {backend, linc_us4},
       {controllers,
        [
          {"Switch0-DefaultController", "controller0.example.com", 6633, tcp}
        ]},
       {ports,
        [
         {port, 1, [{interface, "eth1"}]},
         {port, 2, [{interface, "eth2"}]},
         {port, 3, [{interface, "eth3"}]},
         {port, 4, [{interface, "eth4"}]},
         {port, 5, [{interface, "eth5"}]},
         {port, 6, [{interface, "eth6"}]},
         {port, 7, [{interface, "eth7"}]}
        ]},
        {queues_status, disabled},
        {queues, []}
       ]}

       , {switch, 1,
         [
          {backend, linc_us4},
          {controllers, []},
          {ports, [
            {port, 1, [{interface, "eth8"}]},
            {port, 2, [{interface, "eth9"}]},
            {port, 3, [{interface, "eth10"}]},
            {port, 4, [{interface, "eth11"}]},
            {port, 5, [{interface, "eth12"}]},
            {port, 6, [{interface, "eth13"}]},
            {port, 7, [{interface, "eth14"}]},
            {port, 8, [{interface, "eth15"}]}
          ]},
          {queues_status, disabled},
          {queues, []}
         ]}
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
     {lager_console_backend, debug},
     {lager_file_backend,
      [
       {"log/error.log", error, 10485760, "$D0", 5},
       {"log/console.log", debug, 10485760, "$D0", 5}
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
  ]}
].

```
