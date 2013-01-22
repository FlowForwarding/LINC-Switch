%%------------------------------------------------------------------------------
%% Copyright 2012 FlowForwarding.org
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%-----------------------------------------------------------------------------

%% @author Erlang Solutions Ltd. <openflow@erlang-solutions.com>
%% @copyright 2012 FlowForwarding.org
%% @doc OF-Config configuration module.
-module(linc_ofconfig).

-behaviour(gen_server).
-behaviour(gen_netconf).

%% Internal API
-export([start_link/0,
         get/1,
         is_present/4,
         features/1,
         flow_table_name/2]).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

%% gen_netconf callbacks
-export([handle_get_config/3,
         handle_edit_config/3,
         handle_copy_config/3,
         handle_delete_config/2,
         handle_lock/2,
         handle_unlock/2,
         handle_get/2]).

-include_lib("of_config/include/of_config.hrl").
-include_lib("of_protocol/include/of_protocol.hrl").
-include("linc_logger.hrl").

-record(ofconfig, {
          name = running :: running | startup,
          config :: #capable_switch{}
         }).

-record(state, {}).

%%------------------------------------------------------------------------------
%% Internal API functions
%%------------------------------------------------------------------------------

-spec start_link() -> {ok, pid()} | ignore | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec get(integer()) -> tuple(list(resource()), #logical_switch{}).
get(SwitchId) ->
    LogicalSwitchId = "LogicalSwitch" ++ integer_to_list(SwitchId),
    Ports = get_ports(SwitchId),
    Queues = get_queues(SwitchId),
    Certificates = get_certificates(SwitchId),
    FlowTables = get_flow_tables(SwitchId),
    Resources = Ports ++ Queues ++ Certificates ++ FlowTables,
    Refs = get_ports_refs(Ports)
        ++ get_queues_refs(Queues)
        ++ get_certificates_refs(Certificates)
        ++ get_flow_tables_refs(FlowTables),
    LogicalSwitch = #logical_switch{
                       id = LogicalSwitchId,
                       datapath_id = linc_logic:get_datapath_id(SwitchId),
                       enabled = true,
                       check_controller_certificate = false,
                       lost_connection_behavior = failSecureMode,
                       capabilities = get_capabilities(SwitchId),
                       controllers = get_controllers(SwitchId),
                       resources = Refs
                      },
    {Resources, LogicalSwitch}.

is_present(Value, List, IfPresent, IfAbsent) ->
    case lists:member(Value, List) of
        true ->
            IfPresent;
        false ->
            IfAbsent
    end.

-spec features(list(atom())) -> #features{}.
features(Features) ->
    Rate = rate(Features),
    AutoNegotiate = is_present(autoneg, Features, true, false),
    Medium = is_present(fiber, Features, fiber, copper),
    Pause = case lists:member(pause, Features) of
                true ->
                    symmetric;
                false ->
                    case lists:member(pause_asym, Features) of
                        true ->
                            asymmetric;
                        false ->
                            unsupported
                    end
            end,
    #features{rate = Rate,
              auto_negotiate = AutoNegotiate,
              medium = Medium,
              pause = Pause}.

-spec flow_table_name(integer(), integer()) -> string().
flow_table_name(SwitchId, TableId) ->
    DatapathId = linc_logic:get_datapath_id(SwitchId),
    DatapathId ++ "FlowTable" ++ integer_to_list(TableId).

%%------------------------------------------------------------------------------
%% gen_server callbacks
%%------------------------------------------------------------------------------

