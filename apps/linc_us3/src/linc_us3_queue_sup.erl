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
%% @doc Supervisor module for port queues.
-module(linc_us3_queue_sup).

-behaviour(supervisor).

%% API
-export([start_link/1]).

%% Supervisor callbacks
-export([init/1]).

-include_lib("of_protocol/include/of_protocol.hrl").
-include_lib("of_protocol/include/ofp_v3.hrl").
-include("linc_us3.hrl").

%%%-----------------------------------------------------------------------------
%%% API functions
%%%-----------------------------------------------------------------------------

-spec start_link(integer()) -> {ok, pid()} | ignore | {error, term()}.
start_link(SwitchId) ->
    supervisor:start_link(?MODULE, SwitchId).

%%%-----------------------------------------------------------------------------
%%% Supervisor callbacks
%%%-----------------------------------------------------------------------------

init(SwitchId) ->
    linc:register(SwitchId, linc_us3_queue_sup, self()),
    ChildSpec = {linc_us3_queue, {linc_us3_queue, start_link, [SwitchId]},
                 transient, 5000, worker, [linc_us3_queue]},
    {ok, {{simple_one_for_one, 5, 10}, [ChildSpec]}}.
