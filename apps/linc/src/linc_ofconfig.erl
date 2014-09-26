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

%% Internal API
-export([start_link/0,
         flow_table_name/3,
         get_linc_logical_switches/0,
         convert_port_config/1,
         convert_port_features/1,
         convert_port_state/1,
         read_and_update_startup/0,
         get_startup_without_ofconfig/0,
         get_certificates/0,
         get_switch_state/1]).

%% gen_netconf callbacks
-export([handle_get_config/3,
         handle_edit_config/5,
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

-define(DEFAULT_PORT_CONFIG, #port_configuration{
                                admin_state = up,
                                no_receive = false,
                                no_forward = false,
                                no_packet_in = false}).
-define(DEFAULT_PORT_FEATURES, #features{
                                  rate = '100Mb-FD',
                                  auto_negotiate = true,
                                  medium = copper,
                                  pause = unsupported}).

-define(DEFAULT_PORT_RATE, {100, mbps}).

-type ofc_port() :: {port,
                     {PortId :: integer(),
                      SwitchId :: integer()},
                     Config :: #port_configuration{},
                     Features :: #port_features{}}.

-type ofc_queue() :: {queue,
                      {QueueId :: integer(),
                       PortId :: integer(),
                       SwitchId :: integer()},
                      MinRate :: integer(),
                      MaxRate :: integer()}.

-type ofc_controller() :: {controller,
                           {ControllerId :: string(),
                            SwitchId :: integer()},
                           Host :: string(),
                           Port :: integer(),
                           Protocol :: tcp | tls}.

-type ofc_switch() :: {switch,
                       SwitchId :: integer(),
                       DatapathId :: string()}.

-record(ofconfig, {
          name = startup,
          ports = [] :: [ofc_port()],
          queues = [] :: [ofc_queue()],
          switches = [] :: [ofc_switch()],
          controllers = [] :: [ofc_controller()],
          certificates = [] :: [{Id :: string(), Certificate :: string()}]
         }).

-record(state, {
          certificates = [] :: [{Id :: string(), Certificate :: string()}]
         }).

%%------------------------------------------------------------------------------
%% Internal API functions
%%------------------------------------------------------------------------------

-spec start_link() -> {ok, pid()} | ignore | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

get_certificates() ->
    case application:get_env(linc, of_config) of
        {ok, enabled} ->
            gen_server:call(?MODULE, get_certificates);
        _ ->
            []
    end.

-spec get_state(list()) -> #capable_switch{}.
get_state(Certs) ->
    Switches = get_linc_logical_switches(),
    Config = merge([get_switch_state(Id) || {switch, Id, _} <- Switches]),
    {ok, CapSwitchId} = application:get_env(linc, capable_switch_id),
    Config#capable_switch{id = CapSwitchId,
                          resources = Config#capable_switch.resources ++
                              convert_certificates(Certs)}.

-spec get_switch_state(integer()) -> tuple(list(resource()), #logical_switch{}).
get_switch_state(SwitchId) ->
    LogicalSwitchId = "LogicalSwitch" ++ integer_to_list(SwitchId),
    Ports = linc_logic:get_backend_ports(SwitchId),
    Queues = linc_logic:get_backend_queues(SwitchId),
    Certificates = get_certificates(SwitchId),
    FlowTables = [], %% FIXME: linc_logic:get_backend_flow_tables(SwitchId),
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
                       capabilities =
                           linc_logic:get_backend_capabilities(SwitchId),
                       controllers = get_logical_switch_controllers(SwitchId),
                       resources = Refs
                      },
    {Resources, [LogicalSwitch]}.

-spec get_config(integer()) -> #ofconfig{}.
get_config(SwitchId) ->
    Ports = lists:map(fun(#port{number = PortNo,
                                configuration = Config,
                                features = #port_features{
                                              advertised = Features}}) ->
                              {port, {PortNo, SwitchId}, Config, Features}
                      end, linc_logic:get_backend_ports(SwitchId)),
    Queues = lists:map(fun(#queue{id = QueueId,
                                  port = PortNo,
                                  properties = #queue_properties{
                                                  min_rate = MinRate,
                                                  max_rate = MaxRate
                                                 }}) ->
                               {queue, {QueueId, PortNo, SwitchId},
                                MinRate, MaxRate}
                       end, linc_logic:get_backend_queues(SwitchId)),
    Switches = [{switch, SwitchId, linc_logic:get_datapath_id(SwitchId)}],
    #ofconfig{name = running,
              ports = Ports,
              queues = Queues,
              switches = Switches,
              controllers = get_controllers(SwitchId)}.

-spec flow_table_name(integer(), string(), integer()) -> string().
flow_table_name(SwitchId, DatapathId, TableId) ->
    "Switch" ++ integer_to_list(SwitchId)
        ++ DatapathId
        ++ "FlowTable" ++ integer_to_list(TableId).

-spec get_linc_logical_switches() -> term().
get_linc_logical_switches() ->
    {ok, LogicalSwitches} = application:get_env(linc, logical_switches),
    {ok, CapableSwitchPorts} = application:get_env(linc, capable_switch_ports),
    {ok, CapableSwitchQueues} = application:get_env(linc, capable_switch_queues),
    [convert_logical_switch(S, CapableSwitchPorts, CapableSwitchQueues)
     || S <- LogicalSwitches].

convert_logical_switch({switch, SwitchId, LogicalConfig},
                       CapablePorts, CapableQueues) ->
    {ports, LogicalPorts} = lists:keyfind(ports, 1, LogicalConfig),
    {NewPorts, NewQueues} = convert_ports_and_queues(CapablePorts,
                                                     CapableQueues,
                                                     LogicalPorts),
    {controllers, Controllers} = lists:keyfind(controllers, 1,
                                               LogicalConfig),
    NewControllers = convert_controllers(Controllers),
    NewOpts = [{ports, NewPorts}, {queues, NewQueues},
               {controllers, NewControllers}],
    NewLogicalConfig =
        lists:foldl(fun({Opt, _} = OptValue, Config) ->
                            lists:keystore(Opt, 1, Config, OptValue)
                    end, LogicalConfig, NewOpts),
    {switch, SwitchId, NewLogicalConfig}.

