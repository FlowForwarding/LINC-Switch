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
-module(linc_us4).

-behaviour(gen_switch).

%% Switch API
-export([start_ofconfig/1,
         stop_ofconfig/0]).

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
         ofp_desc_request/2,
         ofp_flow_stats_request/2,
         ofp_aggregate_stats_request/2,
         ofp_table_stats_request/2,
         ofp_table_features_request/2,
         ofp_port_desc_request/2,
         ofp_port_stats_request/2,
         ofp_queue_stats_request/2,
         ofp_group_stats_request/2,
         ofp_group_desc_request/2,
         ofp_group_features_request/2,
         ofp_meter_mod/2,
         ofp_meter_stats_request/2,
         ofp_meter_config_request/2,
         ofp_meter_features_request/2]).

-include_lib("of_protocol/include/of_protocol.hrl").
-include_lib("of_protocol/include/ofp_v4.hrl").
-include_lib("linc/include/linc_logger.hrl").
-include("linc_us4.hrl").

-record(state, {
          flow_state,
          buffer_state,
          switch_id :: integer()
         }).
-type state() :: #state{}.

%%%-----------------------------------------------------------------------------
%%% Switch API
%%%-----------------------------------------------------------------------------

start_ofconfig(SwitchId) ->
    case application:get_env(linc, of_config) of
        {ok, enabled} ->
            start_dependency(ssh),
            start_dependency(enetconf),
            linc_us4_ofconfig:start(SwitchId);
        _ ->
            ok
    end.

stop_ofconfig() ->
    %% Don't stop dependent applications (ssh, enetconf) even when they were
    %% started by the corresponding start_ofconfig/0 function.
    %% Rationale: stop_ofconfig/0 is called from the context of
    %% application:stop(linc) and subsequent attempt to stop another application
    %% while the first one is still stopping results in a deadlock.
    case application:get_env(linc, of_config) of
        {ok, enabled} ->
            linc_us4_ofconfig:stop();
        _ ->
            ok
    end.

%%%-----------------------------------------------------------------------------
%%% gen_switch callbacks
%%%-----------------------------------------------------------------------------

%% @doc Start the switch.
-spec start(any()) -> {ok, Version :: 4, state()}.
start(BackendOpts) ->
    {switch_id, SwitchId} = lists:keyfind(switch_id, 1, BackendOpts),
    BufferState = linc_buffer:initialize(),
    {ok, _Pid} = linc_us4_sup:start_backend_sup(SwitchId),
    start_ofconfig(SwitchId),
    linc_us4_groups:create(),
    FlowState = linc_us4_flow:initialize(),
    linc_us4_port:initialize(SwitchId),
    {ok, 4, #state{flow_state = FlowState,
                   buffer_state = BufferState,
                   switch_id = SwitchId}}.

%% @doc Stop the switch.
-spec stop(state()) -> any().
stop(#state{flow_state = FlowState,
            buffer_state = BufferState,
            switch_id = SwitchId}) ->
    stop_ofconfig(),
    linc_us4_port:terminate(SwitchId),
    linc_us4_flow:terminate(FlowState),
    linc_us4_groups:destroy(),
    linc_buffer:terminate(BufferState),
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

ofp_features_request(State, #ofp_features_request{}) ->
    FeaturesReply = #ofp_features_reply{datapath_mac = get_datapath_mac(),
                                        datapath_id = 0,
                                        n_buffers = 0,
                                        n_tables = 255,
                                        auxiliary_id = 0,
                                        capabilities = ?CAPABILITIES},
    {reply, FeaturesReply, State}.

