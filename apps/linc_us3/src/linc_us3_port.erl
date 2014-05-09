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

%% Port API
-export([start_link/2,
         initialize/2,
         terminate/1,
         modify/2,
         send/2,
         get_ports/1,
         get_stats/2,
         get_state/2,
         set_state/3,
         get_config/2,
         set_config/3,
         get_features/2,
         get_advertised_features/2,
         set_advertised_features/3,
         get_all_ports_state/1,
         get_all_queues_state/1,
         is_valid/2]).

-include_lib("of_config/include/of_config.hrl").
-include_lib("of_protocol/include/of_protocol.hrl").
-include_lib("of_protocol/include/ofp_v3.hrl").
-include_lib("linc/include/linc_logger.hrl").
-include("linc_us3.hrl").
-include("linc_us3_port.hrl").

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
-spec start_link(integer(), list(linc_port_config())) -> {ok, pid()} |
                                                         ignore |
                                                         {error, term()}.
start_link(SwitchId, PortConfig) ->
    gen_server:start_link(?MODULE, [SwitchId, PortConfig], []).

-spec initialize(integer(), tuple(config, list(linc_port_config()))) -> ok.
initialize(SwitchId, Config) ->
    LincPorts = ets:new(linc_ports, [public,
                                     {keypos, #linc_port.port_no},
                                     {read_concurrency, true}]),
    LincPortStats = ets:new(linc_port_stats,
                            [public,
                             {keypos, #ofp_port_stats.port_no},
                             {read_concurrency, true}]),
    linc:register(SwitchId, linc_ports, LincPorts),
    linc:register(SwitchId, linc_port_stats, LincPortStats),
    case queues_enabled(SwitchId) of
        true ->
            linc_us3_queue:initialize(SwitchId);
        false ->
            ok
    end,
    UserspacePorts = ports_for_switch(SwitchId, Config),
    [add(physical, SwitchId, Port) || Port <- UserspacePorts],
    ok.

-spec terminate(integer()) -> ok.
terminate(SwitchId) ->
    [ok = remove(SwitchId, PortNo) || PortNo <- get_all_port_no(SwitchId)],
    true = ets:delete(linc:lookup(SwitchId, linc_ports)),
    true = ets:delete(linc:lookup(SwitchId, linc_port_stats)),
    case queues_enabled(SwitchId) of
        true ->
            linc_us3_queue:terminate(SwitchId);
        false ->
            ok
    end.

%% @doc Change config of the given OF port according to the provided port mod.
-spec modify(integer(), ofp_port_mod()) -> ok |
                                           {error, {Type :: atom(),
                                                    Code :: atom()}}.
modify(SwitchId, #ofp_port_mod{port_no = PortNo} = PortMod) ->
    case get_port_pid(SwitchId, PortNo) of
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
    linc_us3_routing:spawn_route(Pkt),
    ok;
send(#linc_pkt{}, normal) ->
    %% Normal port represents traditional non-OpenFlow pipeline of the switch
    %% not supprted by LINC
    bad_port;
send(#linc_pkt{}, flood) ->
    %% Flood port represents traditional non-OpenFlow pipeline of the switch
    %% not supprted by LINC
    bad_port;
send(#linc_pkt{in_port = InPort, switch_id = SwitchId} = Pkt, all) ->
    [send(Pkt, PortNo) || PortNo <- get_all_port_no(SwitchId), PortNo /= InPort],
    ok;
send(#linc_pkt{no_packet_in = true}, controller) ->
    %% Drop packets which originate from port with no_packet_in config flag set
    ok;
send(#linc_pkt{no_packet_in = false, fields = Fields, packet = Packet,
              table_id = TableId, packet_in_reason = Reason,
              packet_in_bytes = Bytes, switch_id = SwitchId},
     controller) ->
    {BufferId,Data} = maybe_buffer(SwitchId, Reason, Packet, Bytes),
    PacketIn = #ofp_packet_in{buffer_id = BufferId, reason = Reason,
                              table_id = TableId, match = Fields,
                              data = Data},
    linc_logic:send_to_controllers(SwitchId, #ofp_message{body = PacketIn}),
    ok;
send(#linc_pkt{}, local) ->
    ?WARNING("Unsupported port type: local", []),
    bad_port;
send(#linc_pkt{}, any) ->
    %% Special value used in some OpenFlow commands when no port is specified
    %% (port wildcarded).
    %% Can not be used as an ingress port nor as an output port.
    bad_port;
send(#linc_pkt{switch_id = SwitchId} = Pkt, PortNo) when is_integer(PortNo) ->
    case get_port_pid(SwitchId, PortNo) of
        bad_port ->
            bad_port;
        Pid ->
            gen_server:cast(Pid, {send, Pkt})
    end.

%% @doc Return list of all OFP ports present in the switch.
-spec get_ports(integer()) -> [#ofp_port{}].
get_ports(SwitchId) ->
    ets:foldl(fun(#linc_port{pid = Pid}, Ports) ->
                      Port = gen_server:call(Pid, get_port),
                      [Port | Ports]
              end, [], linc:lookup(SwitchId, linc_ports)).

%% @doc Return port stats record for the given OF port.
-spec get_stats(integer(), ofp_port_stats_request()) -> ofp_port_stats_reply() |
                                                        ofp_error_msg().
get_stats(SwitchId, #ofp_port_stats_request{port_no = any}) ->
    PortStats = ets:tab2list(linc:lookup(SwitchId, linc_port_stats)),
    #ofp_port_stats_reply{stats = PortStats};
get_stats(SwitchId, #ofp_port_stats_request{port_no = PortNo}) ->
    case ets:lookup(linc:lookup(SwitchId, linc_port_stats), PortNo) of
        [] ->
            #ofp_error_msg{type = bad_request, code = bad_port};
        [#ofp_port_stats{}] = PortStats ->
            #ofp_port_stats_reply{stats = PortStats}
    end.

-spec get_state(integer(), ofp_port_no()) -> [ofp_port_state()].
get_state(SwitchId, PortNo) ->
    case get_port_pid(SwitchId, PortNo) of
        bad_port ->
            {error, {bad_request, bad_port}};
        Pid ->
            gen_server:call(Pid, get_port_state)
    end.

-spec set_state(integer(), ofp_port_no(), [ofp_port_state()]) -> ok.
set_state(SwitchId, PortNo, PortState) ->
    case get_port_pid(SwitchId, PortNo) of
        bad_port ->
            {error, {bad_request, bad_port}};
        Pid ->
            gen_server:call(Pid, {set_port_state, PortState})
    end.

-spec get_config(integer(), ofp_port_no()) -> [ofp_port_config()].
get_config(SwitchId, PortNo) ->
    case get_port_pid(SwitchId, PortNo) of
        bad_port ->
            {error, {bad_request, bad_port}};
        Pid ->
            gen_server:call(Pid, get_port_config)
    end.

-spec set_config(integer(), ofp_port_no(), [ofp_port_config()]) -> ok.
set_config(SwitchId, PortNo, PortConfig) ->
    case get_port_pid(SwitchId, PortNo) of
        bad_port ->
            {error, {bad_request, bad_port}};
        Pid ->
            gen_server:call(Pid, {set_port_config, PortConfig})
    end.

-spec get_features(integer(), ofp_port_no()) -> tuple([ofp_port_feature()],
                                                      [ofp_port_feature()],
                                                      [ofp_port_feature()],
                                                      [ofp_port_feature()]).
get_features(SwitchId, PortNo) ->
    case get_port_pid(SwitchId, PortNo) of
        bad_port ->
            {error, {bad_request, bad_port}};
        Pid ->
            gen_server:call(Pid, get_features)
    end.

-spec get_advertised_features(integer(), ofp_port_no()) -> [ofp_port_feature()].
get_advertised_features(SwitchId, PortNo) ->
    case get_port_pid(SwitchId, PortNo) of
        bad_port ->
            {error, {bad_request, bad_port}};
        Pid ->
            gen_server:call(Pid, get_advertised_features)
    end.

-spec set_advertised_features(integer(), ofp_port_no(), [ofp_port_feature()]) -> ok.
set_advertised_features(SwitchId, PortNo, AdvertisedFeatures) ->
    case get_port_pid(SwitchId, PortNo) of
        bad_port ->
            {error, {bad_request, bad_port}};
        Pid ->
            gen_server:call(Pid, {set_advertised_features, AdvertisedFeatures})
    end.

-spec get_all_ports_state(integer()) -> list({ResourceId :: string(),
                                              ofp_port()}).
get_all_ports_state(SwitchId) ->
    lists:map(fun(PortNo) ->
                      Pid = get_port_pid(SwitchId, PortNo),
                      gen_server:call(Pid, get_info)
              end, get_all_port_no(SwitchId)).

-spec get_all_queues_state(integer()) -> list(tuple(string(), integer(), integer(),
                                                    integer(), integer())).
get_all_queues_state(SwitchId) ->
    lists:flatmap(fun(PortNo) ->
                          linc_us3_queue:get_all_queues_state(SwitchId, PortNo)
                  end, get_all_port_no(SwitchId)).

%% @doc Test if a port exists.
-spec is_valid(integer(), ofp_port_no()) -> boolean().
is_valid(_SwitchId, PortNo) when is_atom(PortNo)->
    true;
is_valid(SwitchId, PortNo) when is_integer(PortNo)->
    ets:member(linc:lookup(SwitchId, linc_ports), PortNo).

%%%-----------------------------------------------------------------------------
%%% gen_server callbacks
%%%-----------------------------------------------------------------------------

%% @private
init([SwitchId, {port, PortNo, PortOpts}]) ->
    process_flag(trap_exit, true),
    %% epcap crashes if this dir does not exist.
    filelib:ensure_dir(filename:join([code:priv_dir(epcap), "tmp", "ensure"])),
    PortName = "Port" ++ integer_to_list(PortNo),
    Advertised = case lists:keyfind(features, 1, PortOpts) of
                     false ->
                         ?FEATURES;
                     {features, undefined} ->
                         ?FEATURES;
                     {features, Features} ->
                         linc_ofconfig:convert_port_features(Features)
                 end,
    PortConfig = case lists:keyfind(config, 1, PortOpts) of
                     false ->
                         [];
                     {config, undefined} ->
                         [];
                     {config, Config} ->
                         linc_ofconfig:convert_port_config(Config)
                 end,
    Port = #ofp_port{port_no = PortNo,
                     name = PortName,
                     config = PortConfig,
                     state = [live],
                     curr = ?FEATURES,
                     advertised = Advertised,
                     supported = ?FEATURES, peer = ?FEATURES,
                     curr_speed = ?PORT_SPEED, max_speed = ?PORT_SPEED},
    QueuesState = case queues_enabled(SwitchId) of
                      false ->
                          disabled;
                      true ->
                          enabled
                  end,
    SwitchName = "LogicalSwitch" ++ integer_to_list(SwitchId),
    ResourceId =  SwitchName ++ "-" ++ PortName,
    {interface, Interface} = lists:keyfind(interface, 1, PortOpts),
    State = #state{resource_id = ResourceId, interface = Interface, port = Port,
                   queues = QueuesState, switch_id = SwitchId},
    Type = case lists:keyfind(type, 1, PortOpts) of
        {type, Type1} ->
            Type1;
        _ ->
            %% The type is not specified explicitly.
            %% Guess from the interface name.
            case re:run(Interface, "^tap.*$", [{capture, none}]) of
                match ->
                    tap;
                nomatch ->
                    eth
            end
    end,
    case Type of
        %% When switch connects to a tap interface, erlang receives file
        %% descriptor to read/write ethernet frames directly from the
        %% desired /dev/tapX character device. No socket communication
        %% is involved.
        tap ->
            case linc_us3_port_native:tap(Interface, PortOpts) of
                {stop, shutdown} ->
                    {stop, shutdown};
                {ErlangPort, Pid, HwAddr} ->
                    ets:insert(linc:lookup(SwitchId, linc_ports),
                               #linc_port{port_no = PortNo, pid = self()}),
                    ets:insert(linc:lookup(SwitchId, linc_port_stats),
                               #ofp_port_stats{port_no = PortNo}),
                    case queues_config(SwitchId, PortOpts) of
                        disabled ->
                            disabled;
                        QueuesConfig ->
                            SendFun = fun(Frame) ->
                                              port_command(ErlangPort, Frame)
                                      end,
                            linc_us3_queue:attach_all(SwitchId, PortNo,
                                                      SendFun, QueuesConfig)
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
        eth ->
            {Socket, IfIndex, EpcapPid, HwAddr} =
                linc_us3_port_native:eth(Interface),
            case queues_config(SwitchId, PortOpts) of
                disabled ->
                    disabled;
                QueuesConfig ->
                    SendFun = fun(Frame) ->
                                      linc_us3_port_native:send(Socket,
                                                                IfIndex,
                                                                Frame)
                              end,
                    linc_us3_queue:attach_all(SwitchId, PortNo,
                                              SendFun, QueuesConfig)
            end,
            ets:insert(linc:lookup(SwitchId, linc_ports),
                       #linc_port{port_no = PortNo, pid = self()}),
            ets:insert(linc:lookup(SwitchId, linc_port_stats),
                       #ofp_port_stats{port_no = PortNo}),
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
                               {{error, {port_mod_failed, bad_hw_addr}}, Port}
                       end,
    {reply, Reply, State#state{port = NewPort}};
handle_call(get_port, _From, #state{port = Port} = State) ->
    {reply, Port, State};
handle_call(get_port_state, _From,
            #state{port = #ofp_port{state = PortState}} = State) ->
    {reply, PortState, State};
handle_call({set_port_state, NewPortState}, _From,
            #state{port = Port, switch_id = SwitchId} = State) ->
    NewPort = Port#ofp_port{state = NewPortState},
    PortStatus = #ofp_port_status{reason = modify,
                                  desc = NewPort},
    linc_logic:send_to_controllers(SwitchId, #ofp_message{body = PortStatus}),
    {reply, ok, State#state{port = NewPort}};
handle_call(get_port_config, _From,
            #state{port = #ofp_port{config = PortConfig}} = State) ->
    {reply, PortConfig, State};
handle_call({set_port_config, NewPortConfig}, _From,
            #state{port = Port, switch_id = SwitchId} = State) ->
    NewPort = Port#ofp_port{config = NewPortConfig},
    PortStatus = #ofp_port_status{reason = modify,
                                  desc = NewPort},
    linc_logic:send_to_controllers(SwitchId, #ofp_message{body = PortStatus}),
    {reply, ok, State#state{port = NewPort}};
handle_call(get_features, _From,
            #state{port = #ofp_port{
                             curr = CurrentFeatures,
                             advertised = AdvertisedFeatures,
                             supported = SupportedFeatures,
                             peer  = PeerFeatures
                            }} = State) ->
    {reply, {CurrentFeatures, AdvertisedFeatures,
             SupportedFeatures, PeerFeatures}, State};
handle_call(get_advertised_features, _From,
            #state{port = #ofp_port{advertised = AdvertisedFeatures}} = State) ->
    {reply, AdvertisedFeatures, State};
handle_call({set_advertised_features, AdvertisedFeatures}, _From,
            #state{port = Port, switch_id = SwitchId} = State) ->
    NewPort = Port#ofp_port{advertised = AdvertisedFeatures},
    PortStatus = #ofp_port_status{reason = modify,
                                  desc = NewPort},
    linc_logic:send_to_controllers(SwitchId, #ofp_message{body = PortStatus}),
    {reply, ok, State#state{port = NewPort}};
handle_call(get_info, _From, #state{resource_id = ResourceId,
                                    port = Port} = State) ->
    {reply, {ResourceId, Port}, State}.

%% @private
handle_cast({send, #linc_pkt{packet = Packet, queue_id = QueueId}},
            #state{socket = Socket,
                   port = #ofp_port{port_no = PortNo,
                                    config = PortConfig},
                   erlang_port = Port,
                   queues = QueuesState,
                   ifindex = Ifindex,
                   switch_id = SwitchId} = State) ->
    case check_port_config(no_fwd, PortConfig) of
        true ->
            drop;
        false ->
            Frame = pkt:encapsulate(Packet),
            update_port_tx_counters(SwitchId, PortNo, byte_size(Frame)),
            case QueuesState of
                disabled ->
                    case {Port, Ifindex} of
                        {undefined, _} ->
                            linc_us3_port_native:send(Socket, Ifindex, Frame);
                        {_, undefined} ->
                            port_command(Port, Frame)
                    end;
                enabled ->
                    linc_us3_queue:send(SwitchId, PortNo, QueueId, Frame)
            end
    end,
    {noreply, State}.

%% @private
handle_info({packet, _DataLinkType, _Time, _Length, Frame},
            #state{port = #ofp_port{port_no = PortNo,
                                    config = PortConfig},
                   switch_id = SwitchId} = State) ->
    handle_frame(Frame, SwitchId, PortNo, PortConfig),
    {noreply, State};
handle_info({Port, {data, Frame}}, #state{port = #ofp_port{port_no = PortNo,
                                                           config = PortConfig},
                                          erlang_port = Port,
                                          switch_id = SwitchId} = State) ->
    handle_frame(Frame, SwitchId, PortNo, PortConfig),
    {noreply, State};
handle_info({'EXIT', _Pid, {port_terminated, 1}},
            #state{interface = Interface} = State) ->
    ?ERROR("Port for interface ~p exited abnormally",
           [Interface]),
    {stop, normal, State};
handle_info(_Info, State) ->
    {noreply, State}.

%% @private
terminate(_Reason, #state{port = #ofp_port{port_no = PortNo},
                          switch_id = SwitchId} = State) ->
    case queues_enabled(SwitchId) of
        true ->
            linc_us3_queue:detach_all(SwitchId, PortNo);
        false ->
            ok
    end,
    true = ets:delete(linc:lookup(SwitchId, linc_ports), PortNo),
    true = ets:delete(linc:lookup(SwitchId, linc_port_stats), PortNo),
    linc_us3_port_native:close(State).

%% @private
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%-----------------------------------------------------------------------------
%%% Internal functions
%%%-----------------------------------------------------------------------------

%% @doc Return list of all OFP port nuumbers present in the switch.
-spec get_all_port_no(integer()) -> [integer()].
get_all_port_no(SwitchId) ->
    Ports = ets:tab2list(linc:lookup(SwitchId, linc_ports)),
    lists:map(fun(#linc_port{port_no = PortNo}) ->
                      PortNo
              end, Ports).

-spec add(linc_port_type(), integer(), [linc_port_config()]) -> pid() | error.
add(physical, SwitchId, Opts) ->
    Sup = linc:lookup(SwitchId, linc_us3_port_sup),
    case supervisor:start_child(Sup, [Opts]) of
        {ok, Pid} ->
            ?INFO("Created port: ~p", [Opts]),
            Pid;
        {error, shutdown} ->
            ?ERROR("Cannot create port ~p", [Opts]),
            error
    end.

%% @doc Removes given OF port from the switch, as well as its port stats entry,
%% all queues connected to it and their queue stats entries.
-spec remove(integer(), ofp_port_no()) -> ok | bad_port.
remove(SwitchId, PortNo) ->
    case get_port_pid(SwitchId, PortNo) of
        bad_port ->
            bad_port;
        Pid ->
            Sup = linc:lookup(SwitchId, linc_us3_port_sup),
            ok = supervisor:terminate_child(Sup, Pid)
    end.

handle_frame(Frame, SwitchId, PortNo, PortConfig) ->
    case check_port_config(no_recv, PortConfig) of
        true ->
            drop;
        false ->
            LincPkt = linc_us3_packet_edit:binary_to_record(Frame, SwitchId,
                                                            PortNo),
            update_port_rx_counters(SwitchId, PortNo, byte_size(Frame)),
            case check_port_config(no_packet_in, PortConfig) of
                false ->
                    linc_us3_routing:spawn_route(LincPkt);
                true ->
                    linc_us3_routing:spawn_route(LincPkt#linc_pkt{no_packet_in = true})
            end
    end.

-spec update_port_rx_counters(integer(), integer(), integer()) -> any().
update_port_rx_counters(SwitchId, PortNum, Bytes) ->
    ets:update_counter(linc:lookup(SwitchId, linc_port_stats), PortNum,
                       [{#ofp_port_stats.rx_packets, 1},
                        {#ofp_port_stats.rx_bytes, Bytes}]).

-spec update_port_tx_counters(integer(), integer(), integer()) -> any().
update_port_tx_counters(SwitchId, PortNum, Bytes) ->
    ets:update_counter(linc:lookup(SwitchId, linc_port_stats), PortNum,
                       [{#ofp_port_stats.tx_packets, 1},
                        {#ofp_port_stats.tx_bytes, Bytes}]).

-spec get_port_pid(integer(), ofp_port_no()) -> pid() | bad_port.
get_port_pid(SwitchId, PortNo) ->
    case ets:lookup(linc:lookup(SwitchId, linc_ports), PortNo) of
        [] ->
            bad_port;
        [#linc_port{pid = Pid}] ->
            Pid
    end.

maybe_buffer(_SwitchId, action, Packet, no_buffer) ->
    {no_buffer,pkt:encapsulate(Packet)};
maybe_buffer(SwitchId, action, Packet, Bytes) ->
    maybe_buffer(SwitchId, Packet, Bytes);
maybe_buffer(SwitchId, no_match, Packet, _Bytes) ->
    maybe_buffer(SwitchId, Packet, get_switch_config(miss_send_len));
maybe_buffer(SwitchId, invalid_ttl, Packet, _Bytes) ->
    %% The spec does not specify how many bytes to include for invalid_ttl,
    %% so we use miss_send_len here as well.
    maybe_buffer(SwitchId, Packet, get_switch_config(miss_send_len)).

maybe_buffer(_SwitchId, Packet, no_buffer) ->
    {no_buffer, pkt:encapsulate(Packet)};
maybe_buffer(SwitchId, Packet, Bytes) ->
    BufferId = linc_buffer:save_buffer(SwitchId, Packet),
    {BufferId, truncate_packet(Packet, Bytes)}.

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

-spec queues_enabled(integer()) -> boolean().
queues_enabled(SwitchId) ->
    {ok, Switches} = application:get_env(linc, logical_switches),
    {switch, SwitchId, Opts} = lists:keyfind(SwitchId, 2, Switches),
    case lists:keyfind(queues_status, 1, Opts) of
        false ->
            false;
        {queues_status, enabled} ->
            true;
        _ ->
            false
    end.

-spec queues_config(integer(), list(linc_port_config())) -> [term()] |
                                                            disabled.
queues_config(SwitchId, PortOpts) ->
    case queues_enabled(SwitchId) of
        true ->
            case lists:keyfind(queues, 1, PortOpts) of
                false ->
                    disabled;
                {queues, Queues} ->
                    Queues
            end;
        false ->
            disabled
    end.

ports_for_switch(SwitchId, Config) ->
    {switch, SwitchId, Opts} = lists:keyfind(SwitchId, 2, Config),
    {ports, Ports} = lists:keyfind(ports, 1, Opts),
    QueuesStatus = lists:keyfind(queues_status, 1, Opts),
    Queues = lists:keyfind(queues, 1, Opts),
    [begin
         {port, PortNo, [QueuesStatus | [Queues | PortConfig]]}
     end || {port, PortNo, PortConfig} <- Ports].

check_port_config(Flag, Config) ->
    lists:member(port_down, Config) orelse lists:member(Flag, Config).