init([]) ->
    mnesia:change_table_copy_type(schema, node(), disc_copies),

    TabDef = [{attributes, record_info(fields, ofconfig)},
              {record_name, ofconfig},
              {disc_copies, [node()]}],
    mnesia:create_table(?MODULE, TabDef),

    mnesia:wait_for_tables([?MODULE], 5000),

    Startup = init_or_update_startup(),
    overwrite_running(Startup),

    {ok, #state{}}.

handle_call({get_config, _SessionId, Source, _Filter}, _From, State) ->
    [#ofconfig{config = Config}] = mnesia:dirty_read(?MODULE, Source),
    EncodedConfig = of_config:encode(Config),
    {reply, {ok, EncodedConfig}, State};
handle_call({edit_config, _SessionId, running, {xml, Config}}, _From, State) ->
    _Decoded = of_config:decode(Config),

    %% [Switch0] = Decoded#capable_switch.logical_switches,
    %% Controllers = Switch0#logical_switch.controllers,
    %% [add_controller(running, Ctrl) || Ctrl <- Controllers],

    {reply, ok, State};
handle_call(_, _, State) ->
    {reply, {error, {operation_failed, application}}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%------------------------------------------------------------------------------
%% gen_netconf callbacks
%%------------------------------------------------------------------------------

handle_get_config(SessionId, Source, Filter) ->
    gen_server:call(?MODULE,
                    {get_config, SessionId, Source, Filter}, infinity).

handle_edit_config(SessionId, Target, Config) ->
    gen_server:call(?MODULE,
                    {edit_config, SessionId, Target, Config}, infinity).

handle_copy_config(_SessionId, _Source, _Target) ->
    ok.

handle_delete_config(_SessionId, _Config) ->
    ok.

handle_lock(_SessionId, _Config) ->
    ok.

handle_unlock(_SessionId, _Config) ->
    ok.

handle_get(_SessionId, _Filter) ->
    {ok, "<capable-switch/>"}.

%%------------------------------------------------------------------------------
%% Helper functions
%%------------------------------------------------------------------------------

init_or_update_startup() ->
    case mnesia:dirty_read(?MODULE, startup) of
        [] ->
            InitialConfig = #ofconfig{name = startup,
                                      config = []},
            mnesia:dirty_write(?MODULE, InitialConfig),
            InitialConfig;
        [Startup] ->
            %% TODO: Update startup configuration with setting from sys.config
            NewStartup = update_startup(Startup),
            mnesia:dirty_write(?MODULE, NewStartup),
            NewStartup
    end.

update_startup(#ofconfig{config = Config} = Startup) ->
    Startup#ofconfig{config = Config}.

overwrite_running(#ofconfig{config = Startup}) ->
    Running = #ofconfig{name = running,
                        config = Startup},
    mnesia:dirty_write(?MODULE, Running).

%% add_controller(Target, Controller) ->
%%     [#ofconfig{config = Config}] = mnesia:dirty_read(?MODULE, Target),

%%     State = #controller_state{connection_state = up,
%%                               current_version = undefined,
%%                               supported_versions = []},
%%     NewCtrl = Controller#controller{role = equal,
%%                                     local_ip_address = undefined,
%%                                     local_port = undefined,
%%                                     state = State},

%%     IP = Controller#controller.ip_address,
%%     Port = Controller#controller.port,
%%     linc_receiver_sup:open(IP, Port),

%%     [Switch0] = Config#capable_switch.logical_switches,
%%     Controllers = Switch0#logical_switch.controllers,
%%     NewControllers = [NewCtrl | Controllers],
%%     NewSwitch = Switch0#logical_switch{controllers = NewControllers},

%%     NewConfig = Config#capable_switch{logical_switches = [NewSwitch]},

%%     mnesia:dirty_write(?MODULE, #ofconfig{name = Target,
%%                                           config = NewConfig}).

get_ports(SwitchId) ->
    OFConfigBackendMod = linc_logic:get_ofconfig_backend_mod(SwitchId),
    OFConfigBackendMod:get_ports(SwitchId).

get_ports_refs(Ports) ->
    lists:map(fun(#port{resource_id = ResourceId}) ->
                      {port, ResourceId}
              end, Ports).

get_queues(SwitchId) ->
    PortsBackendMod = linc_logic:get_ports_backend_mod(SwitchId),
    PortsBackendMod:get_all_queues_state(SwitchId).

get_queues_refs(Queues) ->
    lists:map(fun(#queue{resource_id = ResourceId}) ->
                      {queue, ResourceId}
              end, Queues).

get_certificates(_SwitchId) ->
    %% TODO: Get certificate configuration.
    %% PrivateKey = #private_key_rsa{
    %%   modulus = "AEF134F56EDB667DFA4320AEF134F56EDB667DFA4320",
    %%   exponent = "DFA4320AEF134F56EDB6SSS"},
    %% #certificate{resource_id = "ownedCertificate3",
    %%              type = owned,
    %%              certificate =
    %%                  "AEF134F56EDB667DFA4320AEF134F56EDB667DFA4320",
    %%              private_key = PrivateKey},
    %% #certificate{resource_id = "externalCertificate2",
    %%              type = external,
    %%              certificate =
    %%                  "AEF134F56EDB667DFA4320AEF134F56EDB667DFA4320",
    %%              private_key = undefined},
    [].

