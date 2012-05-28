%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2012, Erlang Solutions Ltd.
%%% @doc Supervisor module for the receiver processes.
%%% @end
%%%-----------------------------------------------------------------------------
-module(ofs_receiver_sup).
-author("Erlang Solutions Ltd. <openflow@erlang-solutions.com>").


-behaviour(supervisor).

%% API
-export([start_link/0, open/2, close/2]).

%% Supervisor callbacks
-export([init/1]).

%%%-----------------------------------------------------------------------------
%%% API functions
%%%-----------------------------------------------------------------------------

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

open(Controller, Port) ->
    Id = list_to_atom(Controller ++ "_" ++ integer_to_list(Port)),
    ChildSpec = {Id, {ofs_receiver, start_link, [Id, Controller, Port]},
                 permanent, 5000, worker, [ofs_receiver]},
    supervisor:start_child(ofs_receiver_sup, ChildSpec).

-spec close(string(), integer()) -> ok.
close(Controller, Port) ->
    Id = list_to_atom(Controller ++ "_" ++ integer_to_list(Port)),
    supervisor:terminate_child(ofs_receiver_sup, Id),
    supervisor:delete_child(ofs_receiver_sup, Id).

%%%-----------------------------------------------------------------------------
%%% Supervisor callbacks
%%%-----------------------------------------------------------------------------

init([]) ->
    {ok, {{one_for_one, 5, 10}, []}}.
