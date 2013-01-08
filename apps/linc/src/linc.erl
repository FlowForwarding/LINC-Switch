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
         stop/1]).

-export([create/1,
         delete/1,
         register/3,
         lookup/2,
         controllers_for_switch/1,
         ports_for_switch/1]).

%%------------------------------------------------------------------------------
%% Application callbacks
%%------------------------------------------------------------------------------

%% @doc Starts the application.
-spec start(any(), any()) -> {ok, pid()}.
start(_StartType, _StartArgs) ->
    Id = 0,
    BackendMod = backend_for_switch(Id),
    linc_sup:start_link(Id, BackendMod).

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

-spec delete(integer()) -> ok.
delete(SwitchId) ->
    ets:delete(name(SwitchId)).

-spec register(integer(), atom(), pid()) -> true.
register(SwitchId, Name, Pid) ->
    true = ets:insert(name(SwitchId), {Name, Pid}).

-spec lookup(integer(), atom()) -> term().
lookup(SwitchId, Name) ->
    [{Name, Pid}] = ets:lookup(name(SwitchId), Name),
    Pid.

-spec controllers_for_switch(integer()) -> list(tuple()).
controllers_for_switch(_SwitchId) ->
    {ok, Controllers} = application:get_env(linc, controllers),
    Controllers.

ports_for_switch(SwitchId) ->
    case application:get_env(linc, backends_opts) of
        {ok, Backends} ->
            {linc_us4, Opts} = lists:keyfind(linc_us4, 1, Backends),
            {ports, UserspacePorts} = lists:keyfind(ports, 1, Opts),
            UserspacePorts;
        undefined ->
            []
    end.

%%------------------------------------------------------------------------------
%% Local helpers
%%------------------------------------------------------------------------------

name(SwitchId) ->
    list_to_atom("linc_switch_" ++ integer_to_list(SwitchId)).

-spec backend_for_switch(integer()) -> atom().
backend_for_switch(_SwitchId) ->
    {ok, BackendMod} = application:get_env(linc, backend),
    BackendMod.
