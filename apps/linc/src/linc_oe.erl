-module(linc_oe).

-export([initialize/1, terminate/0, get_optical_peer_pid/2,
         add_mapping_ofp_to_optical_port/3, is_port_optical/2]).

-define(OPTICAL_LINKS_ETS, optical_ports).
-define(OFP_TO_OPTICAL_PORT_ETS, ofp_ports_to_optical_ports).

%%%--------------------------------------------------------------------
%%% API functions
%%%--------------------------------------------------------------------

initialize(Links) ->
    init_optical_links_ets(Links),
    init_ofp_to_optical_ports_map_ets(Links).

terminate() ->
    [true = ets:delete(T) || T <- [?OPTICAL_LINKS_ETS,
                                   ?OFP_TO_OPTICAL_PORT_ETS]].

get_optical_peer_pid(SwitchId, PortNo) ->
    {NSwitchId, NPortNo} = get_neighbour_for_ofp_port(SwitchId, PortNo),
    get_optical_port_pid_for_ofp_port(NSwitchId, NPortNo).
    
add_mapping_ofp_to_optical_port(SwitchId, PortNo, Pid)
  when is_pid(Pid)->
    case ets:update_element(?OFP_TO_OPTICAL_PORT_ETS,
                            {SwitchId, PortNo}, {2, Pid}) of
        true ->
            ok;
        false ->
            throw(optical_port_not_exists)
    end.

is_port_optical(SwitchId, PortNo) ->
    Port = {SwitchId, PortNo},
    [x] == [x || Pattern <- [{Port, '_'}, {'_', Port}],
                 ets:match(?OPTICAL_LINKS_ETS, Pattern) /= []].

%%%--------------------------------------------------------------------
%%% Internal functions
%%%--------------------------------------------------------------------

init_optical_links_ets(Links) ->
    ets:new(?OPTICAL_LINKS_ETS, [named_table, public]),
    [ets:insert(?OPTICAL_LINKS_ETS, {OneEnd, OtherEnd})
     || {OneEnd, OtherEnd} <- Links].

init_ofp_to_optical_ports_map_ets(Links) ->
    OFPPorts = lists:flatten([tuple_to_list(L) || L <- Links]),
    ets:new(?OFP_TO_OPTICAL_PORT_ETS, [named_table, public]),
    [ets:insert(?OFP_TO_OPTICAL_PORT_ETS, {P, _FuturePid = undefined})
     || P <- OFPPorts].

get_neighbour_for_ofp_port(SwitchId, PortNo) ->
    Port = {SwitchId, PortNo},
    Neigbour0 = ets:match(?OPTICAL_LINKS_ETS, {Port, '$1'}),
    Neigbour1 = case Neigbour0 of
                    [] ->
                        ets:match(?OPTICAL_LINKS_ETS, {'$1', Port});
                    N ->
                        N
                end,
    Neigbour1 == [] andalso throw(optical_port_not_exists),
    [[Neigbour2]] =  Neigbour1,
    Neigbour2.

get_optical_port_pid_for_ofp_port(SwitchId, PortNo) ->
    case ets:lookup_element(?OFP_TO_OPTICAL_PORT_ETS,
                           {SwitchId, PortNo}, 2)
    of
        undefined ->
            throw(optical_peer_not_ready);
        Pid ->
            Pid
    end.