convert_ports_and_queues(CapablePorts, CapableQueues, LogicalPorts) ->
    lists:foldl(
      fun({port, PortNo, LogicalPortOpts}, {Ports, Queues}) ->
              {_, _, CapablePortOpts} = lists:keyfind(PortNo, 2,
                                                      CapablePorts),
              PortRate = logical_switch_port_rate(CapablePortOpts),
              QueuesIds = logical_port_queues_ids(LogicalPortOpts),
              NewPortQueues = convert_queues(PortNo,
                                             PortRate,
                                             QueuesIds,
                                             CapableQueues),
              NewPortConfig = convert_port_opts(CapablePortOpts,
                                                LogicalPortOpts),
              NewPort = {port, PortNo, NewPortConfig},
              {[NewPort | Ports], [NewPortQueues | Queues]}
      end, {[], []}, LogicalPorts).

logical_port_queues_ids(LogicalPortOpts) when is_list(LogicalPortOpts) ->
    proplists:get_value(queues, LogicalPortOpts);
logical_port_queues_ids(OldFormatOpts) ->
    {queues, QueuesIds} = OldFormatOpts,
    QueuesIds.

convert_queues(PortNo, PortRate, QueueIds, CapableSwitchQueues) ->
    PortQueues =
        [begin
             {queue, QId, QueueConfig} = lists:keyfind(QId, 2,
                                                       CapableSwitchQueues),
             {QId, QueueConfig}
         end || QId <- QueueIds],
    {port, PortNo, [PortRate, {port_queues, PortQueues}]}.

convert_port_opts(CapablePortOpts, LogicalPortOpts)
  when is_list(LogicalPortOpts) ->
    Opts = [lists:keyfind(Opt, 1, LogicalPortOpts)
            || Opt <- [port_no, port_name]],
    [O || O <- Opts, O =/= false] ++ CapablePortOpts;
convert_port_opts(CapablePortOpts, _OldFormatOpts = {queues, _}) ->
    CapablePortOpts.

convert_controllers(Controllers) ->
    [begin
         Host = element(2, C),
         setelement(2, C, convert_host_to_ip(Host))
     end || C <- Controllers].

convert_host_to_ip(Host) ->
    {ok, IP} = inet:getaddr(Host, inet),
    inet_parse:ntoa(IP).

-spec convert_port_config([atom()] | #port_configuration{}) ->
                                 #port_configuration{} | [atom()].
convert_port_config(#port_configuration{admin_state = State,
                                        no_receive = NoReceive,
                                        no_forward = NoForward,
                                        no_packet_in = NoPacketIn}) ->
    translate([{State, down, port_down},
               {NoReceive, true, no_recv},
               {NoForward, true, no_fwd},
               {NoPacketIn, true, no_packet_in}]);
convert_port_config(Config) when is_list(Config) ->
    AdminState = is_present(port_down, Config, down, up),
    NoReceive = is_present(no_recv, Config, true, false),
    NoForward = is_present(no_fwd, Config, true, false),
    NoPacketIn = is_present(no_packet_in, Config, true, false),
    #port_configuration{
       admin_state = AdminState,
       no_receive = NoReceive,
       no_forward = NoForward,
       no_packet_in = NoPacketIn
      }.

-spec convert_port_features({[atom()], [atom()], [atom()], [atom()]}
                            | #features{})
                           -> #port_features{} | [atom()].
convert_port_features({Current, Advertised, Supported, Peer}) ->
    #port_features{
       current = features(Current),
       advertised = features(Advertised),
       supported = features(Supported),
       advertised_peer = features(Peer)
      };
convert_port_features(#features{rate = Rate2,
                                auto_negotiate = Auto,
                                medium = Medium,
                                pause = Pause}) ->
    Rate = list_to_atom(string:to_lower(atom_to_list(Rate2))),
    translate([{Rate, '10Mb-HD', '10mb_hd'},
               {Rate, '10Mb-FD', '10mb_fd'},
               {Rate, '100Mb-HD', '100mb_hd'},
               {Rate, '100Mb-FD', '100mb_fd'},
               {Rate, '1Gb-HD', '1gb_hd'},
               {Rate, '1Gb-FD', '1gb_fd'},
               {Rate, '10Gb', '10gb_fd'},
               {Rate, '40Gb', '40gb_fd'},
               {Rate, '100Gb', '100gb_fd'},
               {Rate, '1Tb', '1tb_fd'},
               {Rate, other, other},
               {Medium, copper, copper},
               {Medium, fiber, fiber},
               {Auto, true, autoneg},
               {Pause, symmetric, pause},
               {Pause, asymmetric, pause_asym}]).

-spec convert_port_state([atom()]) -> #port_state{}.
convert_port_state(State) ->
    OperState = is_present(link_down, State, down, up),
    Blocked = is_present(blocked, State, true, false),
    Live = is_present(live, State, true, false),
    #port_state{oper_state = OperState,
                blocked = Blocked,
                live = Live}.

delete_startup() ->
    Sys = get_linc_logical_switches(),
    NewStartup = delete_startup_switches(Sys, #ofconfig{name = startup}),
    mnesia_write(startup, NewStartup#ofconfig{certificates = []}).

delete_startup_switches([], NewStartup) ->
    NewStartup;
delete_startup_switches([{switch, SwitchId, Opts} | Rest],
                        #ofconfig{ports = Ports,
                                  queues = Queues,
                                  switches = Switches,
                                  controllers = Ctrls} = Startup) ->
    NewPorts = case lists:keyfind(ports, 1, Opts) of
                   false ->
                       [];
                   {ports, SysPorts} ->
                       [{port, {PortId, SwitchId},
                         ?DEFAULT_PORT_CONFIG,
                         ?DEFAULT_PORT_FEATURES}
                        || {port, PortId, _} <- SysPorts]
               end,
    NewQueues = case lists:keyfind(queues_status, 1, Opts) of
                    {queues_status, enabled} ->
                        case lists:keyfind(queues, 1, Opts) of
                            false ->
                                [];
                            {queues, SysQPorts} ->
                                delete_startup_queues(SysQPorts, SwitchId)
                        end;
                    _ ->
                        []
                end,
    NewCtrls = [],
    NewSwitch = {switch, SwitchId, get_datapath_id(SwitchId, Opts)},
    NewStartup = Startup#ofconfig{ports = Ports ++ NewPorts,
                                  queues = Queues ++ lists:flatten(NewQueues),
                                  switches = [NewSwitch | Switches],
                                  controllers = Ctrls ++ NewCtrls},
    delete_startup_switches(Rest, NewStartup).

