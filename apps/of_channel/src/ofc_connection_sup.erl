%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2012, Erlang Solutions Ltd.
%%% @author Krzysztof Rutka <krzysztof.rutka@erlang-solutions.com>
%%% @doc Supervisor module for the receiver processes.
%%% @end
%%%-----------------------------------------------------------------------------
-module(ofc_connection_sup).

-behaviour(supervisor).

%% API
-export([start_link/0, open/1]).

%% Supervisor callbacks
-export([init/1]).

%%%-----------------------------------------------------------------------------
%%% API functions
%%%-----------------------------------------------------------------------------

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

open(Controller) ->
    ChildSpec = {ofc_connection, {ofc_connection, start_link, [Controller]},
                 permanent, 5000, worker, [ofc_connection]},
    supervisor:start_child(ofc_connection_sup, ChildSpec).

%%%-----------------------------------------------------------------------------
%%% Supervisor callbacks
%%%-----------------------------------------------------------------------------

init([]) ->
    {ok, {{one_for_one, 5, 10}, []}}.
