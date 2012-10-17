-module(vlan_mpls_tests).

-compile(export_all).

-include_lib("eunit/include/eunit.hrl").
-include("ofs_userspace.hrl").
-include_lib("pkt/include/pkt.hrl").

setup() ->
    code:add_path("../../../deps/pkt/ebin").

%%%-----------------------------------------------------------------------------
%%% EUnit tests
%%%-----------------------------------------------------------------------------

decaps(File) ->
    %% Current directory for running eunit is project/.eunit, so go up and down to test/
    CurDir = filename:absname(""),
    %%io:format(user, "current dir ~p file ~p~n", [CurDir, File]),
    {ok, F1} = file:read_file("../test/eunit/" ++ File ++ ".cap"),
    pkt:decapsulate(F1).

%%-----------------------------------------------------------------------------
%% @doc Counts #ieee802_1q_tag{} in the pkt:packet()
-spec count_vlan_headers(pkt:packet()) -> integer().

count_vlan_headers(Pkt) ->
    %%io:format(user, "vlan count headers ~p~n", [Pkt]),
    count_vlan_headers_(Pkt, 0).

count_vlan_headers_([], Count) -> Count;
count_vlan_headers_([#ieee802_1q_tag{} | Rest], Count) -> count_vlan_headers_(Rest, Count + 1);
count_vlan_headers_([_ | Rest], Count) -> count_vlan_headers_(Rest, Count).

%%-----------------------------------------------------------------------------
%% @doc Loads a packet capture with 2 VLAN headers, counts them, pops one,
%% checks that only 1 left, and has tag 'ieee802_1q_tag'
pop_test() ->
    setup(),
    P1 = decaps("vlan_ping"),
    H1 = count_vlan_headers(P1),
    ?assertEqual(H1, 2),
    
    OfsP = ofs_userspace_routing:action_pop_vlan(
            #ofp_action_pop_vlan{},
            #ofs_pkt{packet = P1, size = 100}),
    
    %% ensure that packet now contains only 1 VLAN header.
    #ofs_pkt{packet = P2} = OfsP,
    ?assertEqual(count_vlan_headers(P2), 1),
    %% extract list item 2, check for correct tag
    ?assertEqual(element(1, hd(tl(P2))), ieee802_1q_tag).

%%-----------------------------------------------------------------------------
%% @doc Loads a packet capture with 2 VLAN headers, counts them, pushes one,
%% checks that its 3 now, and all of them have tag 'ieee802_1q_tag'
push_test() ->
    setup(),
    P1 = decaps("vlan_ping"),
    ?assertEqual(count_vlan_headers(P1), 2),
    
    OfsP = ofs_userspace_routing:action_push_vlan(
            #ofp_action_push_vlan{ ethertype = 12345678 },
            #ofs_pkt{packet = P1, size = 100}),
    
    %% ensure that packet now contains only 1 VLAN header.
    #ofs_pkt{packet = P2} = OfsP,
    ?assertEqual(count_vlan_headers(P2), 3),
    %% extract list items 2, 3, 4, check that all have correct tag
    P2Tl = tl(P2),
    ?assertEqual(element(1, hd(P2Tl)), ieee802_1q_tag),
    ?assertEqual(element(1, hd(tl(P2Tl))), ieee802_1q_tag),
    ?assertEqual(element(1, hd(tl(tl(P2Tl)))), ieee802_1q_tag).

