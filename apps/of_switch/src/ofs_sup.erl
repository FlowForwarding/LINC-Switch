%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2012, Erlang Solutions Ltd.
%%% @author Krzysztof Rutka <krzysztof.rutka@erlang-solutions.com>
%%% @doc OpenFlow Logical Switch main supervisor module.
%%% @end
%%%-----------------------------------------------------------------------------
-module(ofs_sup).

-behaviour(supervisor).

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

%%%-----------------------------------------------------------------------------
%%% API functions
%%%-----------------------------------------------------------------------------

start_link() ->
    {ok, _} = supervisor:start_link(?MODULE, []).

%%%-----------------------------------------------------------------------------
%%% Supervisor callbacks
%%%-----------------------------------------------------------------------------

init([]) ->
    {ok, {{one_for_all, 5, 10}, []}}.
