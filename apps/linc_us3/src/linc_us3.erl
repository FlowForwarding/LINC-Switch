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

%% gen_switch callbacks
-export([start/1,
         stop/1,
         handle_message/2]).

%% Backend API
-export([is_port_valid/2,
         is_queue_valid/3,
         set_datapath_mac/2,
         log_message_sent/1,
         set_monitor_data/3]).

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

-include_lib("of_protocol/include/of_protocol.hrl").
-include_lib("of_protocol/include/ofp_v3.hrl").
-include_lib("linc/include/linc_logger.hrl").
-include("linc_us3.hrl").

-record(state, {
          flow_state,
          buffer_state,
          switch_id :: integer(),
          datapath_mac :: binary()
         }).
-type state() :: #state{}.

%%%-----------------------------------------------------------------------------
%%% gen_switch callbacks
%%%-----------------------------------------------------------------------------

%% @doc Start the switch.
-spec start(any()) -> {ok, Version :: 3, state()}.
start(BackendOpts) ->
    {switch_id, SwitchId} = lists:keyfind(switch_id, 1, BackendOpts),
    {datapath_mac, DatapathMac} = lists:keyfind(datapath_mac, 1, BackendOpts),
    {config, Config} = lists:keyfind(config, 1, BackendOpts),
    BufferState = linc_buffer:initialize(SwitchId),
    {ok, _Pid} = linc_us3_sup:start_backend_sup(SwitchId),
    linc_us3_groups:initialize(SwitchId),
    FlowState = linc_us3_flow:initialize(SwitchId),
    linc_us3_port:initialize(SwitchId, Config),
    {ok, 3, #state{flow_state = FlowState,
                   buffer_state = BufferState,
                   switch_id = SwitchId,
                   datapath_mac = DatapathMac}}.

%% @doc Stop the switch.
-spec stop(state()) -> any().
stop(#state{flow_state = FlowState,
            buffer_state = BufferState,
            switch_id = SwitchId}) ->
    linc_us3_port:terminate(SwitchId),
    linc_us3_flow:terminate(FlowState),
    linc_us3_groups:terminate(SwitchId),
    linc_buffer:terminate(BufferState),
    ok.

-spec handle_message(ofp_message_body(), state()) ->
                            {noreply, state()} |
                            {reply, ofp_message(), state()}.
handle_message(MessageBody, State) ->
    MessageName = element(1, MessageBody),
    erlang:apply(?MODULE, MessageName, [State, MessageBody]).

%%%-----------------------------------------------------------------------------
%%% Backend API
%%%-----------------------------------------------------------------------------

-spec is_port_valid(integer(), ofp_port_no()) -> boolean().
is_port_valid(SwitchId, PortNo) ->
    linc_us3_port:is_valid(SwitchId, PortNo).

-spec is_queue_valid(integer(), ofp_port_no(), ofp_queue_id()) -> boolean().
is_queue_valid(SwitchId, PortNo, QueueId) ->
    linc_us3_queue:is_valid(SwitchId, PortNo, QueueId).

set_datapath_mac(State, NewMac) ->
    State#state{datapath_mac = NewMac}.

