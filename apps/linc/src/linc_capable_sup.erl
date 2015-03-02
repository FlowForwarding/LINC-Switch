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
-export([start_link/0,
         start_switch/1,
         stop_switch/1,
         switches/0]).

%% Supervisor callbacks
-export([init/1]).

-include("linc_logger.hrl").

%%------------------------------------------------------------------------------
%% API functions
%%------------------------------------------------------------------------------

-spec start_link() -> {ok, pid()} | ignore | {error, term()}.
start_link() ->
    {ok, LogicalSwitches} = application:get_env(linc, logical_switches),
    ?DEBUG("sys.config logical switches:~n~p", [LogicalSwitches]),
    linc_ports_mapping:initialize(LogicalSwitches),
    {ok, Pid} = supervisor:start_link({local, ?MODULE}, ?MODULE ,[]),
    start_ofconfig_if_enabled(Pid),
    Config = case application:get_env(linc, of_config) of
                 {ok, enabled} ->
                     ?DEBUG("Old startup: ~p",
                            [mnesia:dirty_read(linc_ofconfig_startup,
                                               startup)]),
                     C = linc_ofconfig:read_and_update_startup(),
                     ?DEBUG("New startup: ~p",
                            [mnesia:dirty_read(linc_ofconfig_startup,
                                               startup)]),
                     C;
                 _ ->
                     linc_ofconfig:get_startup_without_ofconfig()
             end,
    ?DEBUG("Configuration: ~p", [Config]),
    initialize_optical_extension_if_enabled(),
    [start_switch(Pid, [Id, backend_for_switch(Id), Config])
     || {switch, Id, _} <- Config],
    {ok, Pid}.

switches() ->
    [{switch_id(Id), Pid} || {Id, Pid, supervisor, [linc_sup]} <- supervisor:which_children(?MODULE)].

start_switch(SwitchId) ->
    supervisor:restart_child(?MODULE, linc_sup_id(SwitchId)).

stop_switch(SwitchId) ->
    supervisor:terminate_child(?MODULE, linc_sup_id(SwitchId)).

%%------------------------------------------------------------------------------
%% Supervisor callbacks
%%------------------------------------------------------------------------------

init([]) ->
    {ok, {{one_for_one, 5, 10}, []}}.

%%------------------------------------------------------------------------------
%% Internal functions
%%------------------------------------------------------------------------------

switch_id(Id) ->
    {match,[SwitchIdS]} = re:run(atom_to_list(Id), "([[:digit:]]+)", [{capture, first, list}]),
    list_to_integer(SwitchIdS).

linc_sup_id(SwitchId) ->
    list_to_atom("linc" ++ integer_to_list(SwitchId) ++ "_sup").

start_switch(Sup, [SwitchId, _, _Config] = Opts) ->
    Id = linc_sup_id(SwitchId),
    LogicSup = {Id, {linc_sup, start_link, Opts},
                permanent, 5000, supervisor, [linc_sup]},
    supervisor:start_child(Sup, LogicSup).

backend_for_switch(SwitchId) ->
    {ok, Switches} = application:get_env(linc, logical_switches),
    {switch, SwitchId, Opts} = lists:keyfind(SwitchId, 2, Switches),
    {backend, BackendMod} = lists:keyfind(backend, 1, Opts),
    BackendMod.

start_ofconfig_if_enabled(Pid) ->
    case application:get_env(linc, of_config) of
        {ok, enabled} ->
            start_dependency(ssh),
            start_dependency(enetconf),
            OFConfig = {linc_ofconfig, {linc_ofconfig, start_link, []},
                        permanent, 5000, worker, [linc_ofconfig]},
            supervisor:start_child(Pid, OFConfig);
        _ ->
            ok
    end.

%% Don't stop dependent applications (ssh, enetconf) even when they were
%% started by the corresponding start_ofconfig/0 function.
%% Rationale: stop_ofconfig/0 is called from the context of
%% application:stop(linc) and subsequent attempt to stop another application
%% while the first one is still stopping results in a deadlock.
%% stop_ofconfig() ->
%%     case application:get_env(linc, of_config) of
%%         {ok, enabled} ->
%%             ok;
%%         _ ->
%%             ok
%%     end.

start_dependency(App) ->
    case application:start(App) of
        ok ->
            ok;
        {error, {already_started, ssh}} ->
            ok;
        {error, _} = Error  ->
            ?ERROR("Starting ~p application failed because: ~p",
                   [App, Error])
    end.

initialize_optical_extension_if_enabled() ->
    case application:get_env(linc, optical_links) of
        {ok, Links} ->
            linc_oe:initialize(Links);
        _ ->
            ok
    end.
