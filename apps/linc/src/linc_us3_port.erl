%%------------------------------------------------------------------------------
%% Copyright 2012 FlowForwarding.org
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%-----------------------------------------------------------------------------

%% @author Erlang Solutions Ltd. <openflow@erlang-solutions.com>
%% @copyright 2012 FlowForwarding.org
%% @doc Module to represent OpenFlow port.
%% It abstracts out underlying logic of either hardware network stack or virtual
%% TAP stack. It provides Open Flow ports represented as gen_server processes
%% with port configuration and statistics according to OpenFlow specification.
%% It allows to create and attach queues to given ports and supports queue
%% statistics as well. OpenFlow ports can be programatically started and
%% stopped by utilizing API provided by this module.
-module(linc_us3_port).

-behaviour(gen_server).

%% API
-export([start_link/1,
         send/2,
         change_config/2,
         list_ports/0,
         list_queues/1,
         get_port_stats/0,
         get_port_stats/1,
         get_queue_stats/0,
         get_queue_stats/1,
         get_queue_stats/2,
         attach_queue/3,
         detach_queue/2,
         remove/1]).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-include("linc_us3.hrl").

-record(state, {port :: port(),
                port_ref :: pid(),
                socket :: integer(),
                ifindex :: integer(),
                epcap_pid :: pid(),
                interface :: string(),
                ofs_port_no :: ofp_port_no(),
                rate_bps :: integer(),
                throttling_ets :: ets:tid()}).

-define(DEFAULT_QUEUE, default).

%%%-----------------------------------------------------------------------------
%%% API functions
%%%-----------------------------------------------------------------------------

%% @doc Start Open Flow port with provided configuration.
-spec start_link(list(ofs_port_config())) -> {ok, pid()} |
                                             ignore |
                                             {error, term()}.
start_link(Args) ->
    gen_server:start_link(?MODULE, Args, []).

