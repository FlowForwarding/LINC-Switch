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
-module(linc_us4_port).

-behaviour(gen_server).

%% Port API
-export([start_link/1,
         initialize/0,
         terminate/0,
         modify/1,
         send/2,
         get_desc/0,
         get_stats/1,
         get_state/1,
         set_state/2,
         get_config/1,
         set_config/2,
         is_valid/1]).

-include_lib("of_protocol/include/of_protocol.hrl").
-include_lib("of_protocol/include/ofp_v4.hrl").
-include_lib("linc/include/linc_logger.hrl").
-include("linc_us4.hrl").
-include("linc_us4_port.hrl").

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

%%%-----------------------------------------------------------------------------
%%% API functions
%%%-----------------------------------------------------------------------------

%% @doc Start Open Flow port with provided configuration.
-spec start_link(list(linc_port_config())) -> {ok, pid()} |
                                              ignore |
                                              {error, term()}.
start_link(Args) ->
    gen_server:start_link(?MODULE, Args, []).

-spec initialize() -> ok.
initialize() ->
    linc_ports = ets:new(linc_ports, [named_table, public,
                                      {keypos, #linc_port.port_no},
                                      {read_concurrency, true}]),
    linc_port_stats = ets:new(linc_port_stats,
                              [named_table, public,
                               {keypos, #ofp_port_stats.port_no},
                               {read_concurrency, true}]),
    case queues_enabled() of
        true ->
            linc_us4_queue:initialize();
        false ->
            ok
    end,
    case application:get_env(linc, backends_opts) of
        {ok, Backends} ->
            {linc_us4, Opts} = lists:keyfind(linc_us4, 1, Backends),
            {ports, UserspacePorts} = lists:keyfind(ports, 1, Opts),
            [add(physical, Port) || Port <- UserspacePorts];
        undefined ->
            ok
    end,
    ok.

-spec terminate() -> ok.
terminate() ->
    [ok = remove(PortNo) || PortNo <- get_all_port_no()],
    true = ets:delete(linc_ports),
    true = ets:delete(linc_port_stats),
    case queues_enabled() of
        true ->
            linc_us4_queue:terminate();
        false ->
            ok
    end.

%% @doc Change config of the given OF port according to the provided port mod.
-spec modify(ofp_port_mod()) -> ok | {error, {Type :: atom(), Code :: atom()}}.
modify(#ofp_port_mod{port_no = PortNo} = PortMod) ->
    case get_port_pid(PortNo) of
        bad_port ->
            {error, {bad_request, bad_port}};
        Pid ->
            gen_server:call(Pid, {port_mod, PortMod})
    end.

%% @doc Send OF packet to the OF port.
-spec send(linc_pkt(), ofp_port_no()) -> ok | bad_port | bad_queue | no_fwd.
send(#linc_pkt{in_port = InPort} = Pkt, in_port) ->
    send(Pkt, InPort);
send(#linc_pkt{} = Pkt, table) ->
    linc_us4_routing:spawn_route(Pkt),
    ok;
send(#linc_pkt{}, normal) ->
    %% Normal port represents traditional non-OpenFlow pipeline of the switch
    %% not supprted by LINC
    bad_port;
send(#linc_pkt{}, flood) ->
    %% Flood port represents traditional non-OpenFlow pipeline of the switch
    %% not supprted by LINC
    bad_port;
send(#linc_pkt{in_port = InPort} = Pkt, all) ->
    [send(Pkt, PortNo) || PortNo <- get_all_port_no(), PortNo /= InPort],
    ok;
send(#linc_pkt{no_packet_in = true}, controller) ->
    %% Drop packets which originate from port with no_packet_in config flag set
    ok;
send(#linc_pkt{no_packet_in = false, fields = Fields, packet = Packet,
               table_id = TableId, packet_in_reason = Reason, 
               packet_in_bytes = Bytes, cookie = Cookie},
     controller) ->
    {BufferId,Data} = maybe_buffer(Reason, Packet, Bytes),
    PacketIn = #ofp_packet_in{buffer_id = BufferId, reason = Reason,
                              table_id = TableId, cookie = Cookie,
                              match = Fields, data = Data},
    linc_logic:send_to_controllers(#ofp_message{body = PacketIn}),
    ok;
send(#ofp_port_status{} = PortStatus, controller) ->
    linc_logic:send_to_controllers(#ofp_message{body = PortStatus}),
    ok;
send(#linc_pkt{}, local) ->
    ?WARNING("Unsupported port type: local", []),
    bad_port;
send(#linc_pkt{}, any) ->
    %% Special value used in some OpenFlow commands when no port is specified
    %% (port wildcarded).
    %% Can not be used as an ingress port nor as an output port.
    bad_port;
send(#linc_pkt{} = Pkt, PortNo) when is_integer(PortNo) ->
    case get_port_pid(PortNo) of
        bad_port ->
            bad_port;
        Pid ->
            gen_server:cast(Pid, {send, Pkt})
    end.

%% @doc Return list of all OFP ports present in the switch.
-spec get_desc() -> ofp_port_desc_reply().
get_desc() ->
    L = ets:foldl(fun(#linc_port{pid = Pid}, Ports) ->
                          Port = gen_server:call(Pid, get_port),
                          [Port | Ports]
                  end, [], linc_ports),
    #ofp_port_desc_reply{body = L}.

%% @doc Return port stats record for the given OF port.
-spec get_stats(ofp_port_stats_request()) -> ofp_port_stats_reply() |
                                             ofp_error_msg().
get_stats(#ofp_port_stats_request{port_no = any}) ->
    PortStats = ets:tab2list(linc_port_stats),
    #ofp_port_stats_reply{body = convert_duration(PortStats)};
get_stats(#ofp_port_stats_request{port_no = PortNo}) ->
    case ets:lookup(linc_port_stats, PortNo) of
        [] ->
            #ofp_error_msg{type = bad_request, code = bad_port};
        [#ofp_port_stats{}] = PortStats ->
            #ofp_port_stats_reply{body = convert_duration(PortStats)}
    end.

-spec get_state(ofp_port_no()) -> [ofp_port_state()].
get_state(PortNo) ->
    case get_port_pid(PortNo) of
        bad_port ->
            {error, {bad_request, bad_port}};
        Pid ->
            gen_server:call(Pid, get_port_state)
    end.

-spec set_state(ofp_port_no(), [ofp_port_state()]) -> ok.
set_state(PortNo, PortState) ->
    case get_port_pid(PortNo) of
        bad_port ->
            {error, {bad_request, bad_port}};
        Pid ->
            gen_server:call(Pid, {set_port_state, PortState})
    end.

-spec get_config(ofp_port_no()) -> [ofp_port_config()].
get_config(PortNo) ->
    case get_port_pid(PortNo) of
        bad_port ->
            {error, {bad_request, bad_port}};
        Pid ->
            gen_server:call(Pid, get_port_config)
    end.

-spec set_config(ofp_port_no(), [ofp_port_config()]) -> ok.
set_config(PortNo, PortConfig) ->
    case get_port_pid(PortNo) of
        bad_port ->
            {error, {bad_request, bad_port}};
        Pid ->
            gen_server:call(Pid, {set_port_config, PortConfig})
    end.

%% @doc Test if a port exists.
-spec is_valid(ofp_port_no()) -> boolean().
is_valid(PortNo) when is_atom(PortNo)->
    true;
is_valid(PortNo) when is_integer(PortNo)->
    ets:member(linc_ports, PortNo).

%%%-----------------------------------------------------------------------------
%%% gen_server callbacks
%%%-----------------------------------------------------------------------------

%% @private
init({PortNo, PortOpts}) ->
    process_flag(trap_exit, true),
    %% epcap crashes if this dir does not exist.
    filelib:ensure_dir(filename:join([code:priv_dir(epcap), "tmp", "ensure"])),
    Port = #ofp_port{port_no = PortNo,
                     name = list_to_binary("Port" ++ integer_to_list(PortNo)),
                     config = [], state = [live],
                     curr = [other], advertised = [other],
                     supported = [other], peer = [other],
                     curr_speed = ?PORT_SPEED, max_speed = ?PORT_SPEED},
    QueuesState = case queues_enabled() of
                      false ->
                          disabled;
                      true ->
                          enabled
                  end,
    {interface, Interface} = lists:keyfind(interface, 1, PortOpts),
    State = #state{interface = Interface, port = Port, queues = QueuesState},

    case re:run(Interface, "^tap.*$", [{capture, none}]) of
        %% When switch connects to a tap interface, erlang receives file
        %% descriptor to read/write ethernet frames directly from the
        %% desired /dev/tapX character device. No socket communication
        %% is involved.
        match ->
            case linc_us4_port_native:tap(Interface, PortOpts) of
                {stop, shutdown} ->
                    {stop, shutdown};
                {ErlangPort, Pid, HwAddr} ->
                    ets:insert(linc_ports,
                               #linc_port{port_no = PortNo, pid = self()}),
                    ets:insert(linc_port_stats,
                               #ofp_port_stats{port_no = PortNo,
                                               duration_sec = erlang:now()}),
                    case queues_config() of
                        disabled ->
                            disabled;
                        QueuesConfig ->
                            SendFun = fun(Frame) ->
                                              port_command(ErlangPort, Frame)
                                      end,
                            linc_us4_queue:attach_all(PortNo, SendFun,
                                                      QueuesConfig)
                    end,
                    {ok, State#state{erlang_port = ErlangPort,
                                     port_ref = Pid,
                                     port = Port#ofp_port{hw_addr = HwAddr}}}
            end;
        %% When switch connects to a hardware interface such as eth0
        %% then communication is handled by two channels:
        %% * receiving ethernet frames is done by libpcap wrapped-up by
        %%   a epcap application
        %% * sending ethernet frames is done by writing to
        %%   a RAW socket binded with given network interface.
        %%   Handling of RAW sockets differs between OSes.
        nomatch ->
            {Socket, IfIndex, EpcapPid, HwAddr} =
                linc_us4_port_native:eth(Interface),
            case queues_config() of
                disabled ->
                    disabled;
                QueuesConfig ->
                    SendFun = fun(Frame) ->
                                      linc_us4_port_native:send(Socket, IfIndex, Frame)
                              end,
                    linc_us4_queue:attach_all(PortNo, SendFun, QueuesConfig)
            end,
            ets:insert(linc_ports,
                       #linc_port{port_no = PortNo, pid = self()}),
            ets:insert(linc_port_stats,
                       #ofp_port_stats{port_no = PortNo,
                                       duration_sec = erlang:now()}),
            {ok, State#state{socket = Socket,
                             ifindex = IfIndex,
                             epcap_pid = EpcapPid,
                             port = Port#ofp_port{hw_addr = HwAddr}}}
    end.

%% @private
handle_call({port_mod, #ofp_port_mod{hw_addr = PMHwAddr,
                                     config = Config,
                                     mask = _Mask,
                                     advertise = Advertise}}, _From,
            #state{port = #ofp_port{hw_addr = HWAddr} = Port} = State) ->
    {Reply, NewPort} = case PMHwAddr == HWAddr of
                           true ->
                               {ok, Port#ofp_port{config = Config,
                                                  advertised = Advertise}};
                           false ->
                               {{error, {bad_request, bad_hw_addr}}, Port}
                       end,
    {reply, Reply, State#state{port = NewPort}};
handle_call(get_port, _From, #state{port = Port} = State) ->
    {reply, Port, State};
handle_call(get_port_state, _From,
            #state{port = #ofp_port{state = PortState}} = State) ->
    {reply, PortState, State};
handle_call({set_port_state, NewPortState}, _From,
            #state{port = Port} = State) ->
    NewPort = Port#ofp_port{state = NewPortState},
    PortStatus = #ofp_port_status{reason = modify,
                                  desc = NewPort},
    send(PortStatus, controller),
    {reply, ok, State#state{port = NewPort}};
handle_call(get_port_config, _From,
            #state{port = #ofp_port{config = PortConfig}} = State) ->
    {reply, PortConfig, State};
handle_call({set_port_config, NewPortConfig}, _From,
            #state{port = Port} = State) ->
    NewPort = Port#ofp_port{config = NewPortConfig},
    PortStatus = #ofp_port_status{reason = modify,
                                  desc = NewPort},
    send(PortStatus, controller),
    {reply, ok, State#state{port = NewPort}}.

%% @private
handle_cast({send, #linc_pkt{packet = Packet, queue_id = QueueId}},
            #state{socket = Socket,
                   port = #ofp_port{port_no = PortNo,
                                    config = PortConfig},
                   erlang_port = Port,
                   queues = QueuesState,
                   ifindex = Ifindex} = State) ->
    case lists:member(no_fwd, PortConfig) of
        true ->
            drop;
        false ->
            Frame = pkt:encapsulate(Packet),
            update_port_tx_counters(PortNo, byte_size(Frame)),
            case QueuesState of
                disabled ->
                    case {Port, Ifindex} of
                        {undefined, _} ->
                            linc_us4_port_native:send(Socket, Ifindex, Frame);
                        {_, undefined} ->
                            port_command(Port, Frame)
                    end;
                enabled ->
                    linc_us4_queue:send(PortNo, QueueId, Frame)
            end
    end,
    {noreply, State}.

%% @private
handle_info({packet, _DataLinkType, _Time, _Length, Frame},
            #state{port = #ofp_port{port_no = PortNo,
                                    config = PortConfig}} = State) ->
    handle_frame(Frame, PortNo, PortConfig),
    {noreply, State};
handle_info({Port, {data, Frame}}, #state{port = #ofp_port{port_no = PortNo,
                                                           config = PortConfig},
                                          erlang_port = Port} = State) ->
    handle_frame(Frame, PortNo, PortConfig),
    {noreply, State};
handle_info({'EXIT', _Pid, {port_terminated, 1}},
            #state{interface = Interface} = State) ->
    ?ERROR("Port for interface ~p exited abnormally",
           [Interface]),
    {stop, normal, State};
handle_info(_Info, State) ->
    {noreply, State}.

%% @private
terminate(_Reason, #state{port = #ofp_port{port_no = PortNo}} = State) ->
    case queues_enabled() of
        true ->
            linc_us4_queue:detach_all(PortNo);
        false ->
            ok
    end,
    true = ets:delete(linc_ports, PortNo),
    true = ets:delete(linc_port_stats, PortNo),
    linc_us4_port_native:close(State).

%% @private
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%-----------------------------------------------------------------------------
%%% Internal functions
%%%-----------------------------------------------------------------------------

%% @doc Return list of all OFP port nuumbers present in the switch.
-spec get_all_port_no() -> [integer()].
get_all_port_no() ->
    Ports = ets:tab2list(linc_ports),
    lists:map(fun(#linc_port{port_no = PortNo}) ->
                      PortNo
              end, Ports).

-spec add(linc_port_type(), [linc_port_config()]) -> pid() | error.
add(physical, Opts) ->
    case supervisor:start_child(linc_us4_port_sup, [Opts]) of
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

%% @doc Removes given OF port from the switch, as well as its port stats entry,
%% all queues connected to it and their queue stats entries.
-spec remove(ofp_port_no()) -> ok | bad_port.
remove(PortNo) ->
    case get_port_pid(PortNo) of
        bad_port ->
            bad_port;
        Pid ->
            ok = supervisor:terminate_child(linc_us4_port_sup, Pid)
    end.

handle_frame(Frame, PortNo, PortConfig) ->
    case lists:member(no_recv, PortConfig) of
        true ->
            drop;
        false ->
            LincPkt = linc_us4_packet:binary_to_record(Frame, PortNo),
            update_port_rx_counters(PortNo, byte_size(Frame)),
            case lists:member(no_packet_in, PortConfig) of
                false ->
                    linc_us4_routing:spawn_route(LincPkt);
                true ->
                    linc_us4_routing:spawn_route(LincPkt#linc_pkt{no_packet_in = true})
            end
    end.

-spec update_port_rx_counters(integer(), integer()) -> any().
update_port_rx_counters(PortNum, Bytes) ->
    ets:update_counter(linc_port_stats, PortNum,
                       [{#ofp_port_stats.rx_packets, 1},
                        {#ofp_port_stats.rx_bytes, Bytes}]).

-spec update_port_tx_counters(integer(), integer()) -> any().
update_port_tx_counters(PortNum, Bytes) ->
    ets:update_counter(linc_port_stats, PortNum,
                       [{#ofp_port_stats.tx_packets, 1},
                        {#ofp_port_stats.tx_bytes, Bytes}]).

-spec get_port_pid(ofp_port_no()) -> pid() | bad_port.
get_port_pid(PortNo) ->
    case ets:lookup(linc_ports, PortNo) of
        [] ->
            bad_port;
        [#linc_port{pid = Pid}] ->
            Pid
    end.

-spec convert_duration(list(#ofp_port_stats{})) -> list(#ofp_port_stats{}).
convert_duration(PortStatsList) ->
    lists:map(fun(#ofp_port_stats{duration_sec = DSec} = PortStats) ->
                      MicroDuration = timer:now_diff(erlang:now(), DSec),
                      Sec = microsec_to_sec(MicroDuration),
                      NSec = microsec_to_nsec(MicroDuration),
                      PortStats#ofp_port_stats{duration_sec = Sec,
                                               duration_nsec = NSec}
              end, PortStatsList).

microsec_to_sec(Micro) ->
    Micro div 1000000.

microsec_to_nsec(Micro) ->
    (Micro rem 1000) * 1000.

maybe_buffer(action, Packet, no_buffer) ->
    {no_buffer,pkt:encapsulate(Packet)};
maybe_buffer(action, Packet, Bytes) ->
    maybe_buffer(Packet, Bytes);
maybe_buffer(no_match, Packet, _Bytes) ->
    maybe_buffer(Packet, get_switch_config(miss_send_len));
maybe_buffer(invalid_ttl, Packet, _Bytes) ->
    %% The spec does not specify how many bytes to include for invalid_ttl,
    %% so we use miss_send_len here as well.
    maybe_buffer(Packet, get_switch_config(miss_send_len)).

maybe_buffer(Packet, no_buffer) ->
    {no_buffer, pkt:encapsulate(Packet)};
maybe_buffer(Packet, Bytes) ->
    BufferId = linc_buffer:save_buffer(Packet),
    {BufferId, truncate_packet(Packet,Bytes)}.

truncate_packet(Packet,Bytes) -> 
    Bin = pkt:encapsulate(Packet),
    case byte_size(Bin) > Bytes of
        true ->
            <<Head:Bytes/bytes, _/binary>> = Bin,
            Head;
        false ->
            Bin
    end.

get_switch_config(miss_send_len) ->
    %%TODO: get this from the switch configuration
    no_buffer.

-spec queues_enabled() -> boolean().
queues_enabled() ->
    case application:get_env(linc, backends_opts) of
        {ok, Backends} ->
            {linc_us4, Opts} = lists:keyfind(linc_us4, 1, Backends),
            case lists:keyfind(queues_status, 1, Opts) of
                false ->
                    false;
                {queues_status, enabled} ->
                    true;
                _ ->
                    false
            end;
        undefined  ->
            false
    end.

-spec queues_config() -> [term()] | disabled.
queues_config() ->
    case queues_enabled() of
        true ->
            {ok, Backends} = application:get_env(linc, backends_opts),
            {linc_us4, Opts} = lists:keyfind(linc_us4, 1, Backends),
            case lists:keyfind(queues, 1, Opts) of
                false ->
                    disabled;
                {queues, Queues} ->
                    Queues
            end;
        false ->
            disabled
    end.
