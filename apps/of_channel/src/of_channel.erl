%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2012, Erlang Solutions Ltd.
%%% @author Krzysztof Rutka <krzysztof.rutka@erlang-solutions.com>
%%% @doc OpenFlow Channel API module.
%%% @end
%%%-----------------------------------------------------------------------------
-module(of_channel).

%% API
-export([start/0, open_connection/1]).

%%%-----------------------------------------------------------------------------
%%% API functions
%%%-----------------------------------------------------------------------------

%% @doc Start the application.
-spec start() -> {ok, pid()}.
start() ->
    application:start(of_channel).

%% @doc Open a connection to the controller.
-spec open_connection(atom() | binary() |
                      string() | {integer(), integer(),
                                  integer(), integer()}) -> {ok, pid()} | 
                                                            {error, any()}.
open_connection(Controller) when is_binary(Controller) ->
    open_connection(binary_to_list(Controller));
open_connection(Controller) ->
    ofc_connection_sup:open(Controller).