%% @doc Modify flow entry in the flow table.
-spec ofp_flow_mod(state(), ofp_flow_mod()) ->
                          {noreply, #state{}} |
                          {reply, ofp_message(), #state{}}.
ofp_flow_mod(#state{switch_id = SwitchId} = State,
             #ofp_flow_mod{} = FlowMod) ->
    case linc_us4_flow:modify(SwitchId, FlowMod) of
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
    case linc_us4_flow:table_mod(TableMod) of
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
ofp_port_mod(State, #ofp_port_mod{} = PortMod) ->
    case linc_us4_port:modify(PortMod) of
        ok ->
            {noreply, State};
        {error, {Type, Code}} ->
            ErrorMsg = #ofp_error_msg{type = Type,
                                      code = Code},
            {reply, ErrorMsg, State}
    end.

%% @doc Modify group entry in the group table.
-spec ofp_group_mod(state(), ofp_group_mod()) ->
                           {noreply, #state{}} |
                           {reply, ofp_message(), #state{}}.
ofp_group_mod(State, #ofp_group_mod{} = GroupMod) ->
    case linc_us4_groups:modify(GroupMod) of
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
ofp_packet_out(State, #ofp_packet_out{buffer_id = no_buffer,
                                      actions = Actions,
                                      in_port = InPort,
                                      data = Data}) ->
    OfsPkt = linc_us4_packet:binary_to_record(Data, InPort),
    linc_us4_actions:apply_list(OfsPkt, Actions),
    {noreply, State};
ofp_packet_out(State, #ofp_packet_out{buffer_id = BufferId,
                                      actions = Actions}) ->
    case linc_buffer:get_buffer(BufferId) of
        #linc_pkt{}=OfsPkt ->
            linc_us4_actions:apply_list(OfsPkt, Actions);
        not_found ->
            %% Buffer has been dropped, ignore
            ok
    end,
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
                                        miss_send_len = no_buffer},
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
-spec ofp_desc_request(state(), ofp_desc_request()) ->
                              {reply, ofp_message(), #state{}}.
ofp_desc_request(State, #ofp_desc_request{}) ->
    {reply, #ofp_desc_reply{flags = [],
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
    Reply = linc_us4_flow:get_stats(Request),
    {reply, Reply, State}.

%% @doc Get aggregated flow statistics.
-spec ofp_aggregate_stats_request(state(), ofp_aggregate_stats_request()) ->
                                         {reply, ofp_message(), #state{}}.
ofp_aggregate_stats_request(State, #ofp_aggregate_stats_request{} = Request) ->
    Reply = linc_us4_flow:get_aggregate_stats(Request),
    {reply, Reply, State}.

%% @doc Get flow table statistics.
-spec ofp_table_stats_request(state(), ofp_table_stats_request()) ->
                                     {reply, ofp_message(), #state{}}.
ofp_table_stats_request(State, #ofp_table_stats_request{} = Request) ->
    Reply = linc_us4_flow:get_table_stats(Request),
    {reply, Reply, State}.

ofp_table_features_request(State, #ofp_table_features_request{} = Request) ->
    Reply = linc_us4_table_features:handle_req(Request),
    {reply, Reply, State}.

%% @doc Get port description.
-spec ofp_port_desc_request(state(), ofp_port_desc_request()) ->
                                   {reply, ofp_message(), #state{}}.
ofp_port_desc_request(State, #ofp_port_desc_request{}) ->
    Reply = linc_us4_port:get_desc(),
    {reply, Reply, State}.

%% @doc Get port statistics.
-spec ofp_port_stats_request(state(), ofp_port_stats_request()) ->
                                    {reply, ofp_message(), #state{}}.
ofp_port_stats_request(State, #ofp_port_stats_request{} = Request) ->
    Reply = linc_us4_port:get_stats(Request),
    {reply, Reply, State}.

%% @doc Get queue statistics.
-spec ofp_queue_stats_request(state(), ofp_queue_stats_request()) ->
                                     {reply, ofp_message(), #state{}}.
ofp_queue_stats_request(State, #ofp_queue_stats_request{} = Request) ->
    Reply = linc_us4_queue:get_stats(Request),
    {reply, Reply, State}.

%% @doc Get group statistics.
-spec ofp_group_stats_request(state(), ofp_group_stats_request()) ->
                                     {reply, ofp_message(), #state{}}.
ofp_group_stats_request(State, #ofp_group_stats_request{} = Request) ->
    Reply = linc_us4_groups:get_stats(Request),
    {reply, Reply, State}.

%% @doc Get group description statistics.
-spec ofp_group_desc_request(state(), ofp_group_desc_request()) ->
                                    {reply, ofp_message(), #state{}}.
ofp_group_desc_request(State, #ofp_group_desc_request{} = Request) ->
    Reply = linc_us4_groups:get_desc(Request),
    {reply, Reply, State}.

%% @doc Get group features statistics.
-spec ofp_group_features_request(state(),
                                 ofp_group_features_request()) ->
                                        {reply, ofp_message(), #state{}}.
ofp_group_features_request(State,
                           #ofp_group_features_request{} = Request) ->
    Reply = linc_us4_groups:get_features(Request),
    {reply, Reply, State}.

%% Meters ----------------------------------------------------------------------

ofp_meter_mod(#state{switch_id = SwitchId} = State,
              #ofp_meter_mod{} = MeterMod) ->
    case linc_us4_meter:modify(SwitchId, MeterMod) of
        noreply ->
            {noreply, State};
        {reply, Reply} ->
            {reply, Reply, State}
    end.

ofp_meter_stats_request(#state{switch_id = SwitchId} = State,
                        #ofp_meter_stats_request{meter_id = Id}) ->
    {reply, linc_us4_meter:get_stats(SwitchId, Id), State}.

ofp_meter_config_request(#state{switch_id = SwitchId} = State,
                         #ofp_meter_config_request{meter_id = Id}) ->
    {reply, linc_us4_meter:get_config(SwitchId, Id), State}.

ofp_meter_features_request(State, #ofp_meter_features_request{}) ->
    {reply, linc_us4_meter:get_features(), State}.

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

start_dependency(App) ->
    case application:start(App) of
        ok ->
            ok;
        {error, {already_started, ssh}} ->
            ok;
        {error, _} = Error  ->
            ?ERROR("Starting ~p application failed because: ~p",
                   [App, Error])
    end.
