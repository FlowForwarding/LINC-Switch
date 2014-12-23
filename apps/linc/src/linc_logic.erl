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
%% @doc OpenFlow Logical Switch logic.
-module(linc_logic).

-behaviour(gen_server).

%% API
-export([send_to_controllers/2,
         gen_datapath_id/1,
         %% Backend general
         get_datapath_id/1,
         set_datapath_id/2,
         get_backend_flow_tables/1,
         get_backend_capabilities/1,
         %% Backend ports
         get_backend_ports/1,
         get_port_config/2,
         set_port_config/3,
         get_port_features/2,
         set_port_features/3,
         is_port_valid/2,
         %% Backend queues
         get_backend_queues/1,
         get_queue_min_rate/3,
         set_queue_min_rate/4,
         get_queue_max_rate/3,
         set_queue_max_rate/4,
         is_queue_valid/3,
         %% Controllers
         open_controller/5
        ]).

%% Internal API
-export([start_link/4]).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-include_lib("of_protocol/include/of_protocol.hrl").
-include_lib("of_config/include/of_config.hrl").
-include("linc_logger.hrl").

-record(state, {
          xid = 1 :: integer(),
          backend_mod :: atom(),
          ofconfig_backend_mod :: atom(),
          backend_state :: term(),
          switch_id :: integer(),
          datapath_id :: string(),
          config :: term(),
          version :: integer()
         }).

%%------------------------------------------------------------------------------
%% API functions
%%------------------------------------------------------------------------------

%% @doc Send message out to controllers.
-spec send_to_controllers(integer(), ofp_message()) -> any().
send_to_controllers(SwitchId, Message) ->
    gen_server:cast(linc:lookup(SwitchId, linc_logic),
                    {send_to_controllers, Message}).

-spec get_datapath_id(integer()) -> string().
get_datapath_id(SwitchId) ->
    gen_server:call(linc:lookup(SwitchId, linc_logic), get_datapath_id).

-spec set_datapath_id(integer(), string()) -> ok.
set_datapath_id(SwitchId, DatapathId) ->
    gen_server:cast(linc:lookup(SwitchId, linc_logic),
                    {set_datapath_id, DatapathId}).

