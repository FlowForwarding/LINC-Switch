%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2012, Erlang Solutions Ltd.
%%% @doc Supervisor module for ports.
%%% @end
%%%-----------------------------------------------------------------------------
-module(ofs_userspace_port_sup).

-behaviour(supervisor).

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

%%%-----------------------------------------------------------------------------
%%% API functions
%%%-----------------------------------------------------------------------------

-spec start_link() -> {ok, pid()} | ignore | {error, term()}.
start_link() ->
    {ok, _} = supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%%%-----------------------------------------------------------------------------
%%% Supervisor callbacks
%%%-----------------------------------------------------------------------------

-spec init(list()) -> {ok, {SupFlags :: tuple(), [ChildSpec :: tuple()]}} |
                      ignore | {error, term()}.
init([]) ->
    ChildSpec = {ofs_userspace_port, {ofs_userspace_port, start_link, []},
                 transient, 5000, worker, [ofs_userspace_port]},
    {ok, {{simple_one_for_one, 5, 10}, [ChildSpec]}}.
