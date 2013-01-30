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
         %% Backend queues
         get_backend_queues/1,
         get_queue_min_rate/3,
         set_queue_min_rate/4,
         get_queue_max_rate/3,
         set_queue_max_rate/4
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
          config :: term()
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

-spec get_backend_queues(integer()) -> list(#queue{}).
get_backend_queues(SwitchId) ->
    gen_server:call(linc:lookup(SwitchId, linc_logic), get_backend_queues).

-spec get_queue_min_rate(integer(), integer(), integer()) -> integer().
get_queue_min_rate(SwitchId, PortNo, QueueId) ->
    gen_server:call(linc:lookup(SwitchId, linc_logic), {get_queue_min_rate,
                                                        PortNo, QueueId}).

-spec set_queue_min_rate(integer(), integer(), integer(), integer()) -> ok.
set_queue_min_rate(SwitchId, PortNo, QueueId, Rate) ->
    gen_server:call(linc:lookup(SwitchId, linc_logic), {set_queue_min_rate,
                                                        PortNo, QueueId, Rate}).

-spec get_queue_max_rate(integer(), integer(), integer()) -> integer().
get_queue_max_rate(SwitchId, PortNo, QueueId) ->
    gen_server:call(linc:lookup(SwitchId, linc_logic), {get_queue_max_rate,
                                                        PortNo, QueueId}).

-spec set_queue_max_rate(integer(), integer(), integer(), integer()) -> ok.
set_queue_max_rate(SwitchId, PortNo, QueueId, Rate) ->
    gen_server:call(linc:lookup(SwitchId, linc_logic), {set_queue_max_rate,
                                                        PortNo, QueueId, Rate}).

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
handle_call(_Message, _From, State) ->
    {reply, ok, State}.

handle_cast({send_to_controllers, Message},
            #state{xid = Xid,
                   switch_id = SwitchId} = State) ->
    ofp_channel:send(SwitchId, Message#ofp_message{xid = Xid}),
    {noreply, State#state{xid = Xid + 1}};
handle_cast({set_datapath_id, DatapathId}, State) ->
    {noreply, State#state{datapath_id = DatapathId}};
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
handle_cast(_Message, State) ->
    {noreply, State}.

handle_info(timeout, #state{backend_mod = BackendMod,
                            backend_state = BackendState,
                            switch_id = SwitchId,
                            config = Config} = State) ->
    ChannelSup = {ofp_channel_sup, {ofp_channel_sup, start_link, [SwitchId]},
                  permanent, 5000, supervisor, [ofp_channel_sup]},
    {ok, ChannelSupPid} = supervisor:start_child(linc:lookup(SwitchId,
                                                             linc_sup),
                                                 ChannelSup),
    linc:register(SwitchId, channel_sup, ChannelSupPid),
    %% Starting the backend and opening connections to the controllers as a
    %% first thing after the logic and the main supervisor started.
    BackendOpts = lists:keystore(switch_id, 1, BackendState,
                                 {switch_id, SwitchId}),
    {ok, Version, BackendState2} = BackendMod:start(BackendOpts),
    Controllers = linc:controllers_for_switch(SwitchId, Config),
    Opts = [{controlling_process, self()}, {version, Version}],
    Ctrls = [case Ctrl of
                 {Id, Host, Port} ->
                     {Id, Host, Port, Opts};
                 {Id, Host, Port, SysOpts} ->
                     {Id, Host, Port, Opts ++ SysOpts}
             end || Ctrl <- Controllers],
    [ofp_channel:open(ChannelSupPid, Id, Host, Port, Opt)
     || {Id, Host, Port, Opt} <- Ctrls],
    DatapathId = "Datapath" ++ integer_to_list(SwitchId),
    {noreply, State#state{backend_state = BackendState2,
                          datapath_id = DatapathId}};
handle_info({ofp_message, Pid, #ofp_message{body = MessageBody} = Message},
            #state{backend_mod = Backend,
                   backend_state = BackendState} = State) ->
    ?DEBUG("Received message from the controller: ~p", [Message]),
    NewBState = case Backend:handle_message(MessageBody, BackendState) of
                    {noreply, NewState} ->
                        NewState;
                    {reply, ReplyBody, NewState} ->
                        ofp_channel:send(Pid,
                                         Message#ofp_message{body = ReplyBody}),
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

terminate(_Reason, #state{backend_mod = BackendMod,
                          backend_state = BackendState}) ->
    BackendMod:stop(BackendState).

code_change(_OldVersion, State, _Extra) ->
    {ok, State}.

%%%-----------------------------------------------------------------------------
%%% Helpers
%%%-----------------------------------------------------------------------------