get_certificates_refs(Certificates) ->
    lists:map(fun(#certificate{resource_id = ResourceId}) ->
                      {certificate, ResourceId}
              end, Certificates).

get_flow_tables(SwitchId) ->
    OFConfigBackendMod = linc_logic:get_ofconfig_backend_mod(SwitchId),
    OFConfigBackendMod:get_flow_tables(SwitchId).

get_flow_tables_refs(FlowTables) ->
    lists:map(fun(#flow_table{resource_id = ResourceId}) ->
                      {flow_table, ResourceId}
              end, FlowTables).

get_capabilities(SwitchId) ->
    OFConfigBackendMod = linc_logic:get_ofconfig_backend_mod(SwitchId),
    OFConfigBackendMod:get_capabilities().

get_controllers(SwitchId) ->
    lists:map(fun({ControllerId, Role,
                   {ControllerIP, ControllerPort},
                   {LocalIP, LocalPort},
                   Protocol, ConnectionState,
                   CurrentVersion, SupportedVersions}) ->
                      Id = "Switch"
                          ++ integer_to_list(SwitchId)
                          ++ "Controller"
                          ++ integer_to_list(ControllerId),
                      #controller{
                         id = Id,
                         role = Role,
                         ip_address = ip(ControllerIP),
                         port = ControllerPort,
                         local_ip_address = ip(LocalIP),
                         local_port = LocalPort,
                         protocol = Protocol,
                         state = #controller_state{
                                    connection_state = ConnectionState,
                                    current_version =
                                        version(CurrentVersion),
                                    supported_versions =
                                        [version(V) || V <- SupportedVersions]
                                   }
                        }
              end, ofp_client:get_controllers_state(SwitchId)).

%%------------------------------------------------------------------------------
%% Helper conversion functions
%%------------------------------------------------------------------------------

rate(Features) ->
    Rates = lists:map(fun('10mb_hd') ->
                              '10mb-hd';
                         ('10mb_fd') ->
                              '10mb-fd';
                         ('100mb_hd') ->
                              '100mb-hd';
                         ('100mb_fd') ->
                              '100mb-fd';
                         ('1gb_hd') ->
                              '1gb-hd';
                         ('1gb_fd') ->
                              '1gb-fd';
                         ('10gb_fd') ->
                              '10gb-fd';
                         ('40gb_fd') ->
                              '40gb-fd';
                         ('100gb_fd') ->
                              '100gb-fd';
                         ('1tb_fd') ->
                              '1tb-fd';
                         (other) ->
                              other;
                         (_) ->
                              invalid
                      end, Features),
    lists:filter(fun(invalid) ->
                         true;
                    (_) ->
                         false
                 end, Rates),
    hd(Rates).

ip({A, B, C, D}) ->
    integer_to_list(A) ++ "."
        ++ integer_to_list(B) ++ "."
        ++ integer_to_list(C) ++ "."
        ++ integer_to_list(D).

version(1) ->
    '1.0';
version(2) ->
    '1.1';
version(3) ->
    '1.2';
version(4) ->
    '1.3'.
