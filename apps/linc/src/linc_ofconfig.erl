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
-export([start_link/0]).

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
