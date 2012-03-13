%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2012, Erlang Solutions Ltd.
%%% @author Grzegorz Stanislawski <grzegorz.stanislawski@erlang-solutions.com>
%%% @doc Wrapper library for mocking.
%%% @end
%%%-----------------------------------------------------------------------------

-module(netlink_meck).
-compile(export_all).


port_open(A,B) ->  erlang:open_port(A,B).

port_send(A, B) -> erlang:port_command(A,B).

procket_open(A, B) -> procket:open(A,B).

procket_connect(A, B) -> procket:connect(A,B).
procket_close(A) -> procket:close(A).
