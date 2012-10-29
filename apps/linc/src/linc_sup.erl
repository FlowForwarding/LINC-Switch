%%%-----------------------------------------------------------------------------
%%% Use is subject to License terms.
%%% @copyright (C) 2012 FlowForwarding.org
%%% @doc OpenFlow Logical Switch main supervisor module.
%%% @end
%%%-----------------------------------------------------------------------------
-module(linc_sup).
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
    {ok, {BackendMod, BackendOpts}} = application:get_env(linc, backend),
    SwitchLogic = {linc_logic,
                   {linc_logic, start_link, [BackendMod, BackendOpts]},
                   permanent, 5000, worker, [linc_logic]},
    ReceiverSup = {linc_receiver_sup,
                   {linc_receiver_sup, start_link, []},
                   permanent, 5000, supervisor, [linc_receiver_sup]},
    OFConfig = {linc_ofconfig,
                {linc_ofconfig, start_link, []},
                permanent, 5000, worker, [linc_ofconfig]},
    {ok, {{one_for_all, 5, 10}, [ReceiverSup,
                                 SwitchLogic,
                                 OFConfig]}}.