delete_startup_queues(SysQPorts, SwitchId) ->
    [begin
         {_, SysQueues2} = lists:keyfind(port_queues, 1, SysQueues),
         [begin
              MinRate = case lists:keyfind(min_rate, 1, Props) of
                            {min_rate, MinR} -> MinR;
                            false -> undefined
                        end,
              MaxRate = case lists:keyfind(max_rate, 1, Props) of
                            {max_rate, MaxR} -> MaxR;
                            false -> undefined
                        end,
              {queue, {QueueId, PortId, SwitchId}, MinRate, MaxRate}
          end
          || {QueueId, Props} <- SysQueues2]
     end
     || {port, PortId, SysQueues} <- SysQPorts].

read_and_update_startup() ->
    [Startup] = mnesia_read(startup),
    Sys = get_linc_logical_switches(),
    InitNew = {[], #ofconfig{name = startup}},
    {Config, NewStartup} = update_switches(Sys, Startup, InitNew),
    mnesia_write(startup, NewStartup#ofconfig{
                            certificates = Startup#ofconfig.certificates}),
    Config.

-spec get_startup_without_ofconfig() -> [term()].
get_startup_without_ofconfig() ->
    [begin
         LSW1 = assure_datapath_id_in_logical_switch_config(LSW0),
         convert_logical_switch_ports(LSW1)
     end || LSW0 <- get_linc_logical_switches()].

%%------------------------------------------------------------------------------
%% gen_netconf callbacks
%%------------------------------------------------------------------------------

handle_get_config(SessionId, Source, Filter) ->
    gen_server:call(?MODULE,
                    {get_config, SessionId, Source, Filter}, infinity).

handle_edit_config(SessionId, Target, Config, DefaultOp, OnError) ->
    gen_server:call(?MODULE,
                    {edit_config, SessionId, Target,
                     Config, DefaultOp, OnError}, infinity).

handle_copy_config(SessionId, Source, Target) ->
    gen_server:call(?MODULE,
                    {copy_config, SessionId, Source, Target}, infinity).

handle_delete_config(SessionId, Config) ->
    gen_server:call(?MODULE, {delete_config, SessionId, Config}, infinity).

handle_lock(SessionId, Config) ->
    gen_server:call(?MODULE, {lock, SessionId, Config}, infinity).

handle_unlock(SessionId, Config) ->
    gen_server:call(?MODULE, {unlock, SessionId, Config}, infinity).

handle_get(SessionId, Filter) ->
    gen_server:call(?MODULE, {get, SessionId, Filter}, infinity).

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
    Certificates = init_startup(),
    {ok, #state{certificates = Certificates}}.

handle_call({get_config, _SessionId, Source, _Filter}, _From,
            #state{certificates = Certs} = State)
  when Source == running orelse Source == startup ->
    Config = get_capable_switch_config(Source),
    Config2 = Config#capable_switch{resources =
                                        Config#capable_switch.resources ++
                                        convert_certificates(Certs)},
    EncodedConfig = of_config:encode(Config2),
    {reply, {ok, EncodedConfig}, State};
handle_call({edit_config, _SessionId, Target, {xml, Xml}, DefaultOp, OnError},
            _From, #state{certificates = Certs} = State)
  when (OnError == 'stop-on-error' orelse OnError == 'continue-on-error') andalso
       (DefaultOp == merge orelse DefaultOp == replace orelse DefaultOp == none)
       andalso (Target == running orelse Target == startup) ->
    case of_config:decode(Xml) of
        {error, _Reason} ->
            {reply, {error, malformed_message}, State};
        Config ->
            case check_capable_switch_id(Config#capable_switch.id) of
                true ->
                    MyOnError = case OnError of
                                    'stop-on-error' -> stop;
                                    'continue-on-error' -> {continue, []}
                                end,
                    case catch execute_operations(
                                 extract_operations(Config, DefaultOp),
                                 MyOnError, Target, Certs) of
                        {ok, NewCerts} ->
                            {reply, ok, State#state{certificates = NewCerts}};
                        {{error, Errors}, NewCerts} when is_list(Errors) ->
                            {reply, {error, hd(Errors)},
                             State#state{certificates = NewCerts}};
                        {{error, Error}, NewCerts} ->
                            {reply, {error, Error},
                             State#state{certificates = NewCerts}}
                    end;
                false ->
                    {reply, {error, data_missing}, State}
            end
    end;
handle_call({copy_config, _SessionId, running, startup}, _From,
            #state{certificates = Certs} = State) ->
    Switches = get_linc_logical_switches(),
    Config = merge_ofc([get_config(Id) || {switch, Id, _} <- Switches]),
    mnesia_write(startup, Config#ofconfig{name = startup,
                                          certificates = Certs}),
    {reply, ok, State};
handle_call({delete_config, _SessionId, startup}, _From, State) ->
    delete_startup(),
    {reply, ok, State};
handle_call({get, _SessionId, _Filter}, _From,
            #state{certificates = Certs} = State) ->
    ConfigAndState = get_state(Certs),
    EncodedConfigAndState = of_config:encode(ConfigAndState),
    {reply, {ok, EncodedConfigAndState}, State};
handle_call(get_certificates, _From, #state{certificates = Certs} = State) ->
    {reply, Certs, State};
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
            mnesia_write(startup, InitialConfig),
            [];
        [#ofconfig{certificates = Certs}] ->
            Certs
    end.

%% @doc Merge configuration from logical switches.
merge(Configs) ->
    merge(Configs, #capable_switch{resources = [],
                                   logical_switches = []}).

merge([], Config) ->
    Config;
merge([{NewResources, NewSwitches} | Rest],
      #capable_switch{resources = Resources,
                      logical_switches = Switches} = Config) ->
    NewConfig = Config#capable_switch{
                  resources = Resources ++ NewResources,
                  logical_switches = Switches ++ NewSwitches},
    merge(Rest, NewConfig).

merge_ofc(Configs) ->
    merge_ofc(Configs, #ofconfig{}).

merge_ofc([], Config) ->
    Config;
merge_ofc([#ofconfig{ports = NewPorts,
                     queues = NewQueues,
                     switches = NewSwitches,
                     controllers = NewCtrls} | Configs],
           #ofconfig{ports = Ports,
                     queues = Queues,
                     switches = Switches,
                     controllers = Ctrls}) ->
    merge_ofc(Configs, #ofconfig{ports = Ports ++ NewPorts,
                                 queues = Queues ++ NewQueues,
                                 switches = Switches ++ NewSwitches,
                                 controllers = Ctrls ++ NewCtrls}).

get_capable_switch_config(running) ->
    Switches = get_linc_logical_switches(),
    Config = merge([convert_before_merge(get_config(Id))
                    || {switch, Id, _} <- Switches]),
    Resources = Config#capable_switch.resources,
    {ok, CapSwitchId} = application:get_env(linc, capable_switch_id),
    OfflineResources = offline_resources(Resources),
    Config#capable_switch{id = CapSwitchId,
                          resources = Resources ++ OfflineResources};
get_capable_switch_config(startup) ->
    Config = merge([convert_before_merge(hd(mnesia_read(startup)))]),
    Resources = Config#capable_switch.resources,
    {ok, CapSwitchId} = application:get_env(linc, capable_switch_id),
    OfflineResources = offline_resources(Resources),
    Config#capable_switch{id = CapSwitchId,
                          resources = Resources ++ OfflineResources}.

offline_resources(OnlineResources) ->
    {ok, AllPorts} = application:get_env(linc, capable_switch_ports),
    {ok, AllQueues} = application:get_env(linc, capable_switch_queues),
    OfflinePorts = lists:filter(fun({port, PortNum, _Opts}) ->
                                        is_port_offline(PortNum,
                                                        OnlineResources)
                                end, AllPorts),
    OfflineQueues = lists:filter(fun({queue, QueueId, _Opts}) ->
                                         is_queue_offline(QueueId,
                                                          OnlineResources)
                                 end, AllQueues),
    OfflinePorts2 = convert_offline_ports(OfflinePorts),
    OfflineQueues2 = convert_offline_queues(OfflineQueues),
    OfflinePorts2 ++ OfflineQueues2.

convert_offline_ports(Ports) ->
    convert_offline_ports(Ports, []).

convert_offline_ports([], Converted) ->
    Converted;
convert_offline_ports([{port, PortNum, _Opts} | Rest], Converted) ->
    ResourceId = "OfflineResource-Port" ++ integer_to_list(PortNum),
    C = #port{resource_id = ResourceId,
              configuration = #port_configuration{
                                 admin_state = down
                                }
             },
    convert_offline_ports(Rest, [C | Converted]).

convert_offline_queues(Queues) ->
    convert_offline_queues(Queues, []).

convert_offline_queues([], Converted) ->
    Converted;
convert_offline_queues([{queue, QueueId, Opts} | Rest], Converted) ->
    ResourceId = "OfflineResource-Queue" ++ integer_to_list(QueueId),
    {min_rate, MinRate} = lists:keyfind(min_rate, 1, Opts),
    {max_rate, MaxRate} = lists:keyfind(max_rate, 1, Opts),
    C = #queue{resource_id = ResourceId,
               properties = #queue_properties{min_rate = MinRate,
                                              max_rate = MaxRate}
              },
    convert_offline_queues(Rest, [C | Converted]).

