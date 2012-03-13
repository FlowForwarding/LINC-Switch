%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2012, Erlang Solutions Ltd.
%%% @author Grzegorz Stanislawski <grzegorz.stanislawski@erlang-solutions.com>
%%% @doc Linux Netlink interface library module. Application module.
%%% @end
%%%-----------------------------------------------------------------------------

-module(of_netlink_app).
-behaviour(application).

%% Application callbacks
-export([start/2, stop/1]).
%% ===================================================================
%% Application callbacks
%% ===================================================================

start(_StartType, _StartArgs) ->
    of_netlink_sup:start_link().

stop(_State) ->
    ok.
