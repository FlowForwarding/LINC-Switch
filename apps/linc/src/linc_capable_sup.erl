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
%% @doc OpenFlow Capable Switch supervisor module.
-module(linc_capable_sup).

-behaviour(supervisor).

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

%%------------------------------------------------------------------------------
%% API functions
%%------------------------------------------------------------------------------

-spec start_link() -> {ok, pid()} | ignore | {error, term()}.
start_link() ->
    {ok, Pid} = supervisor:start_link(?MODULE, []),
    {ok, Switches} = application:get_env(linc, logical_switches),
    [supervisor:start_child(Pid, [Id, backend_for_switch(Id)])
     || {switch, Id, _} <- Switches],
    {ok, Pid}.

%%------------------------------------------------------------------------------
%% Supervisor callbacks
%%------------------------------------------------------------------------------

init([]) ->
    LogicSup = {linc_sup, {linc_sup, start_link, []},
                permanent, 5000, supervisor, [linc_sup]},
    {ok, {{simple_one_for_one, 5, 10}, [LogicSup]}}.

%%------------------------------------------------------------------------------
%% Internal functions
%%------------------------------------------------------------------------------

backend_for_switch(SwitchId) ->
    {ok, Switches} = application:get_env(linc, logical_switches),
    {switch, SwitchId, Opts} = lists:keyfind(SwitchId, 2, Switches),
    {backend, BackendMod} = lists:keyfind(backend, 1, Opts),
    BackendMod.
