%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2012, Erlang Solutions Ltd.
%%% @author Krzysztof Rutka <krzysztof.rutka@erlang-solutions.com>
%%% @doc OpenFlow Logical Switch API module.
%%% @end
%%%-----------------------------------------------------------------------------
-module(of_switch).

%% API
-export([start/0]).

%%%-----------------------------------------------------------------------------
%%% API functions
%%%-----------------------------------------------------------------------------

%% @doc Start the application.
-spec start() -> {ok, pid()}.
start() ->
    application:start(of_switch).
