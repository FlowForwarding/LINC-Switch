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
         register/3,
         lookup/2,
         controllers_for_switch/1]).

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
create(Id) ->
    ets:new(name(Id), [named_table, public,
                       {read_concurrency, true}]).

-spec register(integer(), atom(), pid()) -> true.
register(Id, Name, Pid) ->
    true = ets:insert(name(Id), {Name, Pid}).

-spec lookup(integer(), atom()) -> pid().
lookup(Id, Name) ->
    [{Name, Pid}] = ets:lookup(name(Id), Name),
    Pid.

-spec controllers_for_switch(integer()) -> list(tuple()).
controllers_for_switch(_Id) ->
    {ok, Controllers} = application:get_env(linc, controllers),
    Controllers.

%%------------------------------------------------------------------------------
%% Local helpers
%%------------------------------------------------------------------------------

name(Id) ->
    list_to_atom("linc_switch_" ++ integer_to_list(Id)).

-spec backend_for_switch(integer()) -> atom().
backend_for_switch(_Id) ->
    {ok, BackendMod} = application:get_env(linc, backend),
    BackendMod.
