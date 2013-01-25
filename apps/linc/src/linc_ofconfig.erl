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

-behaviour(gen_netconf).
-behaviour(gen_server).

-compile(export_all).

%% Internal API
-export([start_link/0,
         get_state/1,
         get_config/1,
         flow_table_name/3,
         convert_port_config/1,
         convert_port_features/4,
         convert_port_state/1
        ]).

%% gen_netconf callbacks
-export([handle_get_config/3,
         handle_edit_config/3,
         handle_copy_config/3,
         handle_delete_config/2,
         handle_lock/2,
         handle_unlock/2,
         handle_get/2]).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-include_lib("of_config/include/of_config.hrl").
-include_lib("of_protocol/include/of_protocol.hrl").
-include("linc_logger.hrl").

-define(STARTUP, linc_ofconfig_startup).

-type ofc_port() :: {port,
                     PortId :: integer(),
                     Config :: #port_configuration{},
                     Features :: #port_features{}}.

-type ofc_queue() :: {queue,
                      {PortId :: integer(), QueueId :: integer()},
                      MinRate :: integer(),
                      MaxRate :: integer()}.

-type ofc_controller() :: {controller,
                           {SwitchId :: integer(), ControllerId :: string()},
                           Host :: string(),
                           Port :: integer(),
                           Protocol :: tcp}.

-type ofc_switch() :: {switch,
                       SwitchId :: integer(),
                       DatapathId :: string()}.

-record(ofconfig, {
          name = startup,
          ports = [] :: [ofc_port()],
          queues = [] :: [ofc_queue()],
          switches = [] :: [ofc_switch()],
          controllers = [] :: [ofc_controller()]
         }).

-record(state, {}).

%%------------------------------------------------------------------------------
%% Internal API functions
%%------------------------------------------------------------------------------

-spec start_link() -> {ok, pid()} | ignore | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec get_state(integer()) -> tuple(list(resource()), #logical_switch{}).
get_state(SwitchId) ->
    LogicalSwitchId = "LogicalSwitch" ++ integer_to_list(SwitchId),
    Ports = linc_logic:get_backend_ports(SwitchId),
    Queues = linc_logic:get_backend_queues(SwitchId),
    Certificates = get_certificates(SwitchId),
    FlowTables = linc_logic:get_backend_flow_tables(SwitchId),
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
                       capabilities = linc_logic:get_backend_capabilities(SwitchId),
                       controllers = get_controllers(SwitchId),
                       resources = Refs
                      },
    {Resources, LogicalSwitch}.

-spec get_config(integer()) -> #ofconfig{}.
get_config(SwitchId) ->
    Ports = lists:map(fun(#port{number = PortNo,
                                configuration = Config,
                                features = Features}) ->
                              {port, PortNo, Config, Features}
                      end, linc_logic:get_backend_ports(SwitchId)),
    Queues = lists:map(fun(#queue{id = QueueId,
                                  port = PortNo,
                                  properties = #queue_properties{
                                                  min_rate = MinRate,
                                                  max_rate = MaxRate
                                                 }}) ->
                               {queue, {PortNo, QueueId}, MinRate, MaxRate}
                       end, linc_logic:get_backend_queues(SwitchId)),
    Switches = [{switch, SwitchId, linc_logic:get_datapath_id(SwitchId)}],
    Controllers = lists:map(fun(#controller{id = ControllerId,
                                            ip_address = IPAddress,
                                            port = Port,
                                            protocol = Protocol}) ->
                                    {controller, {SwitchId, ControllerId},
                                     IPAddress, Port, Protocol}
                            end, get_controllers(SwitchId)),
    #ofconfig{name = running,
              ports = Ports,
              queues = Queues,
              switches = Switches,
              controllers = Controllers}.

-spec flow_table_name(integer(), string(), integer()) -> string().
flow_table_name(SwitchId, DatapathId, TableId) ->
    "Switch" ++ integer_to_list(SwitchId)
        ++ DatapathId
        ++ "FlowTable" ++ integer_to_list(TableId).

-spec convert_port_config([atom()]) -> #port_configuration{}.
convert_port_config(Config) ->
    AdminState = is_present(port_down, Config, up, down),
    NoReceive = is_present(no_recv, Config, true, false),
    NoForward = is_present(no_fwd, Config, true, false),
    NoPacketIn = is_present(no_packet_in, Config, true, false),
    #port_configuration{
       admin_state = AdminState,
       no_receive = NoReceive,
       no_forward = NoForward,
       no_packet_in = NoPacketIn
      }.

-spec convert_port_features([atom()], [atom()], [atom()], [atom()]) ->
                                   #port_features{}.