-spec get_backend_flow_tables(integer()) -> list(#flow_table{}).
get_backend_flow_tables(SwitchId) ->
    gen_server:call(linc:lookup(SwitchId, linc_logic), get_backend_flow_tables).

-spec get_backend_capabilities(integer()) -> #capabilities{}.
get_backend_capabilities(SwitchId) ->
    gen_server:call(linc:lookup(SwitchId, linc_logic), get_backend_capabilities).

-spec get_backend_ports(integer()) -> list(#port{}).
get_backend_ports(SwitchId) ->
    gen_server:call(linc:lookup(SwitchId, linc_logic), get_backend_ports).

-spec get_port_config(integer(), integer()) -> #port_configuration{}.
get_port_config(SwitchId, PortNo) ->
    gen_server:call(linc:lookup(SwitchId, linc_logic), {get_port_config,
                                                        PortNo}).

-spec set_port_config(integer(), integer(), #port_configuration{}) -> ok.
set_port_config(SwitchId, PortNo, PortConfig) ->
    gen_server:cast(linc:lookup(SwitchId, linc_logic), {set_port_config,
                                                        PortNo, PortConfig}).

-spec get_port_features(integer(), integer()) -> #port_features{}.
get_port_features(SwitchId, PortNo) ->
    gen_server:call(linc:lookup(SwitchId, linc_logic), {get_port_features,
                                                        PortNo}).

-spec set_port_features(integer(), integer(), #port_features{}) -> ok.
set_port_features(SwitchId, PortNo, PortFeatures) ->
    gen_server:cast(linc:lookup(SwitchId, linc_logic), {set_port_features,
                                                        PortNo, PortFeatures}).

-spec is_port_valid(integer(), integer()) -> boolean().
is_port_valid(SwitchId, PortNo) ->
    gen_server:call(linc:lookup(SwitchId, linc_logic), {is_port_valid, PortNo}).

-spec get_backend_queues(integer()) -> list(#queue{}).
get_backend_queues(SwitchId) ->
    gen_server:call(linc:lookup(SwitchId, linc_logic), get_backend_queues).

-spec get_queue_min_rate(integer(), integer(), integer()) -> integer().
get_queue_min_rate(SwitchId, PortNo, QueueId) ->
    gen_server:call(linc:lookup(SwitchId, linc_logic), {get_queue_min_rate,
                                                        PortNo, QueueId}).

-spec set_queue_min_rate(integer(), integer(), integer(), integer()) -> ok.
set_queue_min_rate(SwitchId, PortNo, QueueId, Rate) ->
    gen_server:cast(linc:lookup(SwitchId, linc_logic), {set_queue_min_rate,
                                                        PortNo, QueueId, Rate}).

-spec get_queue_max_rate(integer(), integer(), integer()) -> integer().
get_queue_max_rate(SwitchId, PortNo, QueueId) ->
    gen_server:call(linc:lookup(SwitchId, linc_logic), {get_queue_max_rate,
                                                        PortNo, QueueId}).

-spec set_queue_max_rate(integer(), integer(), integer(), integer()) -> ok.
set_queue_max_rate(SwitchId, PortNo, QueueId, Rate) ->
    gen_server:cast(linc:lookup(SwitchId, linc_logic), {set_queue_max_rate,
                                                        PortNo, QueueId, Rate}).

-spec is_queue_valid(integer(), integer(), integer()) -> boolean().
is_queue_valid(SwitchId, PortNo, QueueId) ->
    gen_server:call(linc:lookup(SwitchId, linc_logic), {is_queue_valid,
                                                        PortNo, QueueId}).

open_controller(SwitchId, Id, Host, Port, Proto) ->
    gen_server:cast(linc:lookup(SwitchId, linc_logic), {open_controller, Id,
                                                        Host, Port, Proto}).

%% @doc Start the OF Switch logic.
-spec start_link(integer(), atom(), term(), term()) -> {ok, pid()} |
                                                       {error, any()}.
start_link(SwitchId, BackendMod, BackendOpts, Config) ->
    gen_server:start_link(?MODULE, [SwitchId, BackendMod,
                                    BackendOpts, Config], []).

%%------------------------------------------------------------------------------
%% gen_server callbacks
%%------------------------------------------------------------------------------

init([SwitchId, BackendMod, BackendOpts, Config]) ->
    %% We trap exit signals here to handle shutdown initiated by the supervisor
    %% and run terminate function which invokes terminate in callback modules
    process_flag(trap_exit, true),
    linc:register(SwitchId, linc_logic, self()),

    OFConfigBackendMod = list_to_atom(atom_to_list(BackendMod) ++ "_ofconfig"),

    %% Timeout 0 will send a timeout message to the gen_server to handle
    %% backend initialization before any other message.
    {ok, #state{backend_mod = BackendMod,
                ofconfig_backend_mod = OFConfigBackendMod,
                backend_state = BackendOpts,
                switch_id = SwitchId,
                config = Config}, 0}.

handle_call(get_datapath_id, _From, #state{datapath_id = DatapathId} = State) ->
    {reply, DatapathId, State};
handle_call(get_backend_flow_tables, _From,
            #state{ofconfig_backend_mod = OFConfigBackendMod,
                   datapath_id = DatapathId,
                   switch_id = SwitchId} = State) ->
    FlowTables = OFConfigBackendMod:get_flow_tables(SwitchId, DatapathId),
    {reply, FlowTables, State};
handle_call(get_backend_capabilities, _From,
            #state{ofconfig_backend_mod = OFConfigBackendMod} = State) ->
    Capabilities = OFConfigBackendMod:get_capabilities(),
    {reply, Capabilities, State};
handle_call(get_backend_ports, _From,
            #state{ofconfig_backend_mod = OFConfigBackendMod,
                   switch_id = SwitchId} = State) ->
    Ports = OFConfigBackendMod:get_ports(SwitchId),
    {reply, Ports, State};
handle_call({get_port_config, PortNo}, _From,
            #state{ofconfig_backend_mod = OFConfigBackendMod,
                   switch_id = SwitchId} = State) ->
    PortConfig = OFConfigBackendMod:get_port_config(SwitchId, PortNo),
    {reply, PortConfig, State};
handle_call({get_port_features, PortNo}, _From,
            #state{ofconfig_backend_mod = OFConfigBackendMod,
                   switch_id = SwitchId} = State) ->
    PortFeatures = OFConfigBackendMod:get_port_features(SwitchId, PortNo),
    {reply, PortFeatures, State};
handle_call(get_backend_queues, _From,
            #state{ofconfig_backend_mod = OFConfigBackendMod,
                   switch_id = SwitchId} = State) ->
    BackendQueues = OFConfigBackendMod:get_queues(SwitchId),
    RealQueues = lists:filter(fun(#queue{id = default}) ->
                                      false;
                                 (#queue{})->
                                      true
                              end, BackendQueues),
    {reply, RealQueues, State};
handle_call(get_queue_min_rate, _From,
            #state{ofconfig_backend_mod = OFConfigBackendMod,
                   switch_id = SwitchId} = State) ->
    BackendQueues = OFConfigBackendMod:get_queue_min_rate(SwitchId),
    {reply, BackendQueues, State};
handle_call(get_queue_max_rate, _From,
            #state{ofconfig_backend_mod = OFConfigBackendMod,
                   switch_id = SwitchId} = State) ->
    BackendQueues = OFConfigBackendMod:get_queue_max_rate(SwitchId),
    {reply, BackendQueues, State};
handle_call({is_port_valid, PortNo}, _From,
            #state{backend_mod = BackendMod,
                   switch_id = SwitchId} = State) ->
    Validity = BackendMod:is_port_valid(SwitchId, PortNo),
    {reply, Validity, State};
