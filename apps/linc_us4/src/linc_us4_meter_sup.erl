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
%% @doc Per-flow meters supervisor.
-module(linc_us4_meter_sup).

-behaviour(supervisor).

%% API
-export([start_link/0,
         stop/0]).

%% Supervisor callbacks
-export([init/1]).

-define(ETS, linc_meters).

%%------------------------------------------------------------------------------
%% API functions
%%------------------------------------------------------------------------------

%% @doc Start the supervisor.
-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% @doc Stop the supervisor.
-spec stop() -> ok.
stop() ->
    exit(whereis(?MODULE), normal),
    ok.

%%------------------------------------------------------------------------------
%% Supervisor callbacks
%%------------------------------------------------------------------------------

init([]) ->
    ets:new(?ETS, [named_table, public,
                   {read_concurrency, true}]),
    MeterSpec = {linc_us4_meter, {linc_us4_meter, start_link, []},
                 permanent, 1000, worker, [linc_us4_meter]},
    {ok, {{simple_one_for_one, 5, 10}, [MeterSpec]}}.
