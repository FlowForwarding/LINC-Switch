%%%-----------------------------------------------------------------------------
%%% Use is subject to License terms.
%%% @copyright (C) 2012 FlowForwarding.org
%%% @doc OpenFlow Logical Switch main supervisor module.
%%% @end
%%%-----------------------------------------------------------------------------
-module(ofs_sup).
-author("Erlang Solutions Ltd. <openflow@erlang-solutions.com>").

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

init([]) ->
    UserspaceQueueSup = {ofs_userspace_queue_sup,
                         {ofs_userspace_queue_sup, start_link, []},
                         permanent, 5000, supervisor, [ofs_userspace_queue_sup]},
    UserspacePortSup = {ofs_userspace_port_sup,
                        {ofs_userspace_port_sup, start_link, []},
                        permanent, 5000, supervisor, [ofs_userspace_port_sup]},
    SwitchLogic = {ofs_logic,
                   {ofs_logic, start_link, [ofs_userspace, []]},
                   permanent, 5000, worker, [ofs_logic]},
    ReceiverSup = {ofs_receiver_sup,
                   {ofs_receiver_sup, start_link, []},
                   permanent, 5000, supervisor, [ofs_receiver_sup]},
    {ok, {{one_for_all, 5, 10}, [
                                 UserspaceQueueSup,
                                 UserspacePortSup,
                                 ReceiverSup,
                                 SwitchLogic
                                ]}}.
