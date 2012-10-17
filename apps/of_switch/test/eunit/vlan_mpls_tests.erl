-module(unit_vlan_mpls).
-export([test_push/0, test_pop/0]).

-include_lib("eunit/include/eunit.hrl").
-include("ofs_userspace.hrl").

%%%-----------------------------------------------------------------------------
%%% EUnit tests
%%%-----------------------------------------------------------------------------

vlan_mpls_test_() ->
    {setup,
     fun setup/0,
     fun teardown/1,
     fun (Config) ->
             [
                test_pop(),
                test_push()
             ]
     end}.

decaps(File) ->
    io:format("current dir ~p~n", [filename:absname("")]),
    {ok, F1} = file:read_file("test/eunit/" ++ File ++ ".cap"),
    pkt:decapsulate(F1).

test_pop() ->
    io:format("TEST POP~n"),
    P = decaps("vlan_ping"),
    io:format("P=~p~n", [P]),
    P2 = ofs_userspace_routing:action_pop_vlan(
        #ofp_action_pop_vlan{},
        #ofs_pkt{packet = P, size = 100}),
    P2.

test_push() ->
    io:format("TEST PUSH~n"),
    P = decaps("vlan_ping"),
    io:format("P=~p~n", [P]),
    P2 = ofs_userspace_routing:action_push_vlan(
        #ofp_action_push_vlan{ ethertype = 12345678},
        #ofs_pkt{packet = P, size = 100}),
    P2.

