%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2012, Erlang Solutions Ltd.
%%% @doc OpenFlow Logical Switch API module.
%%% @end
%%%-----------------------------------------------------------------------------
-module(of_switch).

%% API
-export([start/0, stop/0]).

%%%-----------------------------------------------------------------------------
%%% API functions
%%%-----------------------------------------------------------------------------

%% @doc Start the application.
-spec start() -> ok.
start() ->
    application:start(of_switch).

%% @doc Stop the application.
-spec stop() -> ok.
stop() ->
    application:stop(of_switch).