is_port_offline(_, []) ->
    true;
is_port_offline(PortNum, [#port{resource_id = ResourceId} | Rest]) ->
    case re:run(ResourceId,
                "-Port" ++ integer_to_list(PortNum),
                [{capture, none}]) of
        match ->
            false;
        nomatch ->
            is_port_offline(PortNum, Rest)
    end;
is_port_offline(PortNum, [_Resource | Rest]) ->
    is_port_offline(PortNum, Rest).

is_queue_offline(_, []) ->
    true;
is_queue_offline(QueueId, [#queue{resource_id = ResourceId} | Rest]) ->
    case re:run(ResourceId,
                "-Queue" ++ integer_to_list(QueueId),
                [{capture, none}]) of
        match ->
            false;
        nomatch ->
            is_queue_offline(QueueId, Rest)
    end;
is_queue_offline(QueueId, [_Resource | Rest]) ->
    is_queue_offline(QueueId, Rest).

convert_before_merge(#ofconfig{ports = Ports,
                               queues = Queues,
                               switches = Switches,
                               controllers = Controllers}) ->
    {convert_ports_before_merge(Ports) ++ convert_queues_before_merge(Queues),
     [begin
          LSwitchPorts = filter_switch_resources(SwitchId, Ports),
          LSwitchQueues = filter_switch_resources(SwitchId, Queues),
          #logical_switch{id = "LogicalSwitch" ++ integer_to_list(SwitchId),
                          datapath_id = DatapathId,
                          resources = LSwitchPorts ++ LSwitchQueues,
                          controllers = [C || {_SwitchId, C} <- Controllers]}
      end
      || {switch, SwitchId, DatapathId} <- Switches]}.

filter_switch_resources(SwitchId, Resources) ->
    %% filtermap
    lists:reverse(lists:foldl(
        fun({port, {PortId, SId}, _, _}, Acc) when SId == SwitchId ->
               [{port, resource_id(port, {SId, PortId})}|Acc];
           ({queue, {QueueId, PortId, SId}, _, _}, Acc) when SId == SwitchId ->
               [{queue, resource_id(queue, {SId, PortId, QueueId})}|Acc];
           (_, Acc) ->
               Acc
        end, [], Resources)).

convert_ports_before_merge(Ports) ->
    [#port{resource_id = resource_id(port, {PSwitchId, PortId}),
           configuration = Config,
           features = #port_features{advertised = Features}}
     || {port, {PortId, PSwitchId}, Config, Features} <- Ports].

convert_queues_before_merge(Queues) ->
    [#queue{resource_id = resource_id(queue, {QSwitchId, PortId, QueueId}),
            properties = #queue_properties{min_rate = MinRate,
                                           max_rate = MaxRate}}
     || {queue, {QueueId, PortId, QSwitchId}, MinRate, MaxRate} <- Queues].

resource_id(port, {SwitchId, PortId}) ->
    "LogicalSwitch" ++ integer_to_list(SwitchId) ++
        "-Port" ++ integer_to_list(PortId);
resource_id(queue, {SwitchId, PortId, QueueId}) ->
    "LogicalSwitch" ++ integer_to_list(SwitchId) ++
        "-Port" ++ integer_to_list(PortId) ++
        "-Queue" ++ integer_to_list(QueueId).

op(Default, undefined) ->
    Default;
op(_, New) ->
    New.

