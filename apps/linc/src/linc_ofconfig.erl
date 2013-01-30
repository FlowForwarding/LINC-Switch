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
         get_state/0,
         get_state/1,
         get_config/1,
         flow_table_name/3,
         convert_port_config/1,
         convert_port_features/4,
         convert_port_state/1,
         read_and_update_startup/0]).

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

-define(DEFAULT_PORT_CONFIG, #port_configuration{
                                admin_state = up,
                                no_receive = false,
                                no_forward = false,
                                no_packet_in = false}).
-define(DEFAULT_PORT_FEATURES, #features{
                                  rate = '100mb-fd',
                                  auto_negotiate = true,
                                  medium = copper,
                                  pause = unsupported}).
-define(DEFAULT_DATAPATH(SwitchId),
        if
            SwitchId < 10 -> "AA:BB:CC:DD:EE:FF:00:0" ++
                                 integer_to_list(SwitchId);
            SwitchId < 100 -> "AA:BB:CC:DD:EE:FF:00:" ++
                                  integer_to_list(SwitchId);
            SwitchId < 1000 -> "AA:BB:CC:DD:EE:FF:0" ++
                                   integer_to_list(SwitchId div 100) ++
                                   ":" ++ integer_to_list(SwitchId rem 100);
            SwitchId < 10000 -> "AA:BB:CC:DD:EE:FF:" ++
                                    integer_to_list(SwitchId div 100) ++
                                    ":" ++ integer_to_list(SwitchId rem 100)
        end).

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

-spec get_state() -> #capable_switch{}.
get_state() ->
    {ok, Switches} = application:get_env(linc, logical_switches),
    Config = merge([get_state(Id) || {switch, Id, _} <- Switches]),
    {ok, CapSwitchId} = application:get_env(linc, capable_switch_id),
    Config#capable_switch{id = CapSwitchId}.

