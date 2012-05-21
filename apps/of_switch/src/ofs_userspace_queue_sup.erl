%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2012, Erlang Solutions Ltd.
%%% @doc Supervisor module for port queues.
%%% @end
%%%-----------------------------------------------------------------------------
-module(ofs_userspace_queue_sup).

-behaviour(supervisor).

%% API
-export([start_link/0,
         add_queue/6]).

%% Supervisor callbacks
-export([init/1]).

-include("ofs_userspace.hrl").

%%%-----------------------------------------------------------------------------
%%% API functions
%%%-----------------------------------------------------------------------------

-spec start_link() -> {ok, pid()} | ignore | {error, term()}.
start_link() ->
    {ok, _} = supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-spec add_queue({ofp_port_no(), ofp_queue_id()},
                integer(),
                integer(),
                integer(),
                ets:tid(),
                fun()) -> {ok, pid()}.
add_queue(Key, MinRateBps, MaxRateBps, PortRateBps, ThrottlingEts, SendFun) ->
    supervisor:start_child(?MODULE, [Key, MinRateBps, MaxRateBps, PortRateBps, ThrottlingEts, SendFun]).

%%%-----------------------------------------------------------------------------
%%% Supervisor callbacks
%%%-----------------------------------------------------------------------------

init([]) ->
    ChildSpec = {key, {ofs_userspace_queue, start_link, []},
                 transient, 5000, worker, [ofs_userspace_queue]},
    {ok, {{simple_one_for_one, 5, 10}, [ChildSpec]}}.