extract_operations(#capable_switch{resources = Resources,
                                   logical_switches = Switches}, DefOp) ->
    SC = case Switches of
             undefined ->
                 [];
             _ ->
                 [begin
                      SwitchId = extract_id(SwitchIdStr),
                      {case Datapath of
                           undefined ->
                               {none, {switch, SwitchId, undefined}};
                           _ ->
                               {DefOp, {switch, SwitchId, Datapath}}
                       end,
                       case Controllers of
                           undefined ->
                               [];
                           _ ->
                               [{op(DefOp, Op),
                                 {controller, {Id, SwitchId},
                                  IP, Port, tcp, Role}}
                                || #controller{operation = Op,
                                               id = Id,
                                               role = Role,
                                               ip_address = IP,
                                               port = Port} <- Controllers]
                       end}
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
                [{op(DefOp, Op),
                  {port, extract_port_id(ResourceIdStr), Config,
                   case PortFeatures of
                       #port_features{
                          advertised = Features} -> Features;
                       undefined -> undefined
                   end}}
                 || #port{operation = Op,
                          resource_id = ResourceIdStr,
                          configuration = Config,
                          features = PortFeatures} <- Resources]
        end,
    Q = case Resources of
            undefined ->
                [];
            _ ->
                [{op(DefOp, Op),
                  {queue, extract_queue_id(ResourceIdStr), MinRate, MaxRate}}
                 || #queue{operation = Op,
                           resource_id = ResourceIdStr,
                           properties = #queue_properties{
                                           min_rate = MinRate,
                                           max_rate = MaxRate}} <- Resources]
        end,
    Crt = case Resources of
              undefined ->
                  [];
              _ ->
                  [{op(DefOp, Op),
                    {certificate, CertId, CertBin}}
                   || #certificate{operation = Op,
                                   type = external,
                                   resource_id = CertId,
                                   certificate = CertBin} <- Resources]
          end,
    P ++ Q ++ S ++ C ++ Crt.
    
extract_id(String) ->
    case re:run(String, "^LogicalSwitch[0-9]+$") of
        {match, _} ->
            list_to_integer(string:sub_string(String, 14));
        nomatch ->
            invalid
    end.

extract_port_id(String) ->
    case re:run(String, "^LogicalSwitch([0-9]+)-Port([0-9]+)$",
                [{capture, all_but_first, list}]) of
        {match, [SwitchIdStr, PortIdStr]} ->
            PortId = list_to_integer(PortIdStr),
            SwitchId = list_to_integer(SwitchIdStr),
            case linc_logic:is_port_valid(SwitchId, PortId) of
                true ->
                    {PortId, SwitchId};
                false ->
                    invalid
            end;
        nomatch ->
            invalid
    end.

extract_queue_id(String) ->
    case re:run(String, "^LogicalSwitch([0-9]+)-Port([0-9]+)-Queue([0-9]+)$",
                [{capture, all_but_first, list}]) of
        {match, [SwitchIdStr, PortIdStr, QueueIdStr]} ->
            QueueId = list_to_integer(QueueIdStr),
            PortId = list_to_integer(PortIdStr),
            SwitchId = list_to_integer(SwitchIdStr),
            case linc_logic:is_queue_valid(SwitchId, PortId, QueueId) of
                true ->
                    {QueueId, PortId, SwitchId};
                false ->
                    invalid
            end;
        nomatch ->
            invalid
    end.

execute_operations(Ops, OnError, startup, Certs) ->
    [Startup] = mnesia_read(startup),
    {Result, NewStartup} = do_startup(Ops, OnError, Startup),
    mnesia_write(startup, NewStartup),
    {Result, Certs};
execute_operations(Ops, OnError, running, Certs) ->
    do_running(Ops, OnError, Certs).

do_running([], stop, Certs) ->
    {ok, Certs};
do_running([], {continue, []}, Certs) ->
    {ok, Certs};
do_running([], {continue, Errors}, Certs) ->
    {{error, lists:reverse(Errors)}, Certs};
do_running([{_, {port, invalid, _, _}} | Rest], OnError, Certs) ->
    handle_running_error(data_missing, OnError, Rest, Certs);
do_running([{_, {queue, invalid, _, _}} | Rest], OnError, Certs) ->
    handle_running_error(data_missing, OnError, Rest, Certs);
do_running([{_, {switch, invalid, _}} | Rest], OnError, Certs) ->
    handle_running_error(data_missing, OnError, Rest, Certs);
do_running([{_, {controller, invalid, _, _, _}} | Rest], OnError, Certs) ->
    handle_running_error(data_missing, OnError, Rest, Certs);
do_running([{none, _} | Rest], OnError, Certs) ->
    do_running(Rest, OnError, Certs);
do_running([{Op, {port, {PortId, SwitchId},
                  Config, Features}} | Rest], OnError, Certs) ->
    case Op of
        Op when Op == create orelse Op == delete ->
            handle_running_error({operation_not_supported, protocol},
                                 OnError, Rest, Certs);
        remove ->
            do_running(Rest, OnError, Certs);
        _ ->
            linc_logic:set_port_config(SwitchId, PortId, Config),
            linc_logic:set_port_features(SwitchId, PortId, Features),
            do_running(Rest, OnError, Certs)
    end;
do_running([{Op, {queue, {QueueId, PortId, SwitchId},
                  MinRate, MaxRate}} | Rest], OnError, Certs) ->
    case Op of
        Op when Op == create orelse Op == delete ->
            handle_running_error({operation_not_supported, protocol},
                                 OnError, Rest, Certs);
        remove ->
            do_running(Rest, OnError, Certs);
        _ ->
            linc_logic:set_queue_min_rate(SwitchId, PortId, QueueId, MinRate),
            linc_logic:set_queue_max_rate(SwitchId, PortId, QueueId, MaxRate),
            do_running(Rest, OnError, Certs)
    end;
do_running([{Op, {switch, SwitchId, DatapathId}} | Rest], OnError, Certs) ->
    case Op of
        Op when Op == create orelse Op == delete ->
            handle_running_error({operation_not_supported, protocol},
                                 OnError, Rest, Certs);
        remove ->
            do_running(Rest, OnError, Certs);
        _ ->
            linc_logic:set_datapath_id(SwitchId, DatapathId),
            do_running(Rest, OnError, Certs)
    end;
