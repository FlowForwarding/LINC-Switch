%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2012, Erlang Solutions Ltd.
%%% @author Grzegorz Stanislawski <grzegorz.stanislawski@erlang-solutions.com>
%%% @doc Linux Netlink interface library module. Application Supervisor
%%% @end
%%%-----------------------------------------------------------------------------

-module(of_netlink_sup).
-behaviour(supervisor).

%% API
-export([start_link/0]).

%% Supervisor callbacks

-export([init/1]).

%% Helper macro for declaring children of supervisor
-define(CHILD(I, Type), {I, {I, start_link, []}, permanent, 5000, Type, [I]}).

%% ===================================================================
%% API functions
%% ===================================================================
-spec start_link() -> 'ignore' | {'error', term()} | {'ok',pid()}.
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% ===================================================================
%% Supervisor callbacks
%% ===================================================================

-spec init([]) -> {ok, { term(), [term()] | []}}. % | ignore | {error, term()}.
init([]) ->
    {ok, { {one_for_all, 5, 10}, [
      {   netlink_mgr, {   netlink_mgr, start_link, []}, permanent, 10000, worker, [netlink_mgr]}
%      {of_netlink_mgr, {of_netlink_mgr, start_link, []}, permanent, 10000, worker, [of_netlink_mgr]}
    ]}}.
