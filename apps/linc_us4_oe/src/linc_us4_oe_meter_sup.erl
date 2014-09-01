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
-module(linc_us4_oe_meter_sup).

-behaviour(supervisor).

%% API
-export([start_link/1,
         stop/1]).

%% Supervisor callbacks
-export([init/1]).

%%------------------------------------------------------------------------------
%% API functions
%%------------------------------------------------------------------------------

%% @doc Start the supervisor.
-spec start_link(integer()) -> {ok, pid()} | {error, term()}.
start_link(SwitchId) ->
    supervisor:start_link(?MODULE, [SwitchId]).

%% @doc Stop the supervisor.
-spec stop(integer()) -> ok.
stop(SwitchId) ->
    Pid = linc:lookup(SwitchId, linc_meter_sup),
    exit(Pid, normal),
    ok.

%%------------------------------------------------------------------------------
%% Supervisor callbacks
%%------------------------------------------------------------------------------

init([SwitchId]) ->
    TId = ets:new(linc_meters, [public, {read_concurrency, true}]),
    linc:register(SwitchId, linc_meter_ets, TId),
    linc:register(SwitchId, linc_meter_sup, self()),
    MeterSpec = {linc_us4_oe_meter, {linc_us4_oe_meter, start_link, [SwitchId]},
                 permanent, 1000, worker, [linc_us4_oe_meter]},
    {ok, {{simple_one_for_one, 5, 10}, [MeterSpec]}}.
