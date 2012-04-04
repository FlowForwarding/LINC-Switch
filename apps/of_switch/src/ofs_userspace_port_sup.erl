%%%-------------------------------------------------------------------
%%% @doc
%%%
%%% @end
%%%-------------------------------------------------------------------
-module(ofs_userspace_port_sup).

-behaviour(supervisor).

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).
-define(CHILD(I, Type), {I, {I, start_link, []}, transient, 5000, Type, [I]}).

%%%===================================================================
%%% API functions
%%%===================================================================

-spec start_link() -> {ok, pid()} | ignore | {error, term()}.
start_link() ->
    {ok, _} = supervisor:start_link({local, ?SERVER}, ?MODULE, []).

%%%===================================================================
%%% Supervisor callbacks
%%%===================================================================

-spec init(list()) -> {ok, {SupFlags :: tuple(), [ChildSpec :: tuple()]}} |
                      ignore |
                      {error, term()}.
init([]) ->
    {ok, { {simple_one_for_one, 5, 10}, [
                                         ?CHILD(ofs_userspace_physical_port,
                                                worker)
                                        ]} }.

%%%===================================================================
%%% Internal functions
%%%===================================================================
