-module(linc_oe).

-export([initialize/0, get_optical_peer_pid/2,
         add_mapping_ofp_port_to_optical_link/2, is_port_optical/2]).

initialize() ->
    init_optical_links_ets(),
    init_optical_links_to_pids_ets().

get_optical_peer_pid(SwitchID, PortNo) ->
    throw(optical_peer_not_ready).

add_mapping_ofp_port_to_optical_link(SwitchID, PortNo) ->
    ok.

is_port_optical(SwitchID, PortNo) ->
    false.

init_optical_links_ets() ->
    ok.

init_optical_links_to_pids_ets() ->
    ok.
