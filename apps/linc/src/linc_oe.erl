-module(linc_oe).

-export([initialize/0, get_optical_peer_pid/2,
         add_mapping_ofp_to_optical_port/3, is_port_optical/2]).

-define(OPTICAL_LINKS_ETS, optical_ports).
-define(OFP_TO_OPTICAL_PORT_ETS, ofp_ports_to_optical_ports).

initialize() ->
    init_optical_links_ets(),
    init_ofp_to_optical_ports_map_ets().

get_optical_peer_pid(SwitchID, PortNo) ->
    throw(optical_peer_not_ready).

add_mapping_ofp_to_optical_port(SwitchID, PortNo, Pid) ->
    ok.

is_port_optical(SwitchID, PortNo) ->
    false.

init_optical_links_ets() ->
    ok.

init_ofp_to_optical_ports_map_ets() ->
    ok.
