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
%% @doc Userspace implementation of the OpenFlow Switch logic.
-module(linc_us3).

-behaviour(gen_switch).

%% Switch API
-export([route/1,
         add_port/2,
         remove_port/1,
         parse_ofs_pkt/2,
         get_group_stats/0,
         get_group_stats/1]).

%% gen_switch callbacks
-export([start/1,
         stop/1,
         handle_message/2]).

%% Handle all message types
-export([ofp_features_request/2,
         ofp_flow_mod/2,
         ofp_table_mod/2,
         ofp_port_mod/2,
         ofp_group_mod/2,
         ofp_packet_out/2,
         ofp_echo_request/2,
         ofp_get_config_request/2,
         ofp_set_config/2,
         ofp_barrier_request/2,
         ofp_queue_get_config_request/2,
         ofp_desc_stats_request/2,
         ofp_flow_stats_request/2,
         ofp_aggregate_stats_request/2,
         ofp_table_stats_request/2,
         ofp_port_stats_request/2,
         ofp_queue_stats_request/2,
         ofp_group_stats_request/2,
         ofp_group_desc_stats_request/2,
         ofp_group_features_stats_request/2]).

-include("linc_us3.hrl").

-record(state, {}).
-type state() :: #state{}.

%%%-----------------------------------------------------------------------------
%%% Switch API
%%%-----------------------------------------------------------------------------

-spec route(#ofs_pkt{}) -> pid().
route(Pkt) ->
    proc_lib:spawn_link(linc_us3_routing, do_route, [Pkt]).

-spec add_port(ofs_port_type(), [ofs_port_config()]) -> pid() | error.
add_port(physical, Opts) ->
    case supervisor:start_child(linc_us3_port_sup, [Opts]) of
        {ok, Pid} ->
            ?INFO("Created port: ~p", [Opts]),
            Pid;
        {error, shutdown} ->
            ?ERROR("Cannot create port ~p", [Opts]),
            error
    end;
add_port(logical, _Opts) ->
    error;
add_port(reserved, _Opts) ->
    error.

-spec remove_port(ofp_port_no()) -> ok | bad_port.
remove_port(PortNo) ->
    linc_us3_port:remove(PortNo).

-spec parse_ofs_pkt(binary(), ofp_port_no()) -> #ofs_pkt{}.
parse_ofs_pkt(Binary, PortNum) ->
    try
        Packet = pkt:decapsulate(Binary),
        Fields = [linc_us3_convert:ofp_field(in_port, <<PortNum:32>>)
                  || is_integer(PortNum)]
            ++ linc_us3_convert:packet_fields(Packet),
        #ofs_pkt{packet = Packet,
                 fields =
                     #ofp_match{fields = Fields},
                 in_port = PortNum,
                 size = byte_size(Binary)}
    catch
        E1:E2 ->
            ?ERROR("Decapsulate failed for pkt: ~p because: ~p:~p",
                   [Binary, E1, E2]),
            io:format("Stacktrace: ~p~n", [erlang:get_stacktrace()]),
            #ofs_pkt{}
    end.

-spec get_group_stats() -> [ofp_group_stats()].
get_group_stats() ->
    ets:tab2list(group_stats).

-spec get_group_stats(ofp_group_id()) -> ofp_group_stats() | undefined.
get_group_stats(GroupId) ->
    case ets:lookup(group_stats, GroupId) of
        [] ->
            undefined;
        [Any] ->
            Any
    end.

%%%-----------------------------------------------------------------------------
%%% gen_switch callbacks
%%%-----------------------------------------------------------------------------