-spec get_state(integer()) -> tuple(list(resource()), #logical_switch{}).
get_state(SwitchId) ->
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
                       capabilities = linc_logic:get_backend_capabilities(SwitchId),
                       controllers = get_controllers(SwitchId),
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
    Controllers = lists:map(fun(#controller{id = ControllerId,
                                            ip_address = IPAddress,
                                            port = Port,
                                            protocol = Protocol}) ->
                                    {controller, {ControllerId, SwitchId},
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

delete_startup() ->
    {ok, Sys} = application:get_env(linc, logical_switches),
    NewStartup = delete_startup_switches(Sys, #ofconfig{name = startup}),
    mnesia_write(startup, NewStartup).

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
                                [[begin
                                      MinRate = case lists:keyfind(min_rate,
                                                                   1, Props) of
                                                    {min_rate, MinR} -> MinR;
                                                    false -> undefined
                                                end,
                                      MaxRate = case lists:keyfind(max_rate,
                                                                   1, Props) of
                                                    {max_rate, MaxR} -> MaxR;
                                                    false -> undefined
                                                end,
                                      {queue, {QueueId, PortId, SwitchId},
                                       MinRate, MaxRate}
                                  end
                                  || {QueueId, Props} <- lists:keyfind(
                                                           port_queues,
                                                           1, SysQueues)]
                                 || {port, PortId, SysQueues} <- SysQPorts]
                        end;
                    _ ->
                        []
                end,
    NewCtrls = [],
    NewSwitch = {switch, SwitchId, ?DEFAULT_DATAPATH(SwitchId)},
    NewStartup = Startup#ofconfig{ports = Ports ++ NewPorts,
                                  queues = Queues ++ lists:flatten(NewQueues),
                                  switches = [NewSwitch | Switches],
                                  controllers = Ctrls ++ NewCtrls},
    delete_startup_switches(Rest, NewStartup).

read_and_update_startup() ->
    [Startup] = mnesia_read(startup),
    {ok, Sys} = application:get_env(linc, logical_switches),
    InitNew = {[], #ofconfig{name = startup}},
    {Config, NewStartup} = update_switches(Sys, Startup, InitNew),
    mnesia_write(startup, NewStartup),
    Config.

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
    {NewPorts, NewStartup2} = update_ports(Ports, SwitchId, OldPorts,
                                           {[], NewStartup}),
    {NewQueues, NewStartup3} = update_queues(Queues, SwitchId, OldQueues,
                                             {[], NewStartup2}),
    NewCtrls = update_controllers(Ctrls, SwitchId, OldCtrls),

    NewOpts = lists:keyreplace(ports, 1, Opts, {ports, NewPorts}),
    NewOpts2 = lists:keyreplace(queues, 1, NewOpts, {queues, NewQueues}),
    NewOpts3 = lists:keyreplace(controllers, 1,
                                NewOpts2, {controllers, NewCtrls}),

    DatapathId = case lists:keyfind(SwitchId, 2, OldSwitches) of
                     {switch, _, D} -> D;
                     false -> ?DEFAULT_DATAPATH(SwitchId)
                 end,
    update_switches(Rest, Startup,
                    {[{switch, SwitchId,
                       [{datapath_id, DatapathId} | NewOpts3]} | NewConfig],
                     NewStartup3#ofconfig{
                       switches = [{switch, SwitchId, DatapathId}
                                   | NewSwitches]}}).

update_ports([], _, _, New) ->
    New;
update_ports([{port, PortId, Opts} | Rest], SwitchId, OldPorts,
             {NewPorts, #ofconfig{ports = NewSPorts} = NewStartup}) ->
    {NP, NSP} = case lists:keyfind({PortId, SwitchId}, 2, OldPorts) of
                    {port, _, Config, Features} = P ->
                        {{port, PortId,
                          [{config, Config},
                           {features, Features} | Opts]}, P};
                    false ->
                        {{port, PortId,
                          [{config, ?DEFAULT_PORT_CONFIG},
                           {features, ?DEFAULT_PORT_FEATURES} | Opts]},
                         {port, {PortId, SwitchId},
                          ?DEFAULT_PORT_CONFIG,
                          ?DEFAULT_PORT_FEATURES}}
                end,
    update_ports(Rest, SwitchId, OldPorts,
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
    OldCtrls2 = [{ControllerId, Host, Port} || {controller, {ControllerId, SId},
                                  Host, Port, _} <- OldCtrls, SId == SwitchId],
    Ctrls ++ OldCtrls2.

%%------------------------------------------------------------------------------
%% gen_netconf callbacks
%%------------------------------------------------------------------------------

handle_get_config(SessionId, Source, Filter) ->
    gen_server:call(?MODULE,
                    {get_config, SessionId, Source, Filter}, infinity).

handle_edit_config(SessionId, Target, Config) ->
    gen_server:call(?MODULE,
                    {edit_config, SessionId, Target, Config}, infinity).

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
    init_startup(),
    {ok, #state{}}.

handle_call({get_config, _SessionId, Source, _Filter}, _From, State)
  when Source == running orelse Source == startup ->
    Config = get_capable_switch_config(Source),
    EncodedConfig = of_config:encode(Config),
    {reply, {ok, EncodedConfig}, State};
handle_call({edit_config, _SessionId, startup, {xml, Xml}}, _From, State) ->
    Config = of_config:decode(Xml),
    case check_capable_switch_id(Config#capable_switch.id) of
        true ->
            case catch execute_operations(extract_operations(Config, merge),
                                          stop, startup) of
                ok ->
                    {reply, ok, State};
                {error, Errors} when is_list(Errors) ->
                    {reply, {error, hd(Errors)}, State};
                {error, Error} ->
                    {reply, {error, Error}, State}
            end;
        false ->
            {reply, {error, data_missing}, State}
    end;
handle_call({copy_config, _SessionId, running, startup}, _From, State) ->
    {ok, Switches} = application:get_env(linc, logical_switches),
    Config = merge_ofc([get_config(Id) || {switch, Id, _} <- Switches]),
    mnesia_write(startup, Config#ofconfig{name = startup}),
    {reply, ok, State};
handle_call({delete_config, _SessionId, startup}, _From, State) ->
    delete_startup(),
    {reply, ok, State};
handle_call({get, _SessionId, _Filter}, _From, State) ->
    ConfigAndState = get_state(),
    EncodedConfigAndState = of_config:encode(ConfigAndState),
    {reply, {ok, EncodedConfigAndState}, State};
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
    {ok, Switches} = application:get_env(linc, logical_switches),
    Config = merge([convert_before_merge(get_config(Id))
                    || {switch, Id, _} <- Switches]),
    {ok, CapSwitchId} = application:get_env(linc, capable_switch_id),
    Config#capable_switch{id = CapSwitchId};
get_capable_switch_config(startup) ->
    Config = merge([convert_before_merge(hd(mnesia_read(startup)))]),
    {ok, CapSwitchId} = application:get_env(linc, capable_switch_id),
    Config#capable_switch{id = CapSwitchId}.

convert_before_merge(#ofconfig{ports = Ports,
                               queues = Queues,
                               switches = Switches,
                               controllers = Controllers}) ->
    {[#port{resource_id = "LogicalSwitch" ++ integer_to_list(PSwitchId) ++
                "-Port" ++ integer_to_list(PortId),
            configuration = Config,
            features = #port_features{advertised = Features}}
      || {port, {PortId, PSwitchId}, Config, Features} <- Ports] ++
         [#queue{resource_id = "LogicalSwitch" ++ integer_to_list(QSwitchId) ++
                     "-Port" ++ integer_to_list(PortId) ++
                     "-Queue" ++ integer_to_list(QueueId),
                 properties = #queue_properties{min_rate = MinRate,
                                                max_rate = MaxRate}}
          || {queue, {QueueId, PortId, QSwitchId}, MinRate, MaxRate} <- Queues],
     [#logical_switch{id = "LogicalSwitch" ++ integer_to_list(SwitchId),
                      datapath_id = DatapathId,
                      controllers =
                          [#controller{id = Id,
                                       ip_address = Host,
                                       port = Port,
                                       protocol = Protocol}
                           || {controller, {Id, CSwitchId},
                               Host, Port, Protocol} <- Controllers,
                              CSwitchId == SwitchId]}
      || {switch, SwitchId, DatapathId} <- Switches]}.

extract_operations(#capable_switch{resources = Resources,
                                   logical_switches = Switches}, DefOp) ->
    SC = case Switches of
             undefined ->
                 [];
             _ ->
                 [begin
                      SwitchId = extract_id(SwitchIdStr),
                      {{DefOp, {switch, SwitchId, Datapath}},
                       case Controllers of
                           undefined ->
                               [];
                           _ ->
                               [{DefOp, {controller, {Id, SwitchId},
                                         IP, Port, Proto}}
                                || #controller{id = Id,
                                               ip_address = IP,
                                               port = Port,
                                               protocol = Proto} <- Controllers]
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
                [{DefOp, {port, extract_port_id(ResourceIdStr),
                          Config, Features}}
                 || #port{resource_id = ResourceIdStr,
                          configuration = Config,
                          features = #port_features{
                                        advertised = Features}} <- Resources]
        end,
    Q = case Resources of
            undefined ->
                [];
            _ ->
                [{DefOp, {queue, extract_queue_id(ResourceIdStr),
                          MinRate, MaxRate}}
                 || #queue{resource_id = ResourceIdStr,
                           properties = #queue_properties{
                                           min_rate = MinRate,
                                           max_rate = MaxRate}} <- Resources]
        end,
    P ++ Q ++ S ++ C.
    
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
                    {invalid, invalid, invalid}
            end;
        nomatch ->
            {invalid, invalid, invalid}
    end.