handle_call({is_queue_valid, PortNo, QueueId}, _From,
            #state{backend_mod = BackendMod,
                   switch_id = SwitchId} = State) ->
    Validity = BackendMod:is_queue_valid(SwitchId, PortNo, QueueId),
    {reply, Validity, State};
handle_call(_Message, _From, State) ->
    {reply, ok, State}.

handle_cast({send_to_controllers, Message},
            #state{xid = Xid,
                   switch_id = SwitchId,
                   backend_mod = Backend} = State) ->
    ofp_channel_send(SwitchId, Backend, Message#ofp_message{xid = Xid}),
    {noreply, State#state{xid = Xid + 1}};
handle_cast({set_datapath_id, DatapathId},
            #state{backend_mod = Backend,
                   backend_state = BackendState} = State) ->
    BackendState2 = Backend:set_datapath_mac(BackendState,
                                             extract_mac(DatapathId)),
    {noreply, State#state{backend_state = BackendState2,
                          datapath_id = DatapathId}};
handle_cast({set_port_config, PortNo, PortConfig},
            #state{ofconfig_backend_mod = OFConfigBackendMod,
                   switch_id = SwitchId} = State) ->
    OFConfigBackendMod:set_port_config(SwitchId, PortNo, PortConfig),
    {noreply, State};
handle_cast({set_port_features, PortNo, PortFeatures},
            #state{ofconfig_backend_mod = OFConfigBackendMod,
                   switch_id = SwitchId} = State) ->
    OFConfigBackendMod:set_port_features(SwitchId, PortNo, PortFeatures),
    {noreply, State};
handle_cast({set_queue_min_rate, PortNo, QueueId, Rate},
            #state{ofconfig_backend_mod = OFConfigBackendMod,
                   switch_id = SwitchId} = State) ->
    OFConfigBackendMod:set_queue_min_rate(SwitchId, PortNo, QueueId, Rate),
    {noreply, State};
handle_cast({set_queue_max_rate, PortNo, QueueId, Rate},
            #state{ofconfig_backend_mod = OFConfigBackendMod,
                   switch_id = SwitchId} = State) ->
    OFConfigBackendMod:set_queue_max_rate(SwitchId, PortNo, QueueId, Rate),
    {noreply, State};
handle_cast({open_controller, ControllerId, Host, Port, Proto},
            #state{version = Version,
                   switch_id = SwitchId} = State) ->
    ChannelSup = linc:lookup(SwitchId, channel_sup),
    Opts = [{controlling_process, self()}, {version, Version}],
    ofp_channel:open(
      ChannelSup, ControllerId, {remote_peer, Host, Port, Proto}, Opts),
    {noreply, State};
handle_cast(_Message, State) ->
    {noreply, State}.

handle_info(timeout, #state{backend_mod = BackendMod,
                            backend_state = BackendState,
                            switch_id = SwitchId,
                            config = Config} = State) ->
    %% Starting the backend and opening connections to the controllers as a
    %% first thing after the logic and the main supervisor started.
    {switch, SwitchId, SwitchOpts} = lists:keyfind(SwitchId, 2,
                                                   Config),
    {datapath_id, DatapathId} = lists:keyfind(datapath_id, 1,
                                              SwitchOpts),
    BackendOpts = lists:keystore(switch_id, 1, BackendState,
                                 {switch_id, SwitchId}),
    BackendOpts2 = lists:keystore(datapath_mac, 1, BackendOpts,
                                  {datapath_mac, get_datapath_mac()}),
    BackendOpts3 = lists:keystore(config, 1, BackendOpts2,
                                  {config, Config}),
    BackendOpts4 = lists:keystore(datapath_id, 1, BackendOpts3,
                                  {datapath_id, extract_binary(DatapathId)}),
    case BackendMod:start(BackendOpts4) of
        {ok, Version, BackendState2} ->
            start_and_register_ofp_channels_sup(SwitchId),
            Opts = [{controlling_process, self()}, {version, Version}],
            open_ofp_channels(Opts, State),
            start_and_register_controllers_listener(Opts, State),
            {noreply, State#state{version = Version,
                                  backend_state = BackendState2,
                                  datapath_id = DatapathId}};
        {error, Reason} ->
            {stop, {backend_failed, Reason}, State}
    end;

