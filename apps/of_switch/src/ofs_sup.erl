%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2012, Erlang Solutions Ltd.
%%% @doc OpenFlow Logical Switch main supervisor module.
%%% @end
%%%-----------------------------------------------------------------------------
-module(ofs_sup).

-behaviour(supervisor).

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

-define(CHILD(I, Type), {I, {I, start_link, []}, transient, 5000, Type, [I]}).

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
    UserspacePortSup = {ofs_userspace_port_sup,
                        {ofs_userspace_port_sup, start_link, []},
                        permanent, 5000, supervisor, [ofs_userspace_port_sup]},
    SwitchLogic = {ofs_logic,
                   {ofs_logic, start_link, [of_switch_userspace, []]},
                   permanent, 5000, worker, [ofs_logic]},
    ReceiverSup = {ofs_receiver_sup,
                   {ofs_receiver_sup, start_link, []},
                   permanent, 5000, supervisor, [ofs_receiver_sup]},
    {ok, {{one_for_all, 5, 10}, [
                                 UserspacePortSup,
                                 ReceiverSup,
                                 SwitchLogic
                                ]}}.
