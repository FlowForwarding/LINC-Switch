%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2012, Erlang Solutions Ltd.
%%% @author Krzysztof Rutka <krzysztof.rutka@erlang-solutions.com>
%%% @doc OpenFlow Channel main supervisor module.
%%% @end
%%%-----------------------------------------------------------------------------
-module(ofc_sup).

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
    ChannelLogic = {ofc_logic, {ofc_logic, start_link, []},
                    permanent, 5000, worker, [ofc_logic]},
    ConnectionSup = {ofc_connection_sup, {ofc_connection_sup, start_link, []},
                   permanent, 5000, supervisor, [ofc_connection_sup]},
    {ok, {{one_for_all, 5, 10}, [
                                 ChannelLogic,
                                 ConnectionSup
                                ]}}.