handle_info({ofp_message, Pid, #ofp_message{body = MessageBody, 
                                            xid = Xid} = Message},
            #state{backend_mod = Backend,
                   backend_state = BackendState} = State) ->
    ?DEBUG("Received message from the controller: ~p", [Message]),
    BState2 = Backend:set_monitor_data(Pid, Xid, BackendState),
    NewBState = case Backend:handle_message(MessageBody, BState2) of
                    {noreply, NewState} ->
                        NewState;
                    {reply, Replies, NewState} when is_list(Replies) ->
                        send_replies(Pid, Backend, Replies, Message),
                        NewState;
                    {reply, Reply, NewState} ->
                        send_reply(Pid, Backend, Reply, Message),
                        NewState
                end,
    {noreply, State#state{backend_state = NewBState}};
handle_info({ofp_connected, _Pid, {Host, Port, Id, Version}}, State) ->
    ?INFO("Connected to controller ~s:~p/~p using OFP v~p",
          [Host, Port, Id, Version]),
    {noreply, State};
handle_info({ofp_closed, _Pid, {Host, Port, Id, Reason}}, State) ->
    ?INFO("Connection to controller ~s:~p/~p closed because of ~p",
          [Host, Port, Id, Reason]),
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(Reason, #state{switch_id = SwitchId, backend_mod = BackendMod,
                         backend_state = BackendState}) ->
    case Reason of
        {backend_failed, DeatiledReason} ->
            ?ERROR("Backend module ~p failed to start because: ~p",
                   [BackendMod, DeatiledReason]),
            supervisor:terminate_child(linc:lookup(SwitchId, linc_sup),
                                       linc_logic);
        _ ->
            ok
    end,
    BackendMod:stop(BackendState).

code_change(_OldVersion, State, _Extra) ->
    {ok, State}.

%%%-----------------------------------------------------------------------------
%%% Helpers
%%%-----------------------------------------------------------------------------

start_and_register_ofp_channels_sup(SwitchId) ->
    %% This needs to be temporary, since it is explicitly started as a
    %% child of linc_sup by linc_logic, and thus should _not_ be
    %% automatically restarted by the supervisor.
    ChannelSup = {ofp_channel_sup, {ofp_channel_sup, start_link, [SwitchId]},
                  temporary, 5000, supervisor, [ofp_channel_sup]},
    {ok, ChannelSupPid} = supervisor:start_child(linc:lookup(SwitchId,
                                                             linc_sup),
                                                 ChannelSup),
    linc:register(SwitchId, channel_sup, ChannelSupPid).

open_ofp_channels(Opts, #state{switch_id = SwitchId, config = Config}) ->
    CtrlsConfig = controllers_config(Opts, linc:controllers_for_switch(SwitchId,
                                                                       Config)),
    ChannelSupPid = linc:lookup(SwitchId, channel_sup),
    [ofp_channel:open(
       ChannelSupPid, Id, {remote_peer, Host, Port, Protocol}, Opt)
     || {Id, Host, Port, Protocol, Opt} <- CtrlsConfig].

controllers_config(Opts, Controllers) ->
    [case Ctrl of
         {Id, Host, Port, Protocol} ->
             {Id, Host, Port, Protocol, Opts};
         {Id, Host, Port, Protocol, SysOpts} ->
             {Id, Host, Port, Protocol, Opts ++ SysOpts}
     end || Ctrl <- Controllers].

start_and_register_controllers_listener(Opts, #state{switch_id = SwitchId,
                                                     config = Config}) ->
    case linc:controllers_listener_for_switch(SwitchId, Config) of
        disabled ->
            ok;
        ConnListenerConfig ->
            CtrlsListenerArgs = controllers_listener_args(SwitchId,
                                                          ConnListenerConfig,
                                                          Opts),
            ConnListenerSupPid = start_controllers_listener(
                                   CtrlsListenerArgs,
                                   linc:lookup(SwitchId, linc_sup)),
            linc:register(SwitchId, conn_listener_sup, ConnListenerSupPid)
    end.

