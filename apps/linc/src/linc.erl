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
%% @doc Callback module for OpenFlow Logical Switch application.
-module(linc).

-behaviour(application).

%% Application callbacks
-export([start/2,
         stop/1,
         switches/0,
         port_down/2,
         port_up/2,
         ports/1]).

-export([create/1,
         delete/1,
         register/3,
         lookup/2,
         controllers_for_switch/2,
         controllers_listener_for_switch/2]).

%% command line API
-export([start_switch/1,
         stop_switch/1]).

-include("linc_logger.hrl").

%%------------------------------------------------------------------------------
%% Utility Commands
%%------------------------------------------------------------------------------
start_switch(SwitchId) ->
    linc_capable_sup:start_switch(SwitchId).

stop_switch(SwitchId) ->
    linc_capable_sup:stop_switch(SwitchId).

switches() ->
    linc_capable_sup:switches().

port_down(SwitchId, PortNo) ->
    linc_us4_oe_port:optical_down(SwitchId, PortNo).

port_up(SwitchId, PortNo) ->
    linc_us4_oe_port:optical_up(SwitchId, PortNo).

ports(SwitchId) ->
    linc_logic:get_backend_ports(SwitchId).


%%------------------------------------------------------------------------------
%% Application callbacks
%%------------------------------------------------------------------------------

%% @doc Starts the application.
-spec start(any(), any()) -> {ok, pid()} | {error, Reason :: term()}.
start(_StartType, _StartArgs) ->
    try linc_capable_sup:start_link()
    catch
        throw:Reason ->
            {error, Reason}
    end.

%% @doc Stops the application.
-spec stop(any()) -> ok.
stop(_State) ->
    ok.

%%------------------------------------------------------------------------------
%% Common LINC helper functions
%%------------------------------------------------------------------------------

-spec create(integer()) -> ets:tid().
create(SwitchId) ->
    ets:new(name(SwitchId), [named_table, public,
                             {read_concurrency, true}]).

-spec delete(integer()) -> true.
delete(SwitchId) ->
    true = ets:delete(name(SwitchId)).

-spec register(integer(), atom(), pid() | ets:tid()) -> true.
register(SwitchId, Name, Pid) ->
    true = ets:insert(name(SwitchId), {Name, Pid}).

-spec lookup(integer(), atom()) -> term().
lookup(SwitchId, Name) ->
    case ets:lookup(name(SwitchId), Name) of
        [{Name, Pid}] ->
            Pid;
        [] ->
            undefined
    end.

-spec controllers_for_switch(integer(), term()) -> list(tuple()).
controllers_for_switch(SwitchId, Config) ->
    {switch, SwitchId, Opts} = lists:keyfind(SwitchId, 2, Config),
    {controllers, Controllers} = lists:keyfind(controllers, 1, Opts),
    Controllers.

-spec controllers_listener_for_switch(integer(), term()) -> tuple() | disabled.
controllers_listener_for_switch(SwitchId, Config) ->
    {switch, SwitchId, Opts} = lists:keyfind(SwitchId, 2, Config),
    case lists:keyfind(controllers_listener, 1, Opts) of
        {controllers_listener, ControllersListener}  ->
            ControllersListener;
        false ->
            disabled
    end.

%%------------------------------------------------------------------------------
%% Local helpers
%%------------------------------------------------------------------------------

name(SwitchId) ->
    list_to_atom("linc_switch_" ++ integer_to_list(SwitchId)).
