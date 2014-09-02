-module(linc_us4_oe_optical_native).

-behaviour(gen_fsm).

%% API
-export([start_link/3, stop/1, send/2, port_down/1]).

%% gen_fsm callbacks
-export([init/1, link_up/2, link_down/2, handle_event/3, port_down/2,
         handle_sync_event/4, handle_info/3, terminate/3, code_change/4]).

-define(SERVER, ?MODULE).

-record(state, {ofp_port_switch_id :: integer(),
                ofp_port_no :: integer(),
                ofp_port_pid :: pid(),
                optical_peer_pid :: pid(),
                optical_peer_monitor :: reference()}).

%%%-----------------------------------------------------------------------------
%%% API functions
%%%-----------------------------------------------------------------------------

start_link(SwitchID, PortNo, OFPortPid) ->
    gen_fsm:start_link(?MODULE, [SwitchID, PortNo, OFPortPid], []).

stop(Pid) ->
    gen_fsm:sync_send_all_state_event(Pid, stop).

send(Pid, Frame) ->
    gen_fsm:send_event(Pid, {send, Frame}).

port_down(Pid) ->
    gen_fsm:sync_send_all_state_event(Pid, port_down).

%%%-----------------------------------------------------------------------------
%%% gen_fsm callbacks
%%%-----------------------------------------------------------------------------

init([SwitchID, PortNo, Pid]) ->
    add_ofp_port_to_optical_port_mapping(SwitchID, PortNo),
    ok = linc_us4_oe_port:set_state(SwitchID, PortNo, [link_down]),
    {ok, link_down, #state{ofp_port_switch_id = SwitchID,
                           ofp_port_no = PortNo,
                           ofp_port_pid = Pid}, 0}.


link_down(timeout, #state{ofp_port_switch_id = SwitchID,
                          ofp_port_no = PortNo} = State0) ->
    State1 = State0#state{optical_peer_pid = undefined},
    try
        PeerPid = get_optical_peer_pid(SwitchID, PortNo),
        gen_fsm:send_event(PeerPid, {link_up, self()}),
        {next_state, link_down, State1#state{optical_peer_pid = PeerPid}, 500}
    catch
        throw:optical_peer_not_ready ->
            {next_state, link_down, State1, 500}
    end;
link_down({link_up, PeerPid}, #state{ofp_port_switch_id = SwitchID,
                                     ofp_port_no = PortNo,
                                     optical_peer_pid = PeerPidOrUndef}
          = State) ->
    case PeerPidOrUndef of
        undefined ->
            %% If we don't have optical_peer_pid link_up was not sent
            gen_fsm:send_event(PeerPid, {link_up, self()});
        PeerPid ->
            ok
    end,
    Ref = monitor(process, PeerPid),
    ok = linc_us4_oe_port:set_state(SwitchID, PortNo, []),
    {next_state, link_up, State#state{optical_peer_pid = PeerPid,
                                      optical_peer_monitor = Ref}}.



link_up({send, Frame}, #state{optical_peer_pid = Pid} = State) ->
    gen_fsm:send_event(Pid, {recv, Frame}),
    {next_state, link_up, State};
link_up({recv, Frame}, #state{ofp_port_pid = Pid} = State) ->
    Pid ! {optical_data, Frame},
    {next_state, link_up, State};
link_up({link_down, PeerPid}, #state{ofp_port_switch_id = SwitchID,
                                     ofp_port_no = PortNo,
                                     optical_peer_pid = PeerPid}
        = State) ->
    ok = linc_us4_oe_port:set_state(SwitchID, PortNo, [link_down]),
    {next_state, link_ready, State#state{optical_peer_pid = undefined}}.

port_down(port_up, State) ->
    {next_state, link_down, State, 0};
port_down(_Event, State) ->
    {next_state, port_down, State}.


handle_sync_event(port_down, _From, _StateName,
                  #state{optical_peer_pid = PeerPid,
                         optical_peer_monitor = Ref} = State) ->
    gen_fsm:send_event(PeerPid, {link_down, self()}),
    demonitor(Ref),
    {next_state, port_down, State#state{
                              optical_peer_pid = undefined,
                              optical_peer_monitor = undefined}};
handle_sync_event(stop, _From, _StateName, State) ->
    {stop, normal, State}.


handle_event(_Event, StateName, State) ->
    {next_state, StateName, State}.

handle_info({'DOWN', Ref, process, PeerPid, _Reason}, _StateName,
            #state{ofp_port_switch_id = SwitchID,
                   ofp_port_no = PortNo,
                   optical_peer_pid = PeerPid,
                   optical_peer_monitor = Ref} = State) ->
    ok = linc_us4_oe_port:set_state(SwitchID, PortNo, [link_down]),
    {next_state, link_down, State#state{optical_peer_pid = undefined}};
handle_info(_Info, StateName, State) ->
    {next_state, StateName, State}.

terminate(_Reason, _StateName, _State) ->
    ok.

code_change(_OldVsn, StateName, State, _Extra) ->
    {ok, StateName, State}.

%%%-----------------------------------------------------------------------------
%%% Internal functions
%%%-----------------------------------------------------------------------------

add_ofp_port_to_optical_port_mapping(SwitchID, PortNo) ->
    ets:insert(ofp_port_to_optical_link, {{SwitchID, PortNo}, self()}).

get_optical_peer_pid(SwitchID, PortNo) ->
    linc_oe:get_optical_peer_pid(SwitchID, PortNo).