controllers_listener_args(SwitchId, {Address, Port, tcp}, Opts) ->
    {ok, ParsedAddress} = inet_parse:address(Address),
    [ParsedAddress, Port, linc:lookup(SwitchId, channel_sup), Opts].

start_controllers_listener(ConnListenerArgs, LincSupPid) ->
    %% This needs to be temporary, since it is explicitly started as a
    %% child of linc_sup by linc_logic, and thus should _not_ be
    %% automatically restarted by the supervisor.
    ConnListenerSupSpec =
        {ofp_conn_listener_sup, {ofp_conn_listener_sup, start_link,
                                 ConnListenerArgs},
         temporary, infinity, supervisor, [ofp_conn_listener_sup]},
    {ok, ConnListenerSupPid} = supervisor:start_child(LincSupPid,
                                                      ConnListenerSupSpec),
    ConnListenerSupPid.

get_datapath_mac() ->
    {ok, Ifs} = inet:getifaddrs(),
    MACs =  [element(2, lists:keyfind(hwaddr, 1, Ps))
             || {_IF, Ps} <- Ifs, lists:keymember(hwaddr, 1, Ps)],
    %% Make sure MAC /= 0
    [MAC | _] = [M || M <- MACs, M /= [0,0,0,0,0,0]],
    list_to_binary(MAC).

gen_datapath_id(SwitchId) ->
    datapathid(SwitchId,get_datapath_mac()).

datapathid(SwitchId,MAC) ->
    string:join([integer_to_hex(D) || <<D>> <= <<SwitchId:16,MAC/binary>>],":").

integer_to_hex(I) ->
    case integer_to_list(I, 16) of
        [D] -> [$0, D];
        DD  -> DD
    end.

extract_binary(String) ->
    Str = re:replace(String, ":", "", [global, {return, list}]),
    extract_mac(Str, <<>>).

extract_mac(DatapathId) ->
    Str = re:replace(string:substr(DatapathId, 1, 17), ":", "",
                     [global, {return, list}]),
    extract_mac(Str, <<>>).

extract_mac([], Mac) ->
    Mac;
extract_mac([N1, N2 | Rest], Mac) ->
    B1 = list_to_integer([N1], 16),
    B2 = list_to_integer([N2], 16),
    extract_mac(Rest, <<Mac/binary, B1:4, B2:4>>).

send_replies(Pid, Backend, Replies, OriginalMessage) ->
    lists:foreach(
      fun(Reply) ->
              send_reply(Pid, Backend, Reply, OriginalMessage)
      end, Replies).

send_reply(Pid, Backend, #ofp_message{} = ReplyMessage, _OriginalMessage) ->
    ofp_channel_send(Pid, Backend, ReplyMessage);
send_reply(Pid, Backend, ReplyBody, OriginalMessage) ->
    ofp_channel_send(Pid, Backend, OriginalMessage#ofp_message{body = ReplyBody}).

ofp_channel_send(Id, Backend, Message) ->
    case ofp_channel:send(Id, Message) of
        ok ->
            Backend:log_message_sent(Message),
            ok;
        {ok, filtered} ->
            log_message_filtered(Message, Id);
        {error, not_connected} = Error ->
            %% Don't log not_connected errors, as they pollute debug output.
            %% This error occurs each time when packet is received by
            %% the switch but switch didn't connect to the controller yet.
            Error;
        {error, Reason} = Error ->
            log_channel_send_error(Message, Id, Reason),
            Error;
        L when is_list(L) ->
            lists:map(fun(ok) ->
                              ok;
                         ({ok, filtered}) ->
                              log_message_filtered(Message, Id);
                         ({error, not_connected} = Error) ->
                              %% Same as previous comment
                              Error;
                         ({error, Reason} = Error) ->
                              log_channel_send_error(Message, Id, Reason),
                              Error
                      end, L)
    end.

log_channel_send_error(Message, Id, Reason) ->
    ?ERROR("~nMessage: ~p~n"
           "Channel id: ~p~n"
           "Message cannot be sent through OFP Channel because:~n"
           "~p~n", [Message, Id, Reason]).

log_message_filtered(Message, Id) ->
    ?DEBUG("Message: ~p~n"
           "filtered and not sent through the channel with id: ~p~n",
          [Message, Id]).