do_running([{Op, {controller, {ControllerId, SwitchId},
                  Host, Port, Proto, Role}} | Rest], OnError, Certs) ->
    Host2 = case Host of
                undefined -> "localhost";
                _ -> Host
            end,
    Port2 = case Port of
                undefined -> 6633;
                _ -> Port
            end,
    Proto2 = case Proto of
                 undefined -> tls;
                 _ -> Proto
             end,
    case Op of
        create ->
            case is_valid_controller(SwitchId, ControllerId) of
                {true, _} ->
                    handle_running_error(data_exists, OnError, Rest, Certs);
                false ->
                    linc_logic:open_controller(SwitchId, ControllerId,
                                               Host2, Port2, Proto2),
                    do_running(Rest, OnError, Certs)
            end;
        delete ->
            case is_valid_controller(SwitchId, ControllerId) of
                {true, Pid} ->
                    catch ofp_client:stop(Pid),
                    do_running(Rest, OnError, Certs);
                false ->
                    handle_running_error(data_missing, OnError, Rest, Certs)
            end;
        remove ->
            case is_valid_controller(SwitchId, ControllerId) of
                {true, Pid} ->
                    catch ofp_client:stop(Pid),
                    do_running(Rest, OnError, Certs);
                false ->
                    do_running(Rest, OnError, Certs)
            end;
        Op when Op == merge orelse Op == replace ->
            case is_valid_controller(SwitchId, ControllerId) of
                {true, Pid} ->
                    Config = [ X || {_, Val} = X <- lists:zip(
                                                      [ip, port, protocol, role],
                                                      [Host, Port, Proto, Role]),
                                    Val /= undefined],
                    ofp_client:update_connection_config(Pid, Config),
                    do_running(Rest, OnError, Certs);
                false ->
                    linc_logic:open_controller(SwitchId, ControllerId,
                                               Host2, Port2, Proto2),
                    do_running(Rest, OnError, Certs)
            end
    end;
do_running([{Op, {certificate, CertId, CertBin}} | Rest], OnError, Certs) ->
    case Op of
        create ->
            case lists:keyfind(CertId, 1, Certs) of
                false ->
                    do_running(Rest, OnError, [{CertId, CertBin} | Certs]);
                _ ->
                    handle_running_error(data_exists, OnError, Rest, Certs)
            end;
        delete ->
            case lists:keyfind(CertId, 1, Certs) of
                false ->
                    handle_running_error(data_missing, OnError, Rest, Certs);
                _ ->
                    do_running(Rest, OnError,
                               lists:delete({CertId, CertBin}, Certs))
            end;
        remove ->
            case lists:keyfind(CertId, 1, Certs) of
                false ->
                    do_running(Rest, OnError, Certs);
                _ ->
                    do_running(Rest, OnError,
                               lists:delete({CertId, CertBin}, Certs))
            end;
        Op when Op == merge orelse Op == replace ->
            case lists:keyfind(CertId, 1, Certs) of
                false ->
                    do_running(Rest, OnError, [{CertId, CertBin} | Certs]);
                _ ->
                    do_running(Rest, OnError,
                               lists:keyreplace(CertId, 1, Certs,
                                                {CertId, CertBin}))
            end
    end.

is_valid_controller(SwitchId, ControllerId) ->
    Ids = ofp_client:get_resource_ids(SwitchId),
    case lists:keyfind(ControllerId, 2, Ids) of
        false ->
            false;
        {Pid, _} ->
            {true, Pid}
    end.

handle_running_error(Error, OnError, Rest, Certs) ->
    case OnError of
        stop ->
            {{error, [Error]}, Certs};
        {continue, Errors} ->
            do_running(Rest, {continue, [Error | Errors]}, Certs)
    end.

do_startup([], stop, Startup) ->
    {ok, Startup};
do_startup([], {continue, []}, Startup) ->
    {ok, Startup};
do_startup([], {continue, Errors}, Startup) ->
    {{error, lists:reverse(Errors)}, Startup};
do_startup([{_, {port, invalid, _, _}} | Rest], OnError, Startup) ->
    handle_startup_error(data_missing, OnError, Rest, Startup);
do_startup([{_, {queue, invalid, _, _}} | Rest], OnError, Startup) ->
    handle_startup_error(data_missing, OnError, Rest, Startup);
do_startup([{_, {switch, invalid, _}} | Rest], OnError, Startup) ->
    handle_startup_error(data_missing, OnError, Rest, Startup);
do_startup([{_, {controller, invalid, _, _, _}} | Rest], OnError, Startup) ->
    handle_startup_error(data_missing, OnError, Rest, Startup);
do_startup([{none, _} | Rest], OnError, Startup) ->
    do_startup(Rest, OnError, Startup);
