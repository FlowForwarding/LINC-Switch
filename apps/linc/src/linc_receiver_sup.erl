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
%% @doc Supervisor module for the receiver processes.
-module(linc_receiver_sup).

-behaviour(supervisor).

%% API
-export([start_link/0, open/2, close/2]).

%% Supervisor callbacks
-export([init/1]).

%%%-----------------------------------------------------------------------------
%%% API functions
%%%-----------------------------------------------------------------------------

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

open(Controller, Port) ->
    Id = list_to_atom(Controller ++ "_" ++ integer_to_list(Port)),
    ChildSpec = {Id, {linc_receiver, start_link, [Id, Controller, Port]},
                 permanent, 5000, worker, [linc_receiver]},
    supervisor:start_child(linc_receiver_sup, ChildSpec).

-spec close(string(), integer()) -> ok.
close(Controller, Port) ->
    Id = list_to_atom(Controller ++ "_" ++ integer_to_list(Port)),
    supervisor:terminate_child(linc_receiver_sup, Id),
    supervisor:delete_child(linc_receiver_sup, Id).

%%%-----------------------------------------------------------------------------
%%% Supervisor callbacks
%%%-----------------------------------------------------------------------------

init([]) ->
    {ok, {{one_for_one, 5, 10}, []}}.