convert_port_features(Current, Advertised, Supported, Peer) ->
    #port_features{
       current = features(Current),
       advertised = features(Advertised),
       supported = features(Supported),
       advertised_peer = features(Peer)
      }.

-spec convert_port_state([atom()]) -> #port_state{}.
convert_port_state(State) ->
    OperState = is_present(link_down, State, down, up),
    Blocked = is_present(blocked, State, true, false),
    Live = linc_ofconfig:is_present(live, State, true, false),
    #port_state{oper_state = OperState,
                blocked = Blocked,
                live = Live}.

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
%% gen_server callbacks
%%------------------------------------------------------------------------------

init([]) ->
    mnesia:change_table_copy_type(schema, node(), disc_copies),
    TabDef = [{attributes, record_info(fields, ofconfig)},
              {record_name, ofconfig},
              {disc_copies, [node()]}],
    mnesia:create_table(?STARTUP, TabDef),
    mnesia:wait_for_tables([?STARTUP], 5000),
    init_startup(),
    {ok, #state{}}.

handle_call({get_config, _SessionId, Source, _Filter}, _From, State) ->
    Config = get_of_config(Source),
    EncodedConfig = of_config:encode(Config),
    {reply, {ok, EncodedConfig}, State};
handle_call({edit_config, _SessionId, startup, {xml, Xml}}, _From, State) ->
    Config = of_config:decode(Xml),
    case check_capable_switch_id(Config#capable_switch.id) of
        true ->
            case execute_operations(extract_operations(Config, merge),
                                    stop, running) of
                ok ->
                    {reply, ok, State};
                {error, Errors} ->
                    {reply, hd(Errors), State}
            end;
        false ->
            {reply, {error, data_missing}, State}
    end;
handle_call(_, _, State) ->
    {reply, {error, {operation_failed, application}}, State}.

check_capable_switch_id(CapableSwitchId) ->
    case application:get_env(linc, capable_switch_id) of
        {ok, CapableSwitchId} ->
            true;
        _Else ->
            false
    end.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%------------------------------------------------------------------------------
%% Helper functions
%%------------------------------------------------------------------------------

init_startup() ->
    case mnesia_read(startup) of
        [] ->
            InitialConfig = #ofconfig{name = startup},
            mnesia_write(startup, InitialConfig);
        _Else ->
            ok
    end.

get_of_config(running) ->
    {ok, Switches} = application:get_env(linc, logical_switches),
    Config = merge([get_config(Id) || {switch, Id, _} <- Switches]),
    {ok, CapSwitchId} = application:get_env(linc, capable_switch_id),
    Config#capable_switch{id = CapSwitchId}.

%% @doc Merge configuration from logical switches.
merge(Configs) ->
    merge(Configs, #capable_switch{resources = [],
                                   logical_switches = []}).

merge([], Config) ->
    Config;
merge([{NewResources, NewSwitch} | Rest],
      #capable_switch{resources = Resources,
                      logical_switches = Switches} = Config) ->
    NewConfig = Config#capable_switch{
                  resources = Resources ++ NewResources,
                  logical_switches = Switches ++ [NewSwitch]},
    merge(Rest, NewConfig).

%%------------------------------------------------------------------------------
%% Function for extracting actions from the received config
%%------------------------------------------------------------------------------

extract_operations(#capable_switch{resources = Resources,
                                   logical_switches = Switches}, DefOp) ->
    SC = case Switches of
             undefined ->
                 [];
             _ ->
                 [begin
                      SwitchId = extract_id(SwitchIdStr),
                      {{DefOp, {switch, SwitchId, Datapath}},
                       [{DefOp, {controller, {SwitchId, Id}, IP, Port, Proto}}
                        || #controller{id = Id,
                                       ip_address = IP,
                                       port = Port,
                                       protocol = Proto} <- Controllers]}
                  end || #logical_switch{
                            id = SwitchIdStr,
                            datapath_id = Datapath,
                            controllers = Controllers} <- Switches]
         end,
    {S, Cs} = lists:unzip(SC),
    C = lists:merge(Cs),

    P = case Resources of
            undefined ->
                [];
            _ ->
                [{DefOp, {port, PortId, Config, Features}}
                 || #port{number = PortId,
                          configuration = Config,
                          features = #port_features{
                                        advertised = Features}} <- Resources]
        end,
    Q = case Resources of
            undefined ->
                [];
            _ ->
                [{DefOp, {queue, {QueueId, PortId}, Properties}}
                 || #queue{id = QueueId,
                           port = PortId,
                           properties = Properties} <- Resources]
        end,
    P ++ Q ++ S ++ C.
    