%% @doc Send OF packet to the OF port.
-spec send(ofs_pkt(), ofp_port_no()) -> ok | bad_port | bad_queue | no_fwd.
send(#ofs_pkt{in_port = InPort} = Pkt, all) ->
    Ports = ets:tab2list(ofs_ports),
    [send(PortNo, Pkt)
     || #ofs_port{number = PortNo} <- Ports, PortNo /= InPort];
send(#ofs_pkt{in_port = InPort} = Pkt, in_port) ->
    send(InPort, Pkt);
send(Pkt, controller) ->
    linc_logic:send_to_controller(Pkt, action);
send(Pkt, PortNo) when is_integer(PortNo) ->
    case application:get_env(linc, queues) of
        undefined ->
            do_send(PortNo, Pkt);
        {ok, _} ->
            do_send_with_queue(PortNo, Pkt)
    end;
send(UnsupportedPort, _Pkt) ->
    ?WARNING("Unsupported port type: ~p", [UnsupportedPort]).

do_send(PortNo, Pkt) ->
    case get_port_pid(PortNo) of
        bad_port ->
            bad_port;
        Pid ->
            gen_server:cast(Pid, {send, Pkt})
    end.

do_send_with_queue(PortNo, Pkt) ->
    case ets:lookup(ofs_port_queue, {PortNo, Pkt#ofs_pkt.queue_id}) of
        %% XXX: move no_fwd to ETS and check it
        [#ofs_port_queue{queue_pid = Pid}] ->
            linc_us3_queue:send(Pid, Pkt);
        [] ->
            case ets:lookup(ofs_ports, PortNo) of
                [_] -> bad_queue;
                [ ] -> bad_port
            end
    end.

%% @doc Change config of the given OF port according to the provided port mod.
-spec change_config(ofp_port_no(), ofp_port_mod()) ->
                           {error, bad_port | bad_hw_addr} | ok.
change_config(PortNo, PortMod) ->
    case get_port_pid(PortNo) of
        bad_port ->
            {error, bad_port};
        %% TODO: [#ofs_port{hw_addr = OtherHWAddr}] ->
        %%           {error, bad_hw_addr};
        Pid ->
            gen_server:cast(Pid, {change_config, PortMod})
    end.

%% @doc Return list of all OF ports present in the switch.
-spec list_ports() -> [#ofs_port{}].
list_ports() ->
    ets:tab2list(ofs_ports).

%% @doc Return list of queues connected to the given OF port.
-spec list_queues(ofp_port_no()) -> [ofp_packet_queue()] | bad_port.
list_queues(PortNo) ->
    case get_port_pid(PortNo) of
        bad_port ->
            bad_port;
        Pid ->
            gen_server:call(Pid, list_queues)
    end.

%% @doc Return list of port stats records for all OF ports in the switch.
-spec get_port_stats() -> [ofp_port_stats()].
get_port_stats() ->
    ets:tab2list(port_stats).

%% @doc Retuen port stats record for the given OF port.
-spec get_port_stats(ofp_port_no()) -> ofp_port_stats() | bad_port.
get_port_stats(PortNo) ->
    %% TODO: Add support for PORT_ANY port number
    case ets:lookup(port_stats, PortNo) of
        [] ->
            bad_port;
        [Any] ->
            Any
    end.

%% @doc Return queue stats for all queues installed in the switch.
-spec get_queue_stats() -> [ofp_queue_stats()].
get_queue_stats() ->
    lists:map(fun(E) ->
                      queue_stats_convert(E)
              end, ets:tab2list(ofs_port_queue)).

get_queues(PortNo) ->
    case application:get_env(linc, queues) of
        undefined ->
            [];
        {ok, _} ->
            MatchSpec = #ofs_port_queue{key = {PortNo, '_'}, _ = '_'},
            ets:match_object(ofs_port_queue, MatchSpec)
    end.

%% @doc Return queue stats for all queues connected to the given OF port.
-spec get_queue_stats(ofp_port_no()) -> [ofp_queue_stats()].
get_queue_stats(PortNo) ->
    lists:map(fun(E) ->
                      queue_stats_convert(E)
              end, get_queues(PortNo)).

%% @doc Return queue stats for the given OF port and queue id.
-spec get_queue_stats(ofp_port_no(), ofp_queue_id()) ->
                             ofp_queue_stats() | undefined.
get_queue_stats(PortNo, QueueId) ->
    case ets:lookup(ofs_port_queue, {PortNo, QueueId}) of
        [] ->
            undefined;
        [Any] ->
            queue_stats_convert(Any)
    end.

%% @doc Create and attach queue with the given queue id and configuration to
%% the given OF port. Initializes also queue stats for this queue.
-spec attach_queue(ofp_port_no(), ofp_queue_id(), [ofp_queue_property()]) ->
                          ok | bad_port.
attach_queue(PortNo, QueueId, Properties) ->
    case get_port_pid(PortNo) of
        bad_port ->
            bad_port;
        Pid ->
            gen_server:call(Pid, {attach_queue, QueueId, Properties})
    end.

%% @doc Remove queue with the given queue id from the given OF port.
%% Removes also queue stats entry for this queue.
-spec detach_queue(ofp_port_no(), ofp_queue_id()) -> ok | bad_port.
detach_queue(PortNo, QueueId) ->
    case get_port_pid(PortNo) of
        bad_port ->
            bad_port;
        Pid ->
            gen_server:call(Pid, {detach_queue, QueueId})
    end.

%% @doc Removes given OF port from the switch, as well as its port stats entry,
%% all queues connected to it and their queue stats entries.
-spec remove(ofp_port_no()) -> ok | bad_port.
remove(PortNo) ->
    case get_port_pid(PortNo) of
        bad_port ->
            bad_port;
        Pid ->
            supervisor:terminate_child(linc_us3_port_sup, Pid)
    end.

%%%-----------------------------------------------------------------------------
%%% gen_server callbacks
%%%-----------------------------------------------------------------------------

%% @private
-spec init(list(tuple())) -> {ok, #state{}} |
                             {ok, #state{}, timeout()} |
                             ignore |
                             {stop, Reason :: term()}.
init({OfsPortNo, PortOpts}) ->
    process_flag(trap_exit, true),
    %% epcap crashes if this dir does not exist.
    filelib:ensure_dir(filename:join([code:priv_dir(epcap), "tmp", "ensure"])),

    {interface, Interface} = lists:keyfind(interface, 1, PortOpts),

    State = case re:run(Interface, "^tap.*$", [{capture, none}]) of
                %% When switch connects to a tap interface, erlang receives file
                %% descriptor to read/write ethernet frames directly from the
                %% desired /dev/tapX character device. No socket communication
                %% is involved.
                match ->
                    case tuncer:create(Interface) of
                        {ok, Ref} ->
                            case os:type() of
                                %% Under MacOS we configure TAP interfaces
                                %% programatically as they can't be created in
                                %% persistent mode before node startup.
                                {unix, darwin} ->
                                    {ip, IP} = lists:keyfind(ip, 1, PortOpts),
                                    ok = tuncer:up(Ref, IP);
                                %% We assume that under linux TAP interfaces are
                                %% already set up in persistent state and
                                %% configured with proper IP addresses.
                                {unix, linux} ->
                                    ok
                            end,
                            Fd = tuncer:getfd(Ref),
                            Port = open_port({fd, Fd, Fd}, [binary]),
                            #state{port = Port,
                                   port_ref = Ref,
                                   ofs_port_no = OfsPortNo};
                        {error, Error} ->
                            ?ERROR("Tuncer error ~p for interface ~p",
                                   [Error, Interface]),
                            {stop, shutdown}
                    end;
                %% When switch connects to a hardware interface such as eth0
                %% then communication is handled by two channels:
                %% * receiving ethernet frames is done by libpcap wrapped-up by
                %%   a epcap application
                %% * sending ethernet frames is done by writing to
                %%   a RAW socket binded with given network interface.
                %%   Handling of RAW sockets differs between OSes.
                nomatch ->
                    {ok, Pid} = epcap:start([{no_register, true},
                                             {promiscuous, true},
                                             {interface, Interface},
                                             %% to work on ipv4-less interfaces
                                             {no_lookupnet, true},
                                             %% for ethernet-only (without taps and bridges)
                                             {filter_incoming, true},
                                             {filter, ""}]),
                    {S, I} = case os:type() of
                                 {unix, darwin} ->
                                     bpf_raw_socket(Interface);
                                 {unix, netbsd} ->
                                     bpf_raw_socket(Interface);
                                 {unix, linux} ->
                                     linux_raw_socket(Interface)
                             end,
                    #state{socket = S,
                           ifindex = I,
                           epcap_pid = Pid,
                           ofs_port_no = OfsPortNo}
            end,
    case State of
        {stop, shutdown} ->
            {stop, shutdown};
        _ ->
            OfsPort = #ofs_port{number = OfsPortNo,
                                type = physical,
                                pid = self(),
                                iface = Interface,
                                port = #ofp_port{port_no = OfsPortNo}},
            ets:insert(ofs_ports, OfsPort),
            ets:insert(port_stats, #ofp_port_stats{port_no = OfsPortNo}),
            State1 = State#state{interface = Interface,
                                 ofs_port_no = OfsPortNo},

            PortState = setup_queues(State1, OfsPortNo),
            {ok, PortState}
    end.

setup_queues(State, PortNo) ->
    case application:get_env(linc, queues) of
        undefined ->
            State;
        {ok, Ports} ->
            {PortNo, QueueOpts} = lists:keyfind(PortNo, 1, Ports),
            {rate, RateDesc} = lists:keyfind(rate, 1, QueueOpts),
            Rate = rate_desc_to_bps(RateDesc),
            {queues, Queues} = lists:keyfind(queues, 1, QueueOpts),

            ThrottlingEts = ets:new(queue_throttling,
                                    [public,
                                     {read_concurrency, true},
                                     {keypos,
                                      #ofs_queue_throttling.queue_no}]),

            State2 = State#state{rate_bps = Rate,
                                 throttling_ets = ThrottlingEts},

            %% Add default queue with no min or max rate
            State3 = do_attach_queue(State2, default, []),

            lists:foldl(fun({QueueId, QueueProps}, StateAcc) ->
                                do_attach_queue(StateAcc,
                                                QueueId,
                                                QueueProps)
                       end, State3, Queues)
    end.

%% @private
-spec handle_call(Request :: term(), From :: {pid(), Tag :: term()},
                  #state{}) ->
                         {reply, Reply :: term(), #state{}} |
                         {reply, Reply :: term(), #state{}, timeout()} |
                         {noreply, #state{}} |
                         {noreply, #state{}, timeout()} |
                         {stop, Reason :: term() , Reply :: term(), #state{}} |
                         {stop, Reason :: term(), #state{}}.
handle_call(list_queues, _From, #state{ofs_port_no = PortNo} = State) ->
    Queues = [port_queue_to_packet_queue(Q) || Q <- get_queues(PortNo)],
    {reply, Queues, State};
handle_call({attach_queue, QueueId, Properties}, _From, State) ->
    NewState = do_attach_queue(State, QueueId, Properties),
    {reply, ok, NewState};
handle_call({detach_queue, QueueId}, _From, State) ->
    NewState = do_detach_queue(State, QueueId),
    {reply, ok, NewState}.

%% @private
-spec handle_cast(Msg :: term(),
                  #state{}) -> {noreply, #state{}} |
                               {noreply, #state{}, timeout()} |
                               {stop, Reason :: term(), #state{}}.
handle_cast({send, #ofs_pkt{packet = Packet}},
            #state{socket = Socket,
                   port = Port,
                   ifindex = Ifindex} = State) ->
    Frame = pkt:encapsulate(Packet),
    case {Port, Ifindex} of
        {undefined, _} ->
            send_to_wire(Socket, Ifindex, Frame);
        {_, undefined} ->
            port_command(Port, Frame)
    end,
    {noreply, State};
handle_cast({change_config, #ofp_port_mod{}}, State) ->
    %% FIXME: implement
    {noreply, State}.

%% @private
-spec handle_info(Info :: term(),
                  #state{}) -> {noreply, #state{}} |
                               {noreply, #state{}, timeout()} |
                               {stop, Reason :: term(), #state{}}.
handle_info({packet, _DataLinkType, _Time, _Length, Frame},
            #state{ofs_port_no = OfsPortNo} = State) ->
    handle_frame(Frame, OfsPortNo),
    {noreply, State};
handle_info({Port, {data, Frame}}, #state{ofs_port_no = OfsPortNo,
                                          port = Port} = State) ->
    handle_frame(Frame, OfsPortNo),
    {noreply, State};
handle_info({'EXIT', _Pid, {port_terminated, 1}},
            #state{interface = Interface} = State) ->
    ?ERROR("Port for interface ~p exited abnormally",
                [Interface]),
    {stop, normal, State};
handle_info(_Info, State) ->
    {noreply, State}.

%% @private
-spec terminate(Reason :: term(), #state{}) -> ok.
terminate(_Reason, #state{ofs_port_no = PortNo} = State) ->
    lists:foldl(fun(#ofs_port_queue{key = {_, QueueId}},
                    StateAcc) ->
                        do_detach_queue(StateAcc, QueueId)
                  end, State, get_queues(PortNo)),
    true = ets:delete(ofs_ports, PortNo),
    true = ets:delete(port_stats, PortNo),
    close_ports(State).

%% @private
-spec code_change(Vsn :: term() | {down, Vsn :: term()},
                  #state{}, Extra :: term()) ->
                         {ok, #state{}} |
                         {error, Reason :: term()}.
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%-----------------------------------------------------------------------------
%%% Internal functions
%%%-----------------------------------------------------------------------------

handle_frame(Frame, OfsPortNo) ->
    OFSPacket = linc_us3:parse_ofs_pkt(Frame, OfsPortNo),
    update_port_received_counters(OfsPortNo, byte_size(Frame)),
    linc_us3:route(OFSPacket).

-spec update_port_received_counters(integer(), integer()) -> any().
update_port_received_counters(PortNum, Bytes) ->
    ets:update_counter(port_stats, PortNum,
                       [{#ofp_port_stats.rx_packets, 1},
                        {#ofp_port_stats.rx_bytes, Bytes}]).

%% TODO: Add typespecs to bpf and procket in general to avoid:
%% linc_us3_port.erl:446: Function bpf_raw_socket/1 has no local return
%% warnings in dialyzer.
-spec bpf_raw_socket(string()) -> tuple(integer(), 0).
bpf_raw_socket(Interface) ->
    case bpf:open(Interface) of
        {ok, Socket, _Length} ->
            bpf:ctl(Socket, setif, Interface),
            {Socket, 0};
        {error, Error} ->
            ?ERROR("Cannot open bpf raw socket for"
                        " interface ~p because: ~p", [Interface, Error]),
            {0, 0};
        Any ->
            ?ERROR("Cannot open bpf raw socket for"
                        " interface ~p because: ~p", [Interface, Any]),
            {0, 0}
    end.

%% TODO: Add typespecs to packet and procket in general to avoid:
%% linc_us3_port.erl:462: Function linux_raw_socket/1 has no local return
%% warnings in dialyzer.
-spec linux_raw_socket(string()) -> tuple(integer(), integer()).
linux_raw_socket(Interface) ->
    {ok, Socket} = packet:socket(),
    Ifindex = packet:ifindex(Socket, Interface),
    packet:promiscuous(Socket, Ifindex),
    ok = packet:bind(Socket, Ifindex),
    {Socket, Ifindex}.

-spec get_port_pid(ofp_port_no()) -> pid() | bad_port.
get_port_pid(PortNo) ->
    case ets:lookup(ofs_ports, PortNo) of
        [] ->
            bad_port;
        [#ofs_port{pid = Pid}] ->
            Pid
    end.

-spec port_queue_to_packet_queue(#ofs_port_queue{}) -> #ofp_packet_queue{}.
port_queue_to_packet_queue(#ofs_port_queue{key = {PortNo, QueueId},
                                           properties = Properties}) ->
    #ofp_packet_queue{queue_id = QueueId,
                      port_no = PortNo,
                      properties = Properties}.

-spec queue_stats_convert(#ofs_port_queue{}) -> ofp_queue_stats().
queue_stats_convert(#ofs_port_queue{key = {PortNo, QueueId},
                                    tx_bytes = TxBytes,
                                    tx_packets = TxPackets,
                                    tx_errors = TxErrors}) ->
    #ofp_queue_stats{port_no = PortNo, queue_id = QueueId, tx_bytes = TxBytes,
                     tx_packets = TxPackets, tx_errors = TxErrors}.

%% TODO: Add typespecs to packet and procket in general to avoid:
%% linc_us3_port.erl:496: Function send_to_wire/3 has no local return
%% warnings in dialyzer.
-spec send_to_wire(integer(), integer(), binary()) -> ok.
send_to_wire(Socket, Ifindex, Frame) ->
    case os:type() of
        {unix, darwin} ->
            linc_us3_port_procket:send(Socket, Frame);
        {unix, netbsd} ->
            linc_us3_port_procket:send(Socket, Frame);
        {unix, linux} ->
            packet:send(Socket, Ifindex, Frame)
    end.

close_ports(#state{socket = undefined, port_ref = PortRef}) ->
    tuncer:down(PortRef),
    tuncer:destroy(PortRef);
close_ports(#state{socket = Socket, port_ref = undefined,
                          epcap_pid = EpcapPid}) ->
    %% We use catch here to avoid crashes in tests, where EpcapPid is mocked
    %% and it's an atom, not a pid.
    case catch is_process_alive(EpcapPid) of
        true ->
            epcap:stop(EpcapPid);
        _ ->
            ok
    end,
    linc_us3_port_procket:close(Socket).

rate_desc_to_bps(Bps) when is_integer(Bps) ->
    Bps;
rate_desc_to_bps({Value, Unit}) ->
    Value * unit_to_bps(Unit).

unit_to_bps(bps) -> 1;
unit_to_bps(kbps) -> 1000;
unit_to_bps(kibps) -> 1024;
unit_to_bps(mbps) -> 1000 * 1000;
unit_to_bps(mibps) -> 1024 * 1024;
unit_to_bps(gbps) -> 1000 * 1000 * 1000;
unit_to_bps(gibps) -> 1024 * 1024 * 1024.

get_min_rate_bps(QueueProps, PortRateBps) ->
    case lists:keyfind(min_rate, 1, QueueProps) of
        {min_rate, Rate} when Rate =< 1000 ->
            Rate * PortRateBps div 1000;
        false ->
            no_qos
    end.

get_max_rate_bps(QueueProps, PortRateBps) ->
    case lists:keyfind(max_rate, 1, QueueProps) of
        {max_rate, Rate} when Rate =< 1000 ->
            Rate * PortRateBps div 1000;
        _ ->
            no_max_rate
    end.

do_attach_queue(#state{socket = Socket,
                       ofs_port_no = OfsPortNo,
                       port = Port,
                       ifindex = Ifindex,
                       rate_bps = PortRateBps,
                       throttling_ets = ThrottlingEts} = State,
                QueueId,
                QueueProps) ->
    Key = {OfsPortNo, QueueId},
    case {Port, Ifindex} of
        {undefined, _} ->
            SendFun = fun(Frame) -> send_to_wire(Socket, Ifindex, Frame) end;
        {_, undefined} ->
            SendFun = fun(Frame) -> port_command(Port, Frame) end
    end,
    MinRateBps = get_min_rate_bps(QueueProps, PortRateBps),
    MaxRateBps = get_max_rate_bps(QueueProps, PortRateBps),
    {ok, Pid} = linc_us3_queue_sup:add_queue(Key,
                                             MinRateBps,
                                             MaxRateBps,
                                             PortRateBps,
                                             ThrottlingEts,
                                             SendFun),
    ets:insert(ofs_port_queue, #ofs_port_queue{key = Key,
                                               properties = QueueProps,
                                               queue_pid = Pid}),
    State.

do_detach_queue(#state{ofs_port_no = OfsPortNo,
                       throttling_ets = ThrottlingEts} = State,
                QueueId) ->
    case ets:lookup(ofs_port_queue, {OfsPortNo, QueueId}) of
        [#ofs_port_queue{queue_pid = Pid}] ->
            linc_us3_queue:detach(Pid);
        [] ->
            ok
    end,
    ets:delete(ofs_port_queue, {OfsPortNo, QueueId}),
    ets:delete(ThrottlingEts, QueueId),
    State.
