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
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

%%------------------------------------------------------------------------------
%% API functions
%%------------------------------------------------------------------------------

-spec start_link() -> {ok, pid()} | ignore | {error, term()}.
start_link() ->
    {ok, _} = supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%%------------------------------------------------------------------------------
%% Supervisor callbacks
%%------------------------------------------------------------------------------

init([]) ->
    {ok, {BackendMod, BackendOpts}} = application:get_env(linc, backend),
    SwitchLogic = {linc_logic,
                   {linc_logic, start_link, [BackendMod, BackendOpts]},
                   permanent, 5000, worker, [linc_logic]},
    ReceiverSup = {linc_receiver_sup,
                   {linc_receiver_sup, start_link, []},
                   permanent, 5000, supervisor, [linc_receiver_sup]},
    OFConfig = {linc_ofconfig,
                {linc_ofconfig, start_link, []},
                permanent, 5000, worker, [linc_ofconfig]},
    {ok, {{one_for_all, 5, 10}, [ReceiverSup,
                                 SwitchLogic,
                                 OFConfig]}}.