extract_id(String) ->
    %% FIXME: Case when client sends something else
    list_to_integer(string:sub_string(String, 14)).

execute_operations([], stop, _) ->
    ok;
execute_operations([], {continue, []}, _) ->
    ok;
execute_operations([], {continue, Errors}, _) ->
    {error, lists:reverse(Errors)};
execute_operations([{Op, {port, PortId, Config, Features} = Port} | Rest],
                   OnError, Target) ->
    case Op of
        none ->
            execute_operations(Rest, OnError, Target);
        Op when Op == create orelse
                Op == delete orelse
                Op == remove ->
            handle_error(unsupported_operation, OnError, Rest, Target);
        Op ->
            case Target of
                running ->
                    linc_logic:set_port_config(Op, PortId,
                                               Config, Features);
                _ ->
                    ok
            end,
            update_mnesia(Target, Op, Port),
            execute_operations(Rest, OnError, Target)
    end;
execute_operations([{Op, {queue, {QueueId, PortId},
                          Properties} = Queue} | Rest],
                   OnError, Target) ->
    case Op of
        none ->
            execute_operations(Rest, OnError, Target);
        Op when Op == create orelse
                Op == delete orelse
                Op == remove ->
            handle_error(unsupported_operation, OnError, Rest, Target);
        Op ->
            case Target of
                running ->
                    linc_logic:set_queue_config(Op, QueueId, PortId,
                                                Properties);
                _ ->
                    ok
            end,
            update_mnesia(Target, Op, Queue),
            execute_operations(Rest, OnError, Target)
    end;
execute_operations([{Op, {switch, SwitchId, DatapathId} = Switch} | Rest],
                   OnError, Target) ->
    case Op of
        none ->
            execute_operations(Rest, OnError, Target);
        Op when Op == create orelse
                Op == delete orelse
                Op == remove ->
            handle_error(unsupported_operation, OnError, Rest, Target);
        Op ->
            case Target of
                running ->
                    linc_logic:set_switch_config(Op, SwitchId, DatapathId);
                _ ->
                    ok
            end,
            update_mnesia(Target, Op, Switch),
            execute_operations(Rest, OnError, Target)
    end;
execute_operations([{Op, {controller, {SwitchId, CtrlId},
                          Host, Port, Protocol} = Controller} | Rest],
                   OnError, Target) ->
    case Op of
        none ->
            execute_operations(Rest, OnError, Target);
        Op ->
            case Target of
                running ->
                    linc_logic:set_controller_config(Op, SwitchId, CtrlId,
                                                     Host, Port, Protocol);
                _ ->
                    ok
            end,
            case update_mnesia(Target, Op, Controller) of
                ok ->
                    execute_operations(Rest, OnError, Target);
                {error, Error} ->
                    handle_error(Error, OnError, Rest, Target)
            end
    end.

handle_error(Error, OnError, Rest, Target) ->
    case OnError of
        stop ->
            {error, [Error]};
        {continue, Errors} ->
            execute_operations(Rest, {continue, [Error | Errors]}, Target)
    end.

%%------------------------------------------------------------------------------
%% Function for updating things in Mnesia
%%------------------------------------------------------------------------------

mnesia_read(startup) ->
    mnesia:dirty_read(?STARTUP, startup).

mnesia_write(startup, Config) ->
    mnesia:dirty_write(?STARTUP, Config).

