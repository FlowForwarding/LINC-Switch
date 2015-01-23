-module(linc_us4_oe_optical_native).

-behaviour(gen_fsm).

%% API
-export([start_link/3, stop/1, send/2, port_down/1, port_up/1]).

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

start_link(SwitchId, PortNo, OFPortPid) ->
    gen_fsm:start_link(?MODULE, [SwitchId, PortNo, OFPortPid], []).

stop(Pid) ->
    gen_fsm:sync_send_all_state_event(Pid, stop).

send(Pid, Msg) ->
    gen_fsm:send_event(Pid, {send, Msg}).

port_down(Pid) ->
    gen_fsm:send_all_state_event(Pid, port_down).

port_up(Pid) ->
    gen_fsm:send_event(Pid, port_up).

%%%-----------------------------------------------------------------------------
%%% gen_fsm callbacks
%%%-----------------------------------------------------------------------------

init([SwitchId, PortNo, Pid]) ->
    add_ofp_port_to_optical_port_mapping(SwitchId, PortNo),
    {ok, link_down, #state{ofp_port_switch_id = SwitchId,
                           ofp_port_no = PortNo,
                           ofp_port_pid = Pid}, 0}.

link_down(timeout, #state{optical_peer_pid = Pid} = State) when is_pid(Pid) ->
    {stop, optical_peer_not_responding, State};
link_down(timeout, #state{ofp_port_switch_id = SwitchId,
                          ofp_port_no = PortNo} = State) ->
    try
        PeerPid = get_optical_peer_pid(SwitchId, PortNo),
        gen_fsm:send_event(PeerPid, {link_up, self()}),
        {next_state, link_down,
         State#state{optical_peer_pid = PeerPid}, 1000}
    catch
        throw:optical_peer_not_ready ->
            {next_state, link_down, State, 500}
    end;
link_down({link_up, PeerPid}, #state{ofp_port_switch_id = SwitchId,
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
    ok = linc_us4_oe_port:set_state(SwitchId, PortNo, []),
    {next_state, link_up, State#state{optical_peer_pid = PeerPid,
                                      optical_peer_monitor = Ref}};
link_down(_Event, State) ->
    % port is waiting for peer to come up after simulated link failure.
    % ignore sends/recvs until link is back up.
    {next_state, link_down, State}.

link_up({send, Msg}, #state{optical_peer_pid = PeerPid} = State) ->
    gen_fsm:send_event(PeerPid, {recv, Msg}),
    {next_state, link_up, State};
link_up({recv, Msg}, #state{ofp_port_pid = Pid} = State) ->
    Pid ! {optical_data, self(), Msg},
    {next_state, link_up, State};
link_up({link_down, PeerPid},
        % link down sent from the peer port
        #state{ofp_port_switch_id = SwitchId,
               ofp_port_no = PortNo,
               optical_peer_pid = PeerPid} = State) ->
        ok = linc_us4_oe_port:set_state(SwitchId, PortNo, [link_down]),
    % wait for the peer to come back up
    {next_state, link_down, State#state{optical_peer_pid = undefined}}.

port_down(port_up, State) ->
    % this port is simulating the link failure.
    % wait for the admin to restore the link.
    {next_state, link_down, State, 0};
port_down(_Event, State) ->
    {next_state, port_down, State}.

handle_sync_event(stop, _From, _StateName, State) ->
    {stop, normal, ok, State};
handle_sync_event(Event, _From, _StateName, State) ->
    {stop, bad_event, {bad_event, Event}, State}.

handle_event(port_down, _StateName, State0) ->
    % port down sent by command utility
    State1 = handle_link_down(State0),
    {next_state, port_down, State1};
handle_event(stop, _StateName, State) ->
    {stop, normal, State}.

handle_info({'DOWN', Ref, process, PeerPid, _Reason}, _StateName,
            #state{optical_peer_pid = PeerPid,
                   optical_peer_monitor = Ref} = State0) ->
    State1 = handle_link_down(State0),
    {next_state, link_down, State1};
handle_info(_Info, StateName, State) ->
    {next_state, StateName, State}.

terminate(_Reason, _StateName, _State) ->
    ok.

code_change(_OldVsn, StateName, State, _Extra) ->
    {ok, StateName, State}.

%%%-----------------------------------------------------------------------------
%%% Internal functions
%%%-----------------------------------------------------------------------------

add_ofp_port_to_optical_port_mapping(SwitchId, PortNo) ->
    linc_oe:add_mapping_ofp_to_optical_port(SwitchId, PortNo, self()).

get_optical_peer_pid(SwitchId, PortNo) ->
    linc_oe:get_optical_peer_pid(SwitchId, PortNo).

handle_link_down(#state{ofp_port_switch_id = SwitchId,
                        ofp_port_no = PortNo,
                        optical_peer_pid = PeerPid,
                        optical_peer_monitor = Ref} = State) ->
    ok = linc_us4_oe_port:set_state(SwitchId, PortNo, [link_down]),
    gen_fsm:send_event(PeerPid, {link_down, self()}),
    demonitor(Ref),
    State#state{optical_peer_pid = undefined,
                optical_peer_monitor = undefined}.