-spec log_message_sent(ofp_message()) -> term().
log_message_sent(#ofp_message{body = Body} = Message)
  when is_record(Body, ofp_error_msg) ->
    ?DEBUG("[OF_ERROR] Sent message to controller: ~w~n", [Message]);
log_message_sent(Message) ->
    ?DEBUG("Sent message to controller: ~w~n", [Message]).

-spec set_monitor_data(pid(), integer(), state()) -> state().
set_monitor_data(_ClientPid, _Xid, State) ->
    State.

%%%-----------------------------------------------------------------------------
%%% Handling of messages
%%%-----------------------------------------------------------------------------

%% @doc Modify flow entry in the flow table.
-spec ofp_features_request(state(), ofp_features_request()) ->
                                  {reply, ofp_features_reply(), #state{}}.
ofp_features_request(#state{switch_id = SwitchId,
                            datapath_mac = DatapathMac} = State,
                     #ofp_features_request{}) ->
    Ports = linc_us3_port:get_ports(SwitchId),
    FeaturesReply = #ofp_features_reply{datapath_mac = DatapathMac,
                                        datapath_id = SwitchId,
                                        n_buffers = 0,
                                        ports = Ports,
                                        n_tables = 255,
                                        capabilities = ?CAPABILITIES},
    {reply, FeaturesReply, State}.

%% @doc Modify flow entry in the flow table.
-spec ofp_flow_mod(state(), ofp_flow_mod()) ->
                          {noreply, #state{}} |
                          {reply, ofp_message(), #state{}}.
ofp_flow_mod(#state{switch_id = SwitchId} = State,
             #ofp_flow_mod{} = FlowMod) ->
    case linc_us3_flow:modify(SwitchId, FlowMod) of
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
ofp_table_mod(#state{switch_id = SwitchId} = State,
              #ofp_table_mod{} = TableMod) ->
    case linc_us3_flow:table_mod(SwitchId, TableMod) of
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
ofp_port_mod(#state{switch_id = SwitchId} = State,
             #ofp_port_mod{} = PortMod) ->
    case linc_us3_port:modify(SwitchId, PortMod) of
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
ofp_group_mod(#state{switch_id = SwitchId} = State,
              #ofp_group_mod{} = GroupMod) ->
    case linc_us3_groups:modify(SwitchId, GroupMod) of
        ok ->
            {noreply, State};
        {error, ErrorMsg} ->
            {reply, ErrorMsg, State}
    end.

%% @doc Handle a packet received from controller.
-spec ofp_packet_out(state(), ofp_packet_out()) ->
                            {noreply, #state{}} |
                            {reply, ofp_message(), #state{}}.
ofp_packet_out(#state{switch_id = SwitchId} = State,
               #ofp_packet_out{buffer_id = no_buffer,
                               actions = Actions,
                               in_port = InPort,
                               data = Data}) ->
    OfsPkt = linc_us3_packet_edit:binary_to_record(Data, SwitchId, InPort),
    linc_us3_actions:apply_list(OfsPkt, Actions),
    {noreply, State};
ofp_packet_out(#state{switch_id = SwitchId} = State,
               #ofp_packet_out{buffer_id = BufferId,
                               actions = Actions}) ->
    case linc_buffer:get_buffer(SwitchId, BufferId) of
        #linc_pkt{}=OfsPkt ->
            linc_us3_actions:apply_list(OfsPkt, Actions);
        not_found ->
            %% Buffer has been dropped, ignore
            ok
    end,
    {noreply, State}.

%% @doc Reply to echo request.
-spec ofp_echo_request(state(), ofp_echo_request()) ->
                              {reply, ofp_echo_reply(), #state{}}.
ofp_echo_request(State, #ofp_echo_request{data = Data}) ->
    EchoReply = #ofp_echo_reply{data = Data},
    {reply, EchoReply, State}.

%% @doc Reply to get config request.
-spec ofp_get_config_request(state(), ofp_get_config_request()) ->
                                    {reply, ofp_get_config_reply(), #state{}}.
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
                                 {reply, ofp_barrier_reply(), #state{}}.
ofp_barrier_request(State, #ofp_barrier_request{}) ->
    BarrierReply = #ofp_barrier_reply{},
    {reply, BarrierReply, State}.

%% @doc Reply to get queue config request.
-spec ofp_queue_get_config_request(state(), ofp_queue_get_config_request()) ->
                                          {reply, ofp_queue_get_config_reply(),
                                           #state{}}.
ofp_queue_get_config_request(State,
                             #ofp_queue_get_config_request{port = Port}) ->
    QueueConfigReply = #ofp_queue_get_config_reply{port = Port,
                                                   queues = []},
    {reply, QueueConfigReply, State}.

%% @doc Get switch description statistics.
-spec ofp_desc_stats_request(state(), ofp_desc_stats_request()) ->
                                    {reply, ofp_desc_stats_reply(), #state{}}.
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
                                    {reply, ofp_flow_stats_reply(), #state{}}.
ofp_flow_stats_request(#state{switch_id = SwitchId} = State,
                       #ofp_flow_stats_request{} = Request) ->
    Reply = linc_us3_flow:get_stats(SwitchId, Request),
    {reply, Reply, State}.

%% @doc Get aggregated flow statistics.
-spec ofp_aggregate_stats_request(state(), ofp_aggregate_stats_request()) ->
                                         {reply, ofp_aggregate_stats_reply(),
                                          #state{}}.
ofp_aggregate_stats_request(#state{switch_id = SwitchId} = State,
                            #ofp_aggregate_stats_request{} = Request) ->
    Reply = linc_us3_flow:get_aggregate_stats(SwitchId, Request),
    {reply, Reply, State}.

%% @doc Get flow table statistics.
-spec ofp_table_stats_request(state(), ofp_table_stats_request()) ->
                                     {reply, ofp_table_stats_reply(), #state{}}.
ofp_table_stats_request(#state{switch_id = SwitchId} = State,
                        #ofp_table_stats_request{} = Request) ->
    Reply = linc_us3_flow:get_table_stats(SwitchId, Request),
    {reply, Reply, State}.

%% @doc Get port statistics.
-spec ofp_port_stats_request(state(), ofp_port_stats_request()) ->
                                    {reply, ofp_port_stats_reply(), #state{}}.
ofp_port_stats_request(#state{switch_id = SwitchId} = State,
                       #ofp_port_stats_request{} = Request) ->
    Reply = linc_us3_port:get_stats(SwitchId, Request),
    {reply, Reply, State}.

%% @doc Get queue statistics.
-spec ofp_queue_stats_request(state(), ofp_queue_stats_request()) ->
                                     {reply, ofp_queue_stats_reply(), #state{}}.
ofp_queue_stats_request(#state{switch_id = SwitchId} = State,
                        #ofp_queue_stats_request{} = Request) ->
    Reply = linc_us3_queue:get_stats(SwitchId, Request),
    {reply, Reply, State}.

%% @doc Get group statistics.
-spec ofp_group_stats_request(state(), ofp_group_stats_request()) ->
                                     {reply, ofp_group_stats_reply(), #state{}}.
ofp_group_stats_request(#state{switch_id = SwitchId} = State,
                        #ofp_group_stats_request{} = Request) ->
    Reply = linc_us3_groups:get_stats(SwitchId, Request),
    {reply, Reply, State}.

%% @doc Get group description statistics.
-spec ofp_group_desc_stats_request(state(), ofp_group_desc_stats_request()) ->
                                          {reply, ofp_group_desc_stats_reply(),
                                           #state{}}.
ofp_group_desc_stats_request(#state{switch_id = SwitchId} = State,
                             #ofp_group_desc_stats_request{} = Request) ->
    Reply = linc_us3_groups:get_desc(SwitchId, Request),
    {reply, Reply, State}.

%% @doc Get group features statistics.
-spec ofp_group_features_stats_request(state(),
                                       ofp_group_features_stats_request()) ->
                                              {reply,
                                               ofp_group_features_stats_reply(),
                                               #state{}}.
ofp_group_features_stats_request(State,
                                 #ofp_group_features_stats_request{} = Request) ->
    Reply = linc_us3_groups:get_features(Request),
    {reply, Reply, State}.

%%%-----------------------------------------------------------------------------
%%% Helpers
%%%-----------------------------------------------------------------------------

get_env(Env) ->
    {ok, Value} = application:get_env(linc, Env),
    Value.