execute_operations(Ops, OnError, startup) ->
    [Startup] = mnesia_read(startup),
    {Result, NewStartup} = do_startup(Ops, case OnError of
                                               stop -> stop;
                                               continue -> {continue, []}
                                           end, Startup),
    mnesia_write(startup, NewStartup),
    Result.
    
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
            handle_startup_error(unsupported_operation, OnError, Rest, Startup);
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
            handle_startup_error(unsupported_operation, OnError, Rest, Startup);
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
            handle_startup_error(unsupported_operation, OnError, Rest, Startup);
        remove ->
            do_startup(Rest, OnError, Startup);
        Op when Op == merge orelse Op == replace ->
            NewSwitches = lists:keyreplace(SwitchId, 2, Switches, Switch),
            do_startup(Rest, OnError, Startup#ofconfig{switches = NewSwitches})
    end;
do_startup([{Op, {controller, CtrlId, _, _, _} = Ctrl} | Rest], OnError,
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

get_controllers(SwitchId) ->
    lists:foldl(fun(controller_not_connected, Controllers) ->
                        Controllers;
                   ({ResourceId, Role,
                     {ControllerIP, ControllerPort},
                     {LocalIP, LocalPort},
                     Protocol, ConnectionState,
                     CurrentVersion, SupportedVersions}, Controllers) ->
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
