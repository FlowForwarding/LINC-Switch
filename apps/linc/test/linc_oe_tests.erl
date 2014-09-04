-module(linc_oe_tests).

-include_lib("eunit/include/eunit.hrl").

%% The links configuration for the following topology. Numbers in |X|
%% indicate switch id while numbers in {X} indicate ports. --- is for
%% an optical link.
%% ~~~||{1} |0| {2}||-----||{3}  |1|  {4}||-----||{5}  |2|  {6}||~~~
%% NOTE: The ports need to be unique withing a switch as they are defined
%% per capable switch.
-define(OPTICAL_LINKS, [_Link = {{_SwID = 0, _PortNo = 2}, {1, 3}},
                        {{1,4}, {2,6}}]).

%% Generators ---------------------------------------------------------

optical_utils_test_() ->
    {foreach, fun() -> set_optical_links_config() end,
     fun(_) -> ok end,
     [fun optical_links_table_should_initialize_correctly/0,
      fun adding_mapping_to_nonexistent_optical_port_should_fail/0,
      fun getting_optical_peer_for_nonexistent_ofp_port_should_fail/0,
      fun ofp_to_optical_port_table_should_initialize_correctly/0]}.

%% Tests --------------------------------------------------------------

optical_links_table_should_initialize_correctly() ->
    %% GIVEN
    OpticalPorts = get_optical_ports_from_config(),
    APort = get_non_optical_port(),
    
    %% WHEN
    linc_oe:initialize(),
    
    %% THEN
    [?assert(linc_oe:is_port_optical(SId, PNo))
     || {SId, PNo} <- OpticalPorts],
    ?assertNot(linc_oe:is_port_optical(element(1, APort),
                                       element(2, APort))).

adding_mapping_to_nonexistent_optical_port_should_fail() ->
    %% GIVEN
    NonOptical = get_non_optical_port(),

    %% WHEN
    linc_oe:initialize(),

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
    linc_oe:initialize(),

    %% THEN
    ?assertThrow(optical_port_not_exists,
                 linc_oe:get_optical_peer_pid(element(1, NonOptical),
                                              element(2, NonOptical))).

ofp_to_optical_port_table_should_initialize_correctly() ->
    %% GIVEN
    linc_oe:initialize(),
    Links = get_optical_links_from_config(),
    Ports = get_optical_ports_from_config(),
    %% [NotReady | Ready] = OpticalPorts,

    %% WHEN
    [linc_oe:add_mapping_ofp_to_optical_port(
       SId, PNo, get_pid_for_port_no(PNo)) || {SId, PNo} <- Ports],

    %% THEN
    [begin
         ExpectedPid = get_pid_for_port_no(element(2, PeerEnd)),
         ?assertEqual(ExpectedPid,
                      linc_oe:get_optical_peer_pid(SId, PNo))
     end || {{SId, PNo}, PeerEnd} <- Links].
    %% ?assertThrow(optical_peer_not_ready,
    %%              linc_oe:get_optical_peer_pid(element(1, NotReady),
    %%                                          element(2, NotReady))).

%% Helpers ------------------------------------------------------------

set_optical_links_config() ->
    application:set_env(linc, optical_links, ?OPTICAL_LINKS).

get_optical_links_from_config() ->
    {ok, Links} = application:get_env(linc, optical_links),
    Links.

get_optical_ports_from_config() ->
    lists:flatten(
      [[OneEnd, OtherEnd]|| {OneEnd, OtherEnd} <- ?OPTICAL_LINKS]).

get_non_optical_port() ->
    Optical = get_optical_ports_from_config(),
    APort = {0, 1},
    ?assertNot(lists:member(APort, Optical)),
    APort.

get_pid_for_port_no(PortNo) ->
    list_to_pid("<0.20." ++ integer_to_list(PortNo) ++ ">").