do_startup([{Op, {port, PortId, _, _} = Port} | Rest], OnError,
           #ofconfig{ports = Ports} = Startup) ->
    case Op of
        Op when Op == create orelse Op == delete ->
            handle_startup_error({unsupported_operation, protocol},
                                 OnError, Rest, Startup);
        remove ->
            do_startup(Rest, OnError, Startup);
        Op when Op == merge orelse Op == replace ->
            NewPorts = lists:keyreplace(PortId, 2, Ports, Port),
            do_startup(Rest, OnError, Startup#ofconfig{ports = NewPorts})
    end;
do_startup([{Op, {queue, QueueId, _, _} = Queue} | Rest], OnError,
           #ofconfig{queues = Queues} = Startup) ->
    case Op of
        Op when Op == create orelse Op == delete ->
            handle_startup_error({unsupported_operation, protocol},
                                 OnError, Rest, Startup);
        remove ->
            do_startup(Rest, OnError, Startup);
        Op when Op == merge orelse Op == replace ->
            NewQueues = lists:keyreplace(QueueId, 2, Queues, Queue),
            do_startup(Rest, OnError, Startup#ofconfig{queues = NewQueues})
    end;
do_startup([{Op, {switch, SwitchId, _} = Switch} | Rest], OnError,
           #ofconfig{switches = Switches} = Startup) ->
    case Op of
        Op when Op == create orelse Op == delete ->
            handle_startup_error({unsupported_operation, protocol},
                                 OnError, Rest, Startup);
        remove ->
            do_startup(Rest, OnError, Startup);
        Op when Op == merge orelse Op == replace ->
            NewSwitches = lists:keyreplace(SwitchId, 2, Switches, Switch),
            do_startup(Rest, OnError, Startup#ofconfig{switches = NewSwitches})
    end;
do_startup([{Op, {controller, CtrlId, _, _, _, _} = Ctrl} | Rest], OnError,
           #ofconfig{controllers = Ctrls} = Startup) ->
    case Op of
        create ->
            case lists:keyfind(CtrlId, 2, Ctrls) of
                false ->
                    do_startup(Rest, OnError,
                               Startup#ofconfig{controllers = [Ctrl | Ctrls]});
                _ ->
                    handle_startup_error(data_exists, OnError, Rest, Startup)
            end;
        delete ->
            case lists:keyfind(CtrlId, 2, Ctrls) of
                false ->
                    handle_startup_error(data_missing, OnError, Rest, Startup);
                _ ->
                    NewCtrls = lists:keyremove(CtrlId, 2, Ctrls),
                    do_startup(Rest, OnError,
                               Startup#ofconfig{controllers = NewCtrls})
            end;
        remove ->
            case lists:keyfind(CtrlId, 2, Ctrls) of
                false ->
                    do_startup(Rest, OnError, Startup);
                _ ->
                    NewCtrls = lists:keyremove(CtrlId, 2, Ctrls),
                    do_startup(Rest, OnError,
                               Startup#ofconfig{controllers = NewCtrls})
            end;
        Op when Op == merge orelse Op == replace ->
            case lists:keyfind(CtrlId, 2, Ctrls) of
                false ->
                    do_startup(Rest, OnError,
                               Startup#ofconfig{controllers = [Ctrl | Ctrls]});
                _ ->
                    NewCtrls = lists:keyreplace(CtrlId, 2, Ctrls, Ctrl),
                    do_startup(Rest, OnError,
                               Startup#ofconfig{controllers = NewCtrls})
            end
    end;
do_startup([{Op, {certificate, CertId, CertBin}} | Rest], OnError,
           #ofconfig{certificates = Certs} = Startup) ->
    case Op of
        create ->
            case lists:keyfind(CertId, 1, Certs) of
                false ->
                    do_startup(Rest, OnError,
                               Startup#ofconfig{
                                 certificates = [{CertId, CertBin} | Certs]});
                _ ->
                    handle_startup_error(data_exists, OnError, Rest, Startup)
            end;
        delete ->
            case lists:keyfind(CertId, 1, Certs) of
                false ->
                    handle_startup_error(data_missing, OnError, Rest, Startup);
                _ ->
                    NewCerts = lists:keyremove(CertId, 1, Certs),
                    do_startup(Rest, OnError,
                               Startup#ofconfig{certificates = NewCerts})
            end;
        remove ->
            case lists:keyfind(CertId, 1, Certs) of
                false ->
                    do_startup(Rest, OnError, Startup);
                _ ->
                    NewCerts = lists:keyremove(CertId, 1, Certs),
                    do_startup(Rest, OnError,
                               Startup#ofconfig{certificates = NewCerts})
            end;
        Op when Op == merge orelse Op == replace ->
            case lists:keyfind(CertId, 1, Certs) of
                false ->
                    do_startup(Rest, OnError,
                               Startup#ofconfig{
                                 certificates = [{CertId, CertBin} | Certs]});
                _ ->
                    NewCerts = lists:keyreplace(CertId, 1, Certs, {CertId,
                                                                   CertBin}),
                    do_startup(Rest, OnError,
                               Startup#ofconfig{certificates = NewCerts})
            end
    end.

handle_startup_error(Error, OnError, Rest, Startup) ->
    case OnError of
        stop ->
            {{error, [Error]}, Startup};
        {continue, Errors} ->
            do_startup(Rest, {continue, [Error | Errors]}, Startup)
    end.

mnesia_read(startup) ->
    mnesia:dirty_read(?STARTUP, startup).

mnesia_write(startup, Config) ->
    mnesia:dirty_write(?STARTUP, Config).

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

get_logical_switch_controllers(SwitchId) ->
    lists:foldl(fun(#controller_status{
                       resource_id = ResourceId,
                       role = Role,
                       controller_ip = ControllerIP,
                       controller_port = ControllerPort,
                       local_ip = LocalIP,
                       local_port = LocalPort,
                       protocol = Protocol,
                       connection_state = ConnectionState,
                       current_version = CurrentVersion,
                       supported_versions = SupportedVersions}, Controllers) ->
                        C = #controller{
                               id = ResourceId,
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
                                         }},
                        [C | Controllers]
                end, [], ofp_client:get_controllers_state(SwitchId)).

get_controllers(SwitchId) ->
    [{SwitchId, C} || C <- get_logical_switch_controllers(SwitchId)].

update_switches([], _, New) ->
    New;
update_switches([{switch, SwitchId, Opts} | Rest],
                #ofconfig{ports = OldPorts,
                          queues = OldQueues,
                          switches = OldSwitches,
                          controllers = OldCtrls} = Startup,
                {NewConfig, #ofconfig{switches = NewSwitches} = NewStartup}) ->
    Ports = case lists:keyfind(ports, 1, Opts) of
                {ports, P} -> P;
                false -> []
            end,
    Ctrls = case lists:keyfind(controllers, 1, Opts) of
                {controllers, C} -> C;
                false -> []
            end,
    Queues = case lists:keyfind(queues_status, 1, Opts) of
                 {queues_status, enabled} ->
                     case lists:keyfind(queues, 1, Opts) of
                         {queues, Q} -> Q;
                         false -> []
                     end;
                 _ -> []
             end,
    {NewQueues, NewStartup2} = update_queues(Queues, SwitchId, OldQueues,
                                             {[], NewStartup}),
    {NewPorts, NewStartup3} = update_ports(Ports, NewQueues, SwitchId, OldPorts,
                                           {[], NewStartup2}),
    NewCtrls = update_controllers(Ctrls, SwitchId, OldCtrls),

    NewOpts = lists:keyreplace(ports, 1, Opts, {ports, NewPorts}),
    NewOpts2 = lists:keyreplace(queues, 1, NewOpts, {queues, NewQueues}),
    NewOpts3 = lists:keyreplace(controllers, 1,
                                NewOpts2, {controllers, NewCtrls}),

    DatapathId = case lists:keyfind(SwitchId, 2, OldSwitches) of
                     {switch, _, D} -> D;
                     false -> get_datapath_id(SwitchId, Opts)
                 end,
    update_switches(Rest, Startup,
                    {[{switch, SwitchId,
                       [{datapath_id, DatapathId} | NewOpts3]} | NewConfig],
                     NewStartup3#ofconfig{
                       switches = [{switch, SwitchId, DatapathId}
                                   | NewSwitches],
                       controllers = OldCtrls}}).

update_ports([], _, _, _, New) ->
    New;
update_ports([{port, PortId, Opts} | Rest], Queues, SwitchId, OldPorts,
             {NewPorts, #ofconfig{ports = NewSPorts} = NewStartup}) ->
    {NP, NSP} = case lists:keyfind({PortId, SwitchId}, 2, OldPorts) of
                    {port, _, Config, Features} = P ->
                        {{port, PortId,
                          [{config, Config},
                           {features, Features},
                           {queues, Queues} | Opts]}, P};
                    false ->
                        {{port, PortId,
                          [{config, ?DEFAULT_PORT_CONFIG},
                           {features, ?DEFAULT_PORT_FEATURES} | Opts]},
                         {port, {PortId, SwitchId},
                          ?DEFAULT_PORT_CONFIG,
                          ?DEFAULT_PORT_FEATURES}}
                end,
    update_ports(Rest, Queues, SwitchId, OldPorts,
                 {[NP | NewPorts],
                  NewStartup#ofconfig{ports = [NSP | NewSPorts]}}).

update_queues([], _, _, New) ->
    New;
update_queues([{port, PortId, Opts} | Rest], SwitchId, OldQueues,
              {NewQueues, NewStartup}) ->
    case lists:keyfind(port_queues, 1, Opts) of
        {port_queues, Queues} ->
            {NQ, NS} = update_queues2(Queues, PortId, SwitchId,
                                      OldQueues, {[], NewStartup}),
            NewOpts = lists:keyreplace(port_queues, 1, Opts,
                                       {port_queues, NQ}),
            update_queues(Rest, SwitchId, OldQueues,
                          {[{port, PortId, NewOpts} | NewQueues], NS});
        false ->
            update_queues(Rest, SwitchId, OldQueues, {NewQueues, NewStartup})
    end.

update_queues2([], _, _, _, New) ->
    New;
update_queues2([{QueueId, Opts} | Rest], PortId, SwitchId, OldQueues,
               {NewQueues, #ofconfig{queues = NewSQueues} = NewStartup}) ->
    {NQ, NSQ} = case lists:keyfind({QueueId, PortId, SwitchId}, 2, OldQueues) of
                    {queue, _, MinRate, MaxRate} = Q ->
                        {{QueueId, [{min_rate, MinRate},
                                    {max_rate, MaxRate}]}, Q};
                    false ->
                        MinRate = case lists:keyfind(min_rate, 1, Opts) of
                                      {min_rate, MinR} -> MinR;
                                      false -> undefined
                                  end,
                        MaxRate = case lists:keyfind(max_rate, 1, Opts) of
                                      {max_rate, MaxR} -> MaxR;
                                      false -> undefined
                                  end,
                        {{QueueId, Opts},
                         {queue, {QueueId, PortId, SwitchId},
                          MinRate, MaxRate}}
                end,
    update_queues2(Rest, PortId, SwitchId, OldQueues,
                   {[NQ | NewQueues],
                    NewStartup#ofconfig{queues = [NSQ | NewSQueues]}}).

update_controllers(Ctrls, SwitchId, OldCtrls) ->
    OldCtrls2 = [Controller || {SId, #controller{} = Controller} <- OldCtrls,
                               SId == SwitchId],
    Ctrls ++ OldCtrls2.

logical_switch_port_rate(PortConfig) ->
    case lists:keyfind(port_rate, 1, PortConfig) of
        false ->
            {port_rate, ?DEFAULT_PORT_RATE};
        R ->
            R
    end.

assure_datapath_id_in_logical_switch_config({switch, SwitchId, Opts}) ->
    case lists:keyfind(datapath_id, 1, Opts) of
        false ->
            {switch, SwitchId,
             [{datapath_id, linc_logic:gen_datapath_id(SwitchId)}
              | Opts]};
        _Datapath_Id ->
            {switch, SwitchId, Opts}
    end.

convert_logical_switch_ports({switch, SwitchId, LogicalSwitchConfig}) ->
    LogicalPorts = proplists:get_value(ports, LogicalSwitchConfig),
    StartupLogicalPorts =
        lists:foldl(fun(LogicalPort, Acc) ->
                            [create_startup_logical_port(LogicalPort) | Acc]
                    end, [], LogicalPorts),
    {switch, SwitchId, lists:keyreplace(ports, 1, LogicalSwitchConfig,
                                        {ports, StartupLogicalPorts})}.

create_startup_logical_port({port, PortId, CapablePortConfig}) ->
    logical_switch_default_startup_port_config(PortId, CapablePortConfig).

logical_switch_default_startup_port_config(PortId, CapablePortConfig) ->
    {port, PortId, [{config, ?DEFAULT_PORT_CONFIG},
                    {features, ?DEFAULT_PORT_FEATURES}
                    | CapablePortConfig]}.


%%------------------------------------------------------------------------------
%% Helper conversion functions
%%------------------------------------------------------------------------------

rate(['10mb_hd' | _]) ->
    '10Mb-HD';
rate(['10mb_fd' | _]) ->
    '10Mb-FD';
rate(['100mb_hd' | _]) ->
    '100Mb-HD';
rate(['100mb_fd' | _]) ->
    '100Mb-FD';
rate(['1gb_hd' | _]) ->
    '1Gb-HD';
rate(['1gb_fd' | _]) ->
    '1Gb-FD';
rate(['10gb_fd' | _]) ->
    '10Gb';
rate(['40gb_fd' | _]) ->
    '40Gb';
rate(['100gb_fd' | _]) ->
    '100Gb';
rate(['1tb_fd' | _]) ->
    '1Tb';
rate([_OtherFeature | Rest]) ->
    rate(Rest);
rate([]) ->
    other.

ip(undefined) ->
    undefined;
ip(String) when is_list(String) ->
    String;
ip({A, B, C, D}) ->
    integer_to_list(A) ++ "."
        ++ integer_to_list(B) ++ "."
        ++ integer_to_list(C) ++ "."
        ++ integer_to_list(D).

version(undefined) ->
    undefined;
version(1) ->
    '1.0';
version(2) ->
    '1.1';
version(3) ->
    '1.2';
version(4) ->
    '1.3';
version(5) ->
    '1.4'.

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

convert_certificates(Certs) ->
    lists:map(fun({Id, Bin}) ->
                      #certificate{resource_id = Id,
                                   type = external,
                                   certificate = Bin,
                                   private_key = undefined}
              end, Certs).

translate(List) ->
    translate(List, []).

translate([], Acc) ->
    lists:reverse(Acc);
translate([{Value, Indicator, Atom} | Rest], Acc) ->
    case Value == Indicator of
        true ->
            translate(Rest, [Atom | Acc]);
        false ->
            translate(Rest, Acc)
    end.

get_datapath_id(SwitchId, SwitchOpts) ->
    case lists:keyfind(Key = datapath_id, 1, SwitchOpts) of
        false ->
            linc_logic:gen_datapath_id(SwitchId);
        {Key, Dpid} ->
            Dpid
    end.