%% @doc Start the switch.
-spec start(any()) -> {ok, state()}.
start(_Opts) ->
    UserspaceSup = {linc_us3_sup, {linc_us3_sup, start_link, []},
                    permanent, 5000, supervisor, [linc_us3_sup]},
    supervisor:start_child(linc_sup, UserspaceSup),

    linc_us3_flow:initialize(),
    linc_us3_groups:create(),

    %% Ports
    ofs_ports = ets:new(ofs_ports, [named_table, public,
                                    {keypos, #ofs_port.number},
                                    {read_concurrency, true}]),
    port_stats = ets:new(port_stats,
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
    [add_port(physical, Port) || Port <- UserspacePorts],

    {ok, #state{}}.

%% @doc Stop the switch.
-spec stop(state()) -> any().
stop(_State) ->
    [linc_us3_port:remove(PortNo) ||
        #ofs_port{number = PortNo} <- linc_us3_port:list_ports()],
    %% Flows
    linc_us3_flow:terminate(),
    linc_us3_groups:destroy(),
    %% Ports
    ets:delete(ofs_ports),
    ets:delete(port_stats),
    case application:get_env(linc, queues) of
        undefined ->
            ok;
        {ok, _} ->
            linc_us3_queue:stop()
    end,
    ok.

-spec handle_message(ofp_message_body(), state()) ->
                            {noreply, state()} |
                            {reply, ofp_message(), state()}.
handle_message(MessageBody, State) ->
    MessageName = element(1, MessageBody),
    erlang:apply(?MODULE, MessageName, [State, MessageBody]).

%%%-----------------------------------------------------------------------------
%%% Handling of messages
%%%-----------------------------------------------------------------------------

%% @doc Modify flow entry in the flow table.
-spec ofp_features_request(state(), ofp_features_request()) ->
                          {noreply, #state{}} |
                          {reply, ofp_message(), #state{}}.
ofp_features_request(State, #ofp_features_request{}) ->
    Ports =  [Port || #ofs_port{port = Port} <- []],
    FeaturesReply = #ofp_features_reply{datapath_mac = get_datapath_mac(),
                                        datapath_id = 0,
                                        n_buffers = 0,
                                        ports = Ports,
                                        n_tables = 255},
    {reply, FeaturesReply, State}.

%% @doc Modify flow entry in the flow table.
-spec ofp_flow_mod(state(), ofp_flow_mod()) ->
                          {noreply, #state{}} |
                          {reply, ofp_message(), #state{}}.
ofp_flow_mod(State, #ofp_flow_mod{} = FlowMod) ->
    case linc_us3_flow:modify(FlowMod) of
        ok ->
            {noreply, State};
        {error, {Type, Code}} ->
            ErrorMsg = #ofp_error_msg{type = Type,
                                      code = Code},
            {reply, ErrorMsg, State}
    end.

%% @doc Modify flow table configuration.
-spec ofp_table_mod(state(), ofp_table_mod()) ->
                           {noreply, #state{}} |
                           {reply, ofp_message(), #state{}}.
ofp_table_mod(State, #ofp_table_mod{} = TableMod) ->
    case linc_us3_flow:table_mod(TableMod) of
        ok ->
            {noreply, State};
        {error, {Type, Code}} ->
            ErrorMsg = #ofp_error_msg{type = Type,
                                      code = Code},
            {reply, ErrorMsg, State}
    end.

%% @doc Modify port configuration.
-spec ofp_port_mod(state(), ofp_port_mod()) ->
                          {noreply, #state{}} |
                          {reply, ofp_message(), #state{}}.
ofp_port_mod(State, #ofp_port_mod{port_no = PortNo} = PortMod) ->
    case linc_us3_port:change_config(PortNo, PortMod) of
        ok ->
            {noreply, State};
        {error, Code} ->
            ErrorMsg = #ofp_error_msg{type = port_mod_failed,
                                      code = Code},
            {reply, ErrorMsg, State}
    end.

%% @doc Modify group entry in the group table.
-spec ofp_group_mod(state(), ofp_group_mod()) ->
                           {noreply, #state{}} |
                           {reply, ofp_message(), #state{}}.
ofp_group_mod(State, #ofp_group_mod{} = GroupMod) ->
    case linc_us3_groups:modify(GroupMod) of
        ok ->
            {noreply, State};
        {error, Type, Code} ->
            ErrorMsg = #ofp_error_msg{type = Type,
                                      code = Code},
            {reply, ErrorMsg, State}
    end.

%% @doc Handle a packet received from controller.
-spec ofp_packet_out(state(), ofp_packet_out()) ->
                            {noreply, #state{}} |
                            {reply, ofp_message(), #state{}}.
ofp_packet_out(State, #ofp_packet_out{actions = Actions,
                                      in_port = InPort,
                                      data = Data}) ->
    linc_us3_actions:apply_list(parse_ofs_pkt(Data, InPort), Actions),
    {noreply, State}.

%% @doc Reply to echo request.
-spec ofp_echo_request(state(), ofp_echo_request()) ->
                              {reply, ofp_message(), #state{}}.
ofp_echo_request(State, #ofp_echo_request{data = Data}) ->
    EchoReply = #ofp_echo_reply{data = Data},
    {reply, EchoReply, State}.

%% @doc Reply to get config request.
-spec ofp_get_config_request(state(), ofp_get_config_request()) ->
                                    {reply, ofp_message(), #state{}}.
ofp_get_config_request(State, #ofp_get_config_request{}) ->
    ConfigReply = #ofp_get_config_reply{flags = [],
                                        miss_send_len = ?OFPCML_NO_BUFFER},
    {reply, ConfigReply, State}.

%% @doc Set switch configuration.
-spec ofp_set_config(state(), ofp_set_config()) -> {noreply, state()}.
ofp_set_config(State, #ofp_set_config{}) ->
    {noreply, State}.

%% @doc Reply to barrier request.
-spec ofp_barrier_request(state(), ofp_barrier_request()) ->
                                 {reply, ofp_message(), #state{}}.
ofp_barrier_request(State, #ofp_barrier_request{}) ->
    BarrierReply = #ofp_barrier_reply{},
    {reply, BarrierReply, State}.

%% @doc Reply to get queue config request.
-spec ofp_queue_get_config_request(state(), ofp_queue_get_config_request()) ->
                                          {reply, ofp_message(), #state{}}.
ofp_queue_get_config_request(State,
                             #ofp_queue_get_config_request{port = Port}) ->
    QueueConfigReply = #ofp_queue_get_config_reply{port = Port,
                                                   queues = []},
    {reply, QueueConfigReply, State}.

%% @doc Get switch description statistics.
-spec ofp_desc_stats_request(state(), ofp_desc_stats_request()) ->
                                    {reply, ofp_message(), #state{}}.
ofp_desc_stats_request(State, #ofp_desc_stats_request{}) ->
    {reply, #ofp_desc_stats_reply{flags = [],
                                  mfr_desc = get_env(manufacturer_desc),
                                  hw_desc = get_env(hardware_desc),
                                  sw_desc = get_env(software_desc),
                                  serial_num = get_env(serial_number),
                                  dp_desc = get_env(datapath_desc)
                                 }, State}.

%% @doc Get flow entry statistics.
-spec ofp_flow_stats_request(state(), ofp_flow_stats_request()) ->
                                    {reply, ofp_message(), #state{}}.
ofp_flow_stats_request(State, #ofp_flow_stats_request{} = Request) ->
    Reply = linc_us3_flow:get_stats(Request),
    {reply, Reply, State}.

%% @doc Get aggregated flow statistics.
-spec ofp_aggregate_stats_request(state(), ofp_aggregate_stats_request()) ->
                                         {reply, ofp_message(), #state{}}.
ofp_aggregate_stats_request(State, #ofp_aggregate_stats_request{} = Request) ->
    Reply = linc_us3_flow:get_aggregate_stats(Request),
    {reply, Reply, State}.

%% @doc Get flow table statistics.
-spec ofp_table_stats_request(state(), ofp_table_stats_request()) ->
                                     {reply, ofp_message(), #state{}}.
ofp_table_stats_request(State, #ofp_table_stats_request{} = Request) ->
    Reply = linc_us3_flow:get_table_stats(Request),
    {reply, Reply, State}.

%% @doc Get port statistics.
-spec ofp_port_stats_request(state(), ofp_port_stats_request()) ->
                                    {reply, ofp_message(), #state{}}.
ofp_port_stats_request(State, #ofp_port_stats_request{port_no = PortNo}) ->
    %% TODO: Should we return error when bad_port is encountered?
    Stats = case linc_us3_port:get_port_stats(PortNo) of
                bad_port ->
                    [];
                PortStats ->
                    [PortStats]
            end,
    {reply, #ofp_port_stats_reply{stats = Stats}, State}.

%% @doc Get queue statistics.
-spec ofp_queue_stats_request(state(), ofp_queue_stats_request()) ->
                                     {reply, ofp_message(), #state{}}.
ofp_queue_stats_request(State, #ofp_queue_stats_request{port_no = PortNo,
                                                        queue_id = QueueId}) ->
    %% TODO: Should we return error when undefined is encountered?
    Stats = case linc_us3_port:get_queue_stats(PortNo, QueueId) of
                undefined ->
                    [];
                QueueStats ->
                    [QueueStats]
            end,
    {reply, #ofp_queue_stats_reply{stats = Stats}, State}.

%% @doc Get group statistics.
-spec ofp_group_stats_request(state(), ofp_group_stats_request()) ->
                                     {reply, ofp_message(), #state{}}.
ofp_group_stats_request(State, #ofp_group_stats_request{} = Request) ->
    Reply = linc_us3_groups:get_stats(Request),
    {reply, Reply, State}.

%% @doc Get group description statistics.
-spec ofp_group_desc_stats_request(state(), ofp_group_desc_stats_request()) ->
                                          {reply, ofp_message(), #state{}}.
ofp_group_desc_stats_request(State, #ofp_group_desc_stats_request{} = Request) ->
    Reply = linc_us3_groups:get_desc(Request),
    {reply, Reply, State}.

%% @doc Get group features statistics.
-spec ofp_group_features_stats_request(state(),
                                       ofp_group_features_stats_request()) ->
                                              {reply, ofp_message(), #state{}}.
ofp_group_features_stats_request(State,
                                 #ofp_group_features_stats_request{} = Request) ->
    Reply = linc_us3_groups:get_features(Request),
    {reply, Reply, State}.

%%%-----------------------------------------------------------------------------
%%% Helpers
%%%-----------------------------------------------------------------------------i

get_env(Env) ->
    {ok, Value} = application:get_env(linc, Env),
    Value.

get_datapath_mac() ->
    {ok, Ifs} = inet:getifaddrs(),
    MACs =  [element(2, lists:keyfind(hwaddr, 1, Ps))
             || {_IF, Ps} <- Ifs, lists:keymember(hwaddr, 1, Ps)],
    %% Make sure MAC /= 0
    [MAC | _] = [M || M <- MACs, M /= [0,0,0,0,0,0]],
    list_to_binary(MAC).
