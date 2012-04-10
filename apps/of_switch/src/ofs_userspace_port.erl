%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2012, Erlang Solutions Ltd.
%%% @doc Module to manage sending and receiving data from port.
%%% @end
%%%-----------------------------------------------------------------------------
-module(ofs_userspace_port).

-behaviour(gen_server).

%% API
-export([start_link/1,
         send/2,
         stop/1]).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-include_lib("of_switch/include/of_switch_userspace.hrl").

-record(state, {socket :: integer(),
                port_num :: integer()}).

%%%-----------------------------------------------------------------------------
%%% API functions
%%%-----------------------------------------------------------------------------

-spec start_link(list(tuple())) -> {ok, pid()} | ignore | {error, term()}.
start_link(Args) ->
    gen_server:start_link(?MODULE, Args, []).

-spec send(integer(), #ofs_pkt{}) -> noport | ok.
send(PortId, OFSPkt) ->
    case ets:lookup(ofs_ports, PortId) of
        [] ->
            noport;
        [#ofs_port{handle = Pid}] ->
            gen_server:call(Pid, {send, PortId, OFSPkt})
    end.

-spec stop(pid()) -> ok.
stop(Pid) ->
    gen_server:cast(Pid, stop).

%%%-----------------------------------------------------------------------------
%%% gen_server callbacks
%%%-----------------------------------------------------------------------------

-spec init(list(tuple())) -> {ok, #state{}} |
                             {ok, #state{}, timeout()} |
                             ignore |
                             {stop, Reason :: term()}.
init(Args) ->
    %% epcap crashes if this dir does not exist.
    filelib:ensure_dir(filename:join([code:priv_dir(epcap), "tmp", "ensure"])),
    {interface, Interface} = lists:keyfind(interface, 1, Args),
    {portnum, PortNum} = lists:keyfind(portnum, 1, Args),
    epcap:start([{promiscous, true}, {interface, Interface}]),
    {ok, Socket, _Length} = bpf:open(Interface),
    bpf:ctl(Socket, setif, Interface),
    {ok, #state{socket = Socket,
                port_num = PortNum}}.

-spec handle_call(Request :: term(), From :: {pid(), Tag :: term()},
                  #state{}) ->
                         {reply, Reply :: term(), #state{}} |
                         {reply, Reply :: term(), #state{}, timeout()} |
                         {noreply, #state{}} |
                         {noreply, #state{}, timeout()} |
                         {stop, Reason :: term() , Reply :: term(), #state{}} |
                         {stop, Reason :: term(), #state{}}.
handle_call({send, PortId, OFSPkt}, _From, #state{socket = Socket} = State) ->
    Frame = pkt:encapsulate(OFSPkt#ofs_pkt.packet),
    procket:write(Socket, Frame),
    update_port_transmitted_counters(PortId, byte_size(Frame)),
    {reply, ok, State};
handle_call(_Request, _From, State) ->
    {reply, ok, State}.

-spec handle_cast(Msg :: term(),
                  #state{}) -> {noreply, #state{}} |
                               {noreply, #state{}, timeout()} |
                               {stop, Reason :: term(), #state{}}.
handle_cast(stop, State) ->
    {stop, shutdown, State};
handle_cast(_Msg, State) ->
    {noreply, State}.

-spec handle_info(Info :: term(),
                  #state{}) -> {noreply, #state{}} |
                               {noreply, #state{}, timeout()} |
                               {stop, Reason :: term(), #state{}}.
handle_info({packet, _DataLinkType, _Time, _Length, Frame},
            #state{port_num = PortNum} = State) ->
    Packet = pkt:decapsulate(Frame),
    OFSPacket = of_switch_userspace:pkt_to_ofs(Packet, PortNum),
    update_port_received_counters(PortNum, byte_size(Frame)),
    of_switch_userspace:route(OFSPacket),
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

-spec terminate(Reason :: term(), #state{}) -> none().
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

-spec update_port_received_counters(integer(), integer()) -> any().
update_port_received_counters(PortNum, Bytes) ->
    ets:update_counter(ofs_port_counters, PortNum,
                       [{#ofs_port_counter.received_packets, 1},
                        {#ofs_port_counter.received_bytes, Bytes}]).

-spec update_port_transmitted_counters(integer(), integer()) -> any().
update_port_transmitted_counters(PortNum, Bytes) ->
    ets:update_counter(ofs_port_counters, PortNum,
                       [{#ofs_port_counter.transmitted_packets, 1},
                        {#ofs_port_counter.transmitted_bytes, Bytes}]).
