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
-export([initialize/0,
         terminate/0,
         add/2,
         remove/1,
         is_valid/1,
         start_link/1,
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
         detach_queue/2
        ]).

-include("linc_us3.hrl").
-include("linc_us3_port.hrl").

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-define(DEFAULT_QUEUE, default).

%%%-----------------------------------------------------------------------------
%%% API functions
%%%-----------------------------------------------------------------------------

initialize() ->
    linc_ports = ets:new(linc_ports, [named_table, public,
                                     {keypos, #ofs_port.number},
                                     {read_concurrency, true}]),
    linc_port_stats = ets:new(linc_port_stats,
                         [named_table, public,
                          {keypos, #ofp_port_stats.port_no},
                          {read_concurrency, true}]),
    case application:get_env(linc, queues) of
        undefined ->
            no_queues;
        {ok, _} ->
            linc_us3_queue:start()
    end,
    {ok, BackendOpts} = application:get_env(linc, backends),
    {userspace, UserspaceOpts} = lists:keyfind(userspace, 1, BackendOpts),
    {ports, UserspacePorts} = lists:keyfind(ports, 1, UserspaceOpts),
    [add(physical, Port) || Port <- UserspacePorts],
    ok.

terminate() ->
    [ok = remove(PortNo) || #ofs_port{number = PortNo} <- list_ports()],
    ets:delete(linc_ports),
    ets:delete(linc_port_stats),
    case application:get_env(linc, queues) of
        undefined ->
            ok;
        {ok, _} ->
            linc_us3_queue:stop()
    end.

%% @doc Start Open Flow port with provided configuration.
-spec start_link(list(ofs_port_config())) -> {ok, pid()} |
                                             ignore |
                                             {error, term()}.
start_link(Args) ->
    gen_server:start_link(?MODULE, Args, []).

-spec add(ofs_port_type(), [ofs_port_config()]) -> pid() | error.
add(physical, Opts) ->
    case supervisor:start_child(linc_us3_port_sup, [Opts]) of
        {ok, Pid} ->
            ?INFO("Created port: ~p", [Opts]),
            Pid;
        {error, shutdown} ->
            ?ERROR("Cannot create port ~p", [Opts]),
            error
    end;
add(logical, _Opts) ->
    error;
add(reserved, _Opts) ->
    error.

%% @doc Send OF packet to the OF port.
-spec send(ofs_pkt(), ofp_port_no()) -> ok | bad_port | bad_queue | no_fwd.
send(#ofs_pkt{in_port = InPort} = Pkt, all) ->
    Ports = ets:tab2list(linc_ports),
    [send(Pkt, PortNo)
     || #ofs_port{number = PortNo} <- Ports, PortNo /= InPort];
send(#ofs_pkt{in_port = InPort} = Pkt, in_port) ->
    send(Pkt, InPort);
send(Pkt, controller) ->
    linc_logic:send_to_controllers(Pkt, action);
send(Pkt, PortNo) when is_integer(PortNo) ->
    case application:get_env(linc, queues) of
        undefined ->
            do_send(Pkt, PortNo);
        {ok, _} ->
            do_send_with_queue(Pkt, PortNo)
    end;
send(_Pkt, UnsupportedPort) ->
    ?WARNING("Unsupported port type: ~p", [UnsupportedPort]).

do_send(Pkt, PortNo) ->
    case get_port_pid(PortNo) of
        bad_port ->
            bad_port;
        Pid ->
            gen_server:cast(Pid, {send, Pkt})
    end.

do_send_with_queue(Pkt, PortNo) ->
    case ets:lookup(ofs_port_queue, {PortNo, Pkt#ofs_pkt.queue_id}) of
        %% XXX: move no_fwd to ETS and check it
        [#ofs_port_queue{queue_pid = Pid}] ->
            linc_us3_queue:send(Pid, Pkt);
        [] ->
            case ets:lookup(linc_ports, PortNo) of
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
    ets:tab2list(linc_ports).

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
    ets:tab2list(linc_port_stats).

%% @doc Retuen port stats record for the given OF port.
-spec get_port_stats(ofp_port_no()) -> ofp_port_stats() | bad_port.
get_port_stats(PortNo) ->
    %% TODO: Add support for PORT_ANY port number
    case ets:lookup(linc_port_stats, PortNo) of
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

%% @doc Test if a port exists.
-spec is_valid(ofp_port_no()) -> boolean().
is_valid(OfsPort) ->
    ets:member(linc_ports, OfsPort).

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
    State = #state{interface = Interface, ofs_port_no = OfsPortNo},

    case re:run(Interface, "^tap.*$", [{capture, none}]) of
        %% When switch connects to a tap interface, erlang receives file
        %% descriptor to read/write ethernet frames directly from the
        %% desired /dev/tapX character device. No socket communication
        %% is involved.
        match ->
            case linc_us3_port_native:tap(Interface, PortOpts) of
                {stop, shutdown} ->
                    {stop, shutdown};
                {Port, Pid} ->
                    State2 = State#state{port = Port, port_ref = Pid},
                    NewState = setup_port_and_queues(State2),
                    {ok, NewState}
                end;
        %% When switch connects to a hardware interface such as eth0
        %% then communication is handled by two channels:
        %% * receiving ethernet frames is done by libpcap wrapped-up by
        %%   a epcap application
        %% * sending ethernet frames is done by writing to
        %%   a RAW socket binded with given network interface.
        %%   Handling of RAW sockets differs between OSes.
        nomatch ->
            {Socket, IfIndex, EpcapPid} = linc_us3_port_native:eth(Interface),
            State2 = State#state{socket = Socket,
                                 ifindex = IfIndex,
                                 epcap_pid = EpcapPid},
            NewState = setup_port_and_queues(State2),
            {ok, NewState}
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
            linc_us3_port_native:send(Socket, Ifindex, Frame);
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
    true = ets:delete(linc_ports, PortNo),
    true = ets:delete(linc_port_stats, PortNo),
    linc_us3_port_native:close(State).

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

-spec setup_port_and_queues(#state{}) -> #state{}.
setup_port_and_queues(#state{interface = Interface,
                            ofs_port_no = OfsPortNo} = State) ->
    OfsPort = #ofs_port{number = OfsPortNo,
                        type = physical,
                        pid = self(),
                        iface = Interface,
                        port = #ofp_port{port_no = OfsPortNo}},
    ets:insert(linc_ports, OfsPort),
    ets:insert(linc_port_stats, #ofp_port_stats{port_no = OfsPortNo}),
    setup_queues(State).

-spec setup_queues(#state{}) -> #state{}.
setup_queues(#state{ofs_port_no = PortNo} = State) ->
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

handle_frame(Frame, OfsPortNo) ->
    OFSPacket = linc_us3_packet_edit:binary_to_record(Frame, OfsPortNo),
    update_port_received_counters(OfsPortNo, byte_size(Frame)),
    linc_us3_routing:spawn_route(OFSPacket).

-spec update_port_received_counters(integer(), integer()) -> any().
update_port_received_counters(PortNum, Bytes) ->
    ets:update_counter(linc_port_stats, PortNum,
                       [{#ofp_port_stats.rx_packets, 1},
                        {#ofp_port_stats.rx_bytes, Bytes}]).

-spec get_port_pid(ofp_port_no()) -> pid() | bad_port.
get_port_pid(PortNo) ->
    case ets:lookup(linc_ports, PortNo) of
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
            SendFun = fun(Frame) ->
                              linc_us3_port_native:send(Socket, Ifindex, Frame)
                      end;
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
