%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2012, Erlang Solutions Ltd.
%%% @author Krzysztof Rutka <krzysztof.rutka@erlang-solutions.com>
%%% @doc OpenFlow Channel API module.
%%% @end
%%%-----------------------------------------------------------------------------
-module(of_channel).

%% API
-export([start/0, stop/0]).
-export([open/2, send/1]).
-export([get_connection/1]).

-include("of_channel.hrl").

-type host() :: atom() | binary() | string() | {integer(), integer(),
                                                integer(), integer()}.

%%%-----------------------------------------------------------------------------
%%% API functions
%%%-----------------------------------------------------------------------------

%% @doc Start the application.
-spec start() -> ok.
start() ->
    application:start(of_channel).

%% @doc Stop the application.
-spec stop() -> any().
stop() ->
    application:stop(of_channel).

%% @doc Open a connection to the controller.
-spec open(host(), integer()) -> {ok, pid()} | {error, any()}.
open(Controller, Port) when is_binary(Controller) ->
    open(binary_to_list(Controller), Port);
open(Controller, Port) ->
    {ok, Pid} = ofc_receiver_sup:open(Controller, Port),
    Connection = ofc_logic:get_connection(Pid),
    {ok, Connection}.

%% @doc Send message to the controller.
-spec send(record()) -> any().
send(Message) ->
    ofc_logic:send(Message).

%% @doc Get updated connection informations.
-spec get_connection(connection()) -> connection().
get_connection(#connection{pid = Pid}) ->
    ofc_logic:get_connection(Pid).
