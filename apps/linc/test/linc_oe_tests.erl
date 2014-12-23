-module(linc_oe_tests).

-include_lib("eunit/include/eunit.hrl").

%% The links configuration for the following topology. Numbers in |X|
%% indicate switch id while numbers in {X} indicate ports. --- is for
%% an optical link.
%% ~~~||{1} |0| {2}||-----||{3}  |1|  {4}||-----||{5}  |2|  {6}||~~~
%% NOTE: The ports need to be unique withing a switch as they are defined
%% per capable switch.
-define(OPTICAL_LINKS, [_Link = {{_SwID = 0, _PortNo = 2}, {1, 3}},
                        {{1,4}, {2,5}}]).

%% Generators ---------------------------------------------------------

optical_utils_test_() ->
    {foreach,
     fun () -> linc_oe:initialize(?OPTICAL_LINKS) end,
     fun (_) -> linc_oe:terminate() end,
    [fun optical_links_table_should_initialize_correctly/0,
     fun adding_mapping_to_nonexistent_optical_port_should_fail/0,
     fun getting_optical_peer_for_nonexistent_ofp_port_should_fail/0,
     fun ofp_to_optical_port_table_should_initialize_correctly/0,
     fun getting_not_ready_optical_peer_pid_should_fail/0]}.

%% Tests --------------------------------------------------------------

optical_links_table_should_initialize_correctly() ->
    %% GIVEN
    OpticalPorts = get_optical_ports(),
    APort = get_non_optical_port(),
    
    %% WHEN
    %% Nothing happens
    
    %% THEN
    [?assert(linc_oe:is_port_optical(SId, PNo))
     || {SId, PNo} <- OpticalPorts],
    ?assertNot(linc_oe:is_port_optical(element(1, APort),
                                       element(2, APort))).

adding_mapping_to_nonexistent_optical_port_should_fail() ->
    %% GIVEN
    NonOptical = get_non_optical_port(),

    %% WHEN
    %% Nothing happens
    
    %% THEN
    ?assertThrow(
       optical_port_not_exists,
       linc_oe:add_mapping_ofp_to_optical_port(element(1, NonOptical),
                                               element(2, NonOptical),
                                               self())).

getting_optical_peer_for_nonexistent_ofp_port_should_fail() ->
    %% GIVEN
    NonOptical = get_non_optical_port(),

    %% WHEN
    %% Nothing happens
    
    %% THEN
    ?assertThrow(optical_port_not_exists,
                 linc_oe:get_optical_peer_pid(element(1, NonOptical),
                                              element(2, NonOptical))).

ofp_to_optical_port_table_should_initialize_correctly() ->
    %% GIVEN
    Ports = get_optical_ports(),

    %% WHEN
    [linc_oe:add_mapping_ofp_to_optical_port(
       SId, PNo, get_pid_for_port_no(PNo)) || {SId, PNo} <- Ports],

    %% THEN
    [assert_ofp_port_to_optical_peer_mappings_correct(L)
     || L <- ?OPTICAL_LINKS].

getting_not_ready_optical_peer_pid_should_fail() ->
    %% GIVEN
    Ports = get_optical_ports(),

    %% WHEN
    %% no mappings between ofp ports and optical ports are added

    %% THEN
    [?assertThrow(optical_peer_not_ready,
                  linc_oe:get_optical_peer_pid(SId, PNo))
     || {SId, PNo} <- Ports].

%% Helpers ------------------------------------------------------------

get_optical_ports() ->
    lists:flatten(
      [[OneEnd, OtherEnd]|| {OneEnd, OtherEnd} <- ?OPTICAL_LINKS]).

get_non_optical_port() ->
    Optical = get_optical_ports(),
    APort = {0, 1},
    ?assertNot(lists:member(APort, Optical)),
    APort.

get_pid_for_port_no(PortNo) ->
    list_to_pid("<0.20." ++ integer_to_list(PortNo) ++ ">").

assert_ofp_port_to_optical_peer_mappings_correct(Link) ->
    Ends = tuple_to_list(Link),
    [begin  
         ExpectedPid = get_pid_for_port_no(element(2, OtherEnd)),
         ?assertEqual(ExpectedPid,
                      linc_oe:get_optical_peer_pid(element(1, OneEnd),
                                                   element(2, OneEnd)))
     end || [OneEnd, OtherEnd] <- [Ends, lists:reverse(Ends)]].
