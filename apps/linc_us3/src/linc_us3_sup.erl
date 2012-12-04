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
%% @doc Supervisor module for the userspace switch implementation.
-module(linc_us3_sup).

-behaviour(supervisor).

%% API
-export([start_link/0,
         start_backend_sup/0]).

%% Supervisor callbacks
-export([init/1]).

%%------------------------------------------------------------------------------
%% API functions
%%------------------------------------------------------------------------------

-spec start_link() -> {ok, pid()} | ignore | {error, term()}.
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

start_backend_sup() ->
    BackendSup = {?MODULE, {?MODULE, start_link, []},
                  transient, 5000, supervisor, [?MODULE]},
    supervisor:start_child(linc_sup, BackendSup).

%%------------------------------------------------------------------------------
%% Supervisor callbacks
%%------------------------------------------------------------------------------

init([]) ->
    PortSup = {linc_us3_port_sup, {linc_us3_port_sup, start_link, []},
               permanent, 5000, supervisor, [linc_us3_port_sup]},
    {ok, {{one_for_one, 5, 10}, [PortSup]}}.
