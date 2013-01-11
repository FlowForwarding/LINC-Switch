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
-export([send_to_controllers/2]).

%% Internal API
-export([start_link/3]).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-include_lib("of_protocol/include/of_protocol.hrl").
-include("linc_logger.hrl").

-record(state, {
          connections = [] :: [{pid(), string(), integer()}],
          xid = 1 :: integer(),
          backend_mod :: atom(),
          backend_state :: term(),
          switch_id :: integer()
         }).

%%------------------------------------------------------------------------------
%% API functions
%%------------------------------------------------------------------------------

%% @doc Send message out to controllers.
-spec send_to_controllers(integer(), ofp_message()) -> any().
send_to_controllers(SwitchId, Message) ->
    gen_server:cast(linc:lookup(SwitchId, linc_logic),
                    {send_to_controllers, Message}).

%% @doc Start the OF Switch logic.
-spec start_link(integer(), atom(), term()) -> {ok, pid()} | {error, any()}.
start_link(SwitchId, BackendMod, BackendOpts) ->
    gen_server:start_link(?MODULE, [SwitchId, BackendMod, BackendOpts], []).

%%------------------------------------------------------------------------------
%% gen_server callbacks
%%------------------------------------------------------------------------------

init([SwitchId, BackendMod, BackendOpts]) ->
    %% We trap exit signals here to handle shutdown initiated by the supervisor
    %% and run terminate function which invokes terminate in callback modules
    process_flag(trap_exit, true),
    linc:register(SwitchId, linc_logic, self()),

    %% Timeout 0 will send a timeout message to the gen_server to handle
    %% backend initialization before any other message.
    {ok, #state{backend_mod = BackendMod,
                backend_state = BackendOpts,
                switch_id = SwitchId}, 0}.

handle_call(_Message, _From, State) ->
    {reply, ok, State}.

handle_cast({send_to_controllers, Message}, #state{xid = Xid} = State) ->
    ofp_channel:send(Message#ofp_message{xid = Xid}),
    {noreply, State#state{xid = Xid + 1}};
handle_cast(_Message, State) ->
    {noreply, State}.

handle_info(timeout, #state{backend_mod = BackendMod,
                            backend_state = BackendState,
                            switch_id = SwitchId} = State) ->
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
    Controllers = linc:controllers_for_switch(SwitchId),
    Opts = [{controlling_process, self()}, {version, Version}],
    Ctrls = [case Ctrl of
                 {Host, Port} ->
                     {Host, Port, Opts};
                 {Host, Port, SysOpts} ->
                     {Host, Port, Opts ++ SysOpts}
             end || Ctrl <- Controllers],
    [ofp_channel:open(ChannelSupPid, Host, Port, Opt)
     || {Host, Port, Opt} <- Ctrls],
    {noreply, State#state{backend_state = BackendState2}};
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
