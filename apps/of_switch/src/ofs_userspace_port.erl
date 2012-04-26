%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2012, Erlang Solutions Ltd.
%%% @doc Module to manage sending and receiving data from port.
%%% @end
%%%-----------------------------------------------------------------------------
-module(ofs_userspace_port).

-behaviour(gen_server).

%% API
-export([start_link/1,

         send/3,
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

-include("of_switch.hrl").
-include("of_switch_userspace.hrl").

-record(state, {port :: port(),
                socket :: integer(),
                ifindex :: integer(),
                interface :: string(),
                ofs_port_no :: ofp_port_no(),
                queues = [] :: [ofp_packet_queue()]}).

%%%-----------------------------------------------------------------------------
%%% API functions
%%%-----------------------------------------------------------------------------

-spec start_link(list(tuple())) -> {ok, pid()} | ignore | {error, term()}.
start_link(Args) ->
    gen_server:start_link(?MODULE, Args, []).

-spec send(ofp_port_no(), #ofs_pkt{}) -> ok.
send(OutPort, OFSPkt) ->
    send(OutPort, none, OFSPkt).

-spec send(ofp_port_no(), ofp_queue_id() | none, #ofs_pkt{}) -> ok.
send(OutPort, Queue, OFSPkt) ->
    case get_port(OutPort) of
        undefined ->
            ?ERROR("Port ~p does not exist", [OutPort]);
        #ofs_port{pid = Pid, port = #ofp_port{config = Config}} ->
            case lists:member(no_fwd, Config) of
                true ->
                    ?WARNING("Forwarding to port ~p disabled", [OutPort]);
                false ->
                    gen_server:call(Pid, {send, Queue, OFSPkt})
            end
    end.

-spec change_config(ofp_port_no(), ofp_port_mod()) ->
                           {error, bad_port | bad_hw_addr} | ok.
change_config(PortNo, PortMod) ->
    case get_port_pid(PortNo) of
        undefined ->
            {error, bad_port};
        %% TODO: [#ofs_port{hw_addr = OtherHWAddr}] ->
        %%           {error, bad_hw_addr};
        Pid ->
            gen_server:cast(Pid, {change_config, PortMod})
    end.

-spec list_ports() -> [#ofs_port{}].
list_ports() ->
    ets:tab2list(ofs_ports).

-spec list_queues(ofp_port_no()) -> [ofp_packet_queue()].
list_queues(PortNo) ->
    case get_port_pid(PortNo) of
        undefined ->
            [];
        Pid ->
            gen_server:call(Pid, list_queues)
    end.

-spec get_port_stats() -> [ofp_port_stats()].
get_port_stats() ->
    ets:tab2list(port_stats).

-spec get_port_stats(ofp_port_no()) -> ofp_port_stats() | undefined.
get_port_stats(PortNo) ->
    case ets:lookup(port_stats, PortNo) of
        [] ->
            undefined;
        [Any] ->
            Any
    end.

-spec get_queue_stats() -> [ofp_queue_stats()].
get_queue_stats() ->
    lists:map(fun(E) ->
                      queue_stats_convert(E)
              end, ets:tab2list(queue_stats)).

-spec get_queue_stats(ofp_port_no()) -> [ofp_queue_stats()].
get_queue_stats(PortNo) ->
    L = ets:match_object(queue_stats, #queue_stats{key = {PortNo, '_'}, _ = '_'}),
    lists:map(fun(E) ->
                      queue_stats_convert(E)
              end, L).

-spec get_queue_stats(ofp_port_no(), ofp_queue_id()) ->
                             ofp_queue_stats() | undefined.
get_queue_stats(PortNo, QueueId) ->
    case ets:match_object(queue_stats, #queue_stats{key = {PortNo, QueueId},
                                                    _ = '_'
                                                   }) of
        [] ->
            undefined;
        [Any] ->
            queue_stats_convert(Any)
    end.

-spec attach_queue(ofp_port_no(), ofp_queue_id(), [ofp_queue_property()]) -> ok.
attach_queue(PortNo, QueueId, Properties) ->
    Queue = #ofp_packet_queue{port_no = PortNo,
                              queue_id = QueueId,
                              properties = Properties},
    Pid = get_port_pid(PortNo),
    gen_server:cast(Pid, {attach_queue, Queue}).

-spec detach_queue(ofp_port_no(), ofp_queue_id()) -> ok.
detach_queue(PortNo, QueueId) ->
    Pid = get_port_pid(PortNo),
    gen_server:cast(Pid, {detach_queue, PortNo, QueueId}).

-spec remove(ofp_port_no()) -> ok.
remove(PortNo) ->
    case get_port_pid(PortNo) of
        undefined ->
            ok;
        Pid ->
            gen_server:call(Pid, stop)
    end.

%%%-----------------------------------------------------------------------------
%%% gen_server callbacks
%%%-----------------------------------------------------------------------------

-spec init(list(tuple())) -> {ok, #state{}} |
                             {ok, #state{}, timeout()} |
                             ignore |
                             {stop, Reason :: term()}.
init(Args) ->
    process_flag(trap_exit, true),
    %% epcap crashes if this dir does not exist.
    filelib:ensure_dir(filename:join([code:priv_dir(epcap), "tmp", "ensure"])),
    {interface, Interface} = lists:keyfind(interface, 1, Args),
    {ofs_port_no, OfsPortNo} = lists:keyfind(ofs_port_no, 1, Args),
    State = case re:run(Interface, "^tap[0-9]+$", [{capture, none}]) of
                %% When switch connects to a tap interface, erlang receives file
                %% descriptor to read/write ethernet frames directly from the
                %% desired /dev/tapX character device. No socket communication
                %% is involved.
                match ->
                    {ip, IP} = lists:keyfind(ip, 1, Args),
                    case tuncer:create(Interface) of
                        {ok, Ref} ->
                            ok = tuncer:up(Ref, IP),
                            Fd = tuncer:getfd(Ref),
                            Port = open_port({fd, Fd, Fd}, [binary]),
                            #state{port = Port, ofs_port_no = OfsPortNo};
                        {error, Error} ->
                            lager:error("Tuncer error ~p for interface ~p",
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
                    {ok, _Pid} = epcap:start([{promiscuous, true},
                                             {interface, Interface},
                                             {filter, ""}]),
                    {S, I} = case os:type() of
                                 {unix, darwin} ->
                                     darwin_raw_socket(Interface);
                                 {unix, linux} ->
                                     linux_raw_socket(Interface)
                             end,
                    #state{socket = S, ifindex = I, ofs_port_no = OfsPortNo}
            end,
    case State of
        {stop, shutdown} ->
            {stop, shutdown};
        _ ->
            OfsPort = #ofs_port{number = OfsPortNo,
                                type = physical,
                                pid = self(),
                                port = #ofp_port{port_no = OfsPortNo}},
            ets:insert(ofs_ports, OfsPort),
            ets:insert(port_stats, #ofp_port_stats{port_no = OfsPortNo}),
            {ok, State#state{interface = Interface,
                             ofs_port_no = OfsPortNo}}
    end.

-spec handle_call(Request :: term(), From :: {pid(), Tag :: term()},
                  #state{}) ->
                         {reply, Reply :: term(), #state{}} |
                         {reply, Reply :: term(), #state{}, timeout()} |
                         {noreply, #state{}} |
                         {noreply, #state{}, timeout()} |
                         {stop, Reason :: term() , Reply :: term(), #state{}} |
                         {stop, Reason :: term(), #state{}}.
handle_call(list_queues, _From, #state{queues = Queues} = State) ->
    {reply, Queues, State};
handle_call({send, Queue, OFSPkt}, _From,
            #state{socket = Socket,
                   port = undefined,
                   ifindex = Ifindex,
                   ofs_port_no = OutPort} = State) ->
    Frame = pkt:encapsulate(OFSPkt#ofs_pkt.packet),
    lager:info("Output type: socket, InPort: ~p, OutPort: ~p",
               [OFSPkt#ofs_pkt.in_port, OutPort]),
    case os:type() of
        {unix, darwin} ->
            procket:write(Socket, Frame);
        {unix, linux} ->
            packet:send(Socket, Ifindex, Frame)
    end,
    update_port_transmitted_counters(OutPort, Queue, byte_size(Frame)),
    {reply, ok, State};
handle_call({send, Queue, OFSPkt}, _From,
            #state{socket = undefined,
                   port = ErlangPort,
                   ofs_port_no = OutPort} = State) ->
    Frame = pkt:encapsulate(OFSPkt#ofs_pkt.packet),
    lager:info("Output type: erlang port, InPort: ~p, OutPort: ~p",
               [OFSPkt#ofs_pkt.in_port, OutPort]),
    port_command(ErlangPort, Frame),
    update_port_transmitted_counters(OutPort, Queue, byte_size(Frame)),
    {reply, ok, State};
handle_call(stop, _From, #state{ofs_port_no = PortNo} = State) ->
    true = ets:delete(ofs_ports, PortNo),
    true = ets:delete(port_stats, PortNo),
    true = ets:match_delete(queue_stats, #queue_stats{key = {PortNo, '_'},
                                                      _ = '_'}),
    {stop, shutdown, State};
handle_call(_Request, _From, State) ->
    {reply, ok, State}.

-spec handle_cast(Msg :: term(),
                  #state{}) -> {noreply, #state{}} |
                               {noreply, #state{}, timeout()} |
                               {stop, Reason :: term(), #state{}}.
handle_cast({attach_queue, #ofp_packet_queue{port_no = PortNo,
                                             queue_id = QueueId} = Queue},
            #state{queues = Queues} = State) ->
    ets:insert(queue_stats, #queue_stats{key = {PortNo, QueueId}}),
    {noreply, State#state{queues = [Queue | Queues]}};
handle_cast({detach_queue, PortNo, QueueId}, #state{queues = Queues} = State) ->
    ets:match_delete(queue_stats, #queue_stats{key = {PortNo, QueueId},
                                               _ = '_'}),
    NewQueues = lists:filter(fun(#ofp_packet_queue{port_no = P,
                                                   queue_id = Q})
                                   when P == PortNo andalso Q == QueueId ->
                                     false;
                                (_) ->
                                     true
                             end, Queues),
    {noreply, State#state{queues = NewQueues}};
handle_cast({change_config, #ofp_port_mod{}}, State) ->
    %% FIXME: implement
    {noreply, State};
handle_cast(_Msg, State) ->
    {noreply, State}.

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
    lager:error("Port for interface ~p exited abnormally",
                [Interface]),
    {stop, shutdown, State};
handle_info(_Info, State) ->
    {noreply, State}.

-spec terminate(Reason :: term(), #state{}) -> ok.
terminate(_Reason, _State) ->
    ok.

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
    OFSPacket = of_switch_userspace:parse_ofs_pkt(Frame, OfsPortNo),
    update_port_received_counters(OfsPortNo, byte_size(Frame)),
    of_switch_userspace:route(OFSPacket).

-spec update_port_received_counters(integer(), integer()) -> any().
update_port_received_counters(PortNum, Bytes) ->
    ets:update_counter(port_stats, PortNum,
                       [{#ofp_port_stats.rx_packets, 1},
                        {#ofp_port_stats.rx_bytes, Bytes}]).

-spec update_port_transmitted_counters(ofp_port_no(), ofp_queue_id() | none,
                                       integer()) -> any().
update_port_transmitted_counters(PortNum, Queue, Bytes) ->
    case Queue of
        none ->
            ok;
        _ ->
            try ets:update_counter(queue_stats, {PortNum, Queue},
                                   [{#queue_stats.tx_packets, 1},
                                    {#queue_stats.tx_bytes, Bytes}])
            catch
                _:_ ->
                    lager:error("Queue ~p for port ~p doesn't exist "
                                "cannot update queue stats", [Queue, PortNum])
            end
    end,
    ets:update_counter(port_stats, PortNum,
                       [{#ofp_port_stats.tx_packets, 1},
                        {#ofp_port_stats.tx_bytes, Bytes}]).

-spec darwin_raw_socket(string()) -> tuple(integer(), 0).
darwin_raw_socket(Interface) ->
    case bpf:open(Interface) of
        {ok, Socket, _Length} ->
            bpf:ctl(Socket, setif, Interface),
            {Socket, 0};
        {error, Error} ->
            lager:error("Cannot open darwin raw socket for"
                        " interface ~p because: ~p", [Interface, Error]),
            {0, 0}
    end.

-spec linux_raw_socket(string()) -> tuple(integer(), integer()).
linux_raw_socket(Interface) ->
    {ok, Socket} = packet:socket(),
    Ifindex = packet:ifindex(Socket, Interface),
    packet:promiscuous(Socket, Ifindex),
    ok = packet:bind(Socket, Ifindex),
    {Socket, Ifindex}.

-spec get_port_pid(ofp_port_no()) -> pid() | undefined.
get_port_pid(PortNo) ->
    case ets:lookup(ofs_ports, PortNo) of
        [] ->
            undefined;
        [#ofs_port{pid = Pid}] ->
            Pid
    end.

-spec get_port(ofp_port_no()) -> #ofs_port{} | undefined.
get_port(PortNo) ->
    case ets:lookup(ofs_ports, PortNo) of
        [] ->
            undefined;
        [Port] ->
            Port
    end.

-spec queue_stats_convert(#queue_stats{}) -> ofp_queue_stats().
queue_stats_convert(#queue_stats{key = {PortNo, QueueId},
                                 tx_bytes = TxBytes,
                                 tx_packets = TxPackets,
                                 tx_errors = TxErrors}) ->
    #ofp_queue_stats{port_no = PortNo, queue_id = QueueId, tx_bytes = TxBytes,
                     tx_packets = TxPackets, tx_errors = TxErrors}.
