%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2012, Erlang Solutions Ltd.
%%% @doc Callback module for OpenFlow Logical Switch application.
%%% @end
%%%-----------------------------------------------------------------------------
-module(ofs_app).
-author("Erlang Solutions Ltd. <openflow@erlang-solutions.com>").


-behaviour(application).

%% Application callbacks
-export([start/2, stop/1]).

%%%-----------------------------------------------------------------------------
%%% Application callbacks
%%%-----------------------------------------------------------------------------

%% @doc Start the application.
-spec start(any(), any()) -> {ok, pid()}.
start(_StartType, _StartArgs) ->
    ofs_sup:start_link().

%% @doc Stop the application
-spec stop(any()) -> ok.
stop(_State) ->
    ok.
