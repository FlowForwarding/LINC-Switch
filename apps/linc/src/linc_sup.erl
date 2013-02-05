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
%% @doc OpenFlow Logical Switch main supervisor module.
-module(linc_sup).

-behaviour(supervisor).

%% API
-export([start_link/3]).

%% Supervisor callbacks
-export([init/1]).

%%------------------------------------------------------------------------------
%% API functions
%%------------------------------------------------------------------------------

-spec start_link(integer(), atom(), term()) -> {ok, pid()} | ignore | {error, term()}.
start_link(SwitchId, BackendMod, Config) ->
    supervisor:start_link(?MODULE, [SwitchId, BackendMod, Config]).

%%------------------------------------------------------------------------------
%% Supervisor callbacks
%%------------------------------------------------------------------------------

init([SwitchId, BackendMod, Config]) ->
    linc:create(SwitchId),
    linc:register(SwitchId, linc_sup, self()),
    Logic = {linc_logic, {linc_logic, start_link, [SwitchId, BackendMod,
                                                   [], Config]},
             permanent, 5000, worker, [linc_logic]},
    {ok, {{one_for_all, 5, 10}, [Logic]}}.