update_mnesia(Target, merge, {port, PortId, _, _} = Port) ->
    [#ofconfig{ports = Ports} = Config] = mnesia_read(Target),
    case lists:keyfind(PortId, 2, Ports) of
        false ->
            mnesia_write(Target, Config#ofconfig{ports = [Port | Ports]});
        _ ->
            ok
    end;
update_mnesia(Target, replace, {port, PortId, _, _} = Port) ->
    [#ofconfig{ports = Ports} = Config] = mnesia_read(Target),
    case lists:keyfind(PortId, 2, Ports) of
        {port, PortId, _, _} ->
            NewPorts = lists:keyreplace(PortId, 3, Ports, Port),
            mnesia_write(Target, Config#ofconfig{ports = NewPorts});
        false ->
            mnesia_write(Target, Config#ofconfig{ports = [Port | Ports]})
    end;
update_mnesia(Target, merge, {queue, {QueueId, PortId}, _} = Queue) ->
    [#ofconfig{queues = Queues} = Config] = mnesia_read(Target),
    case lists:keyfind({QueueId, PortId}, 2, Queues) of
        false ->
            mnesia_write(Target, Config#ofconfig{queues = [Queue | Queues]});
        _ ->
            ok
    end;
update_mnesia(Target, replace, {queue, {QueueId, PortId}, _} = Queue) ->
    [#ofconfig{queues = Queues} = Config] = mnesia_read(Target),
    case lists:keyfind({QueueId, PortId}, 2, Queues) of
        {queue, {QueueId, PortId}, _} ->
            NewQueues = lists:keyreplace({QueueId, PortId}, 2, Queues, Queue),
            mnesia_write(Target, Config#ofconfig{queues = NewQueues});
        false ->
            mnesia_write(Target, Config#ofconfig{queues = [Queue | Queues]})
    end;
update_mnesia(Target, merge, {switch, SwitchId, _} = Switch) ->
    [#ofconfig{switches = Switches} = Config] = mnesia_read(Target),
    case lists:keyfind(SwitchId, 2, Switches) of
        false ->
            mnesia_write(Target, Config#ofconfig{
                                   switches = [Switch | Switches]});
        _ ->
            ok
    end;
update_mnesia(Target, replace, {switch, SwitchId, _} = Switch) ->
    [#ofconfig{switches = Switches} = Config] = mnesia_read(Target),
    case lists:keyfind(SwitchId, 2, Switches) of
        {switch, SwitchId, _} ->
            NewSwitches = lists:keyreplace(SwitchId, 2, Switches, Switch),
            mnesia_write(Target, Config#ofconfig{switches = NewSwitches});
        false ->
            mnesia_write(Target, Config#ofconfig{
                                   switches = [Switch | Switches]})
    end;
update_mnesia(Target, create, {controller,
                               {SwitchId, ControllerId}, _ , _, _} = Ctrl) ->
    [#ofconfig{controllers = Ctrls} = Config] = mnesia_read(Target),
    case lists:keyfind({SwitchId, ControllerId}, 2, Ctrls) of
        false ->
            mnesia_write(Target, Config#ofconfig{controllers = [Ctrl | Ctrls]}),
            ok;
        _ ->
            {error, data_exists}
    end;
update_mnesia(Target, merge, {controller,
                              {SwitchId, ControllerId}, _, _, _} = Ctrl) ->
    [#ofconfig{controllers = Ctrls} = Config] = mnesia_read(Target),
    case lists:keyfind({SwitchId, ControllerId}, 2, Ctrls) of
        false ->
            mnesia_write(Target, Config#ofconfig{controllers = [Ctrl | Ctrls]}),
            ok;
        _ ->
            ok
    end;
update_mnesia(Target, replace, {controller,
                                {SwitchId, ControllerId}, _, _, _} = Ctrl) ->
    [#ofconfig{controllers = Ctrls} = Config] = mnesia_read(Target),
    case lists:keyfind({SwitchId, ControllerId}, 2, Ctrls) of
        {controller, {SwitchId, ControllerId}, _, _, _} ->
            NewCtrls = lists:keyreplace({SwitchId, ControllerId},
                                        2, Ctrls, Ctrl),
            mnesia_write(Target, Config#ofconfig{controllers = NewCtrls});
        false ->
            mnesia_write(Target, Config#ofconfig{controllers = [Ctrl | Ctrls]})
    end,
    ok;
update_mnesia(Target, delete, {controller,
                               {SwitchId, ControllerId}, _, _, _} = Ctrl) ->
    [#ofconfig{controllers = Ctrls} = Config] = mnesia_read(Target),
    case lists:keyfind({SwitchId, ControllerId}, 2, Ctrls) of
        false ->
            {error, data_missing};
        _ ->
            NewCtrls = lists:keydelete({SwitchId, ControllerId},
                                       2, Ctrls, Ctrl),
            mnesia_write(Target, Config#ofconfig{controllers = NewCtrls}),
            ok
    end;
update_mnesia(Target, remove, {controller,
                               {SwitchId, ControllerId}, _, _, _} = Ctrl) ->
    [#ofconfig{controllers = Ctrls} = Config] = mnesia_read(Target),
    case lists:keyfind({SwitchId, ControllerId}, 2, Ctrls) of
        false ->
            ok;
        _ ->
            NewCtrls = lists:keydelete({SwitchId, ControllerId},
                                       2, Ctrls, Ctrl),
            mnesia_write(Target, Config#ofconfig{controllers = NewCtrls}),
            ok
    end.

%%------------------------------------------------------------------------------
%% Backend state/configuration get functions
%%------------------------------------------------------------------------------

get_ports_refs(Ports) ->
    lists:map(fun(#port{resource_id = ResourceId}) ->
                      {port, ResourceId}
              end, Ports).

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

get_flow_tables_refs(FlowTables) ->
    lists:map(fun(#flow_table{resource_id = ResourceId}) ->
                      {flow_table, ResourceId}
              end, FlowTables).

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
