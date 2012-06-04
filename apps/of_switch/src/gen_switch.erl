%%%-----------------------------------------------------------------------------
%%% Use is subject to License terms.
%%% @copyright (C) 2012 FlowForwarding.org
%%% @doc OpenFlow Switch behaviour.
%%% Specifies set of callback functions that must be implemented by the switch
%%% backend:
%%%
%%% start/1 - Start the switch.<br/>
%%% stop/1 - Stop the switch.<br/>
%%% ofp_flow_mod/2 - Modify flow entry in the flow table.<br/>
%%% ofp_table_mod/2 - Modify flow table configuration.<br/>
%%% ofp_port_mod/2 - Modify port configuration.<br/>
%%% ofp_group_mod/2 - Modify group entry in the group table.<br/>
%%% ofp_packet_out/2 - Send packet to controller<br/>
%%% ofp_echo_request/2 - Reply to echo request.<br/>
%%% ofp_barrier_request/2 - Reply to barrier request.<br/>
%%% ofp_desc_stats_request/2 - Get switch description statistics.<br/>
%%% ofp_flow_stats_request/2 - Get flow entry statistics.<br/>
%%% ofp_aggregate_stats_request/2 - Get aggregated flow statistics.<br/>
%%% ofp_table_stats_request/2 - Get flow table statistics.<br/>
%%% ofp_port_stats_request - Get port statistics.<br/>
%%% ofp_queue_stats_request/2 - Get queue statistics.<br/>
%%% ofp_group_stats_request/2 -  Get group statistics.<br/>
%%% ofp_group_desc_stats_request/2 - Get group description statistics.<br/>
%%% ofp_group_features_stats_request/2 -  Get group features statistics.<br/>
%%% @end
%%%-----------------------------------------------------------------------------
-module(gen_switch).
-author("Erlang Solutions Ltd. <openflow@erlang-solutions.com>").

-include_lib("of_protocol/include/of_protocol.hrl").

%% Start the switch.
-callback start(Args :: term()) ->
    {ok, State :: term()}.

%% Stop the switch.
-callback stop(State :: term()) ->
    term().

%% Modify flow entry in the flow table.
-callback ofp_flow_mod(State :: term(),
                       ofp_flow_mod()) ->
    {ok, NewState :: term()} |
    {error, ofp_error(), NewState :: term()}.

%% Modify flow table configuration.
-callback ofp_table_mod(State :: term(),
                        ofp_table_mod()) ->
    {ok, NewState :: term()} |
    {error, ofp_error(), NewState :: term()}.

%% Modify port configuration.
-callback ofp_port_mod(State :: term(),
                       ofp_port_mod()) ->
    {ok, NewState :: term()} |
    {error, ofp_error(), NewState :: term()}.

%% Modify group entry in the group table.
-callback ofp_group_mod(State :: term(),
                        ofp_group_mod()) ->
    {ok, NewState :: term()} |
    {error, ofp_error(), NewState :: term()}.

%% Send packet to controller
-callback ofp_packet_out(State :: term(),
                         ofp_packet_out()) ->
    {ok, NewState :: term()} |
    {error, ofp_error(), NewState :: term()}.

%% Reply to echo request.
-callback ofp_echo_request(State :: term(),
                           ofp_echo_request()) ->
    {ok, ofp_echo_reply(), NewState :: term()} |
    {error, ofp_error(), NewState :: term()}.

%% Reply to barrier request.
-callback ofp_barrier_request(State :: term(),
                              ofp_barrier_request()) ->
    {ok, ofp_barrier_reply(), NewState :: term()} |
    {error, ofp_error(), NewState :: term()}.

%% Get switch description statistics.
-callback ofp_desc_stats_request(State :: term(),
                                 ofp_desc_stats_request()) ->
    {ok, ofp_desc_stats_reply(), NewState :: term()} |
    {error, ofp_error(), NewState :: term()}.

%% Get flow entry statistics.
-callback ofp_flow_stats_request(State :: term(),
                                 ofp_flow_stats_request()) ->
    {ok, ofp_flow_stats_reply(), NewState :: term()} |
    {error, ofp_error(), NewState :: term()}.

%% Get aggregated flow statistics.
-callback ofp_aggregate_stats_request(State :: term(),
                                      ofp_aggregate_stats_request()) ->
    {ok, ofp_aggregate_stats_reply(), NewState :: term()} |
    {error, ofp_error(), NewState :: term()}.

%% Get flow table statistics.
-callback ofp_table_stats_request(State :: term(),
                                  ofp_table_stats_request()) ->
    {ok, ofp_table_stats_reply(), NewState :: term()} |
    {error, ofp_error(), NewState :: term()}.

%% Get port statistics.
-callback ofp_port_stats_request(State :: term(),
                                 ofp_port_stats_request()) ->
    {ok, ofp_port_stats_reply(), NewState :: term()} |
    {error, ofp_error(), NewState :: term()}.

%% Get queue statistics.
-callback ofp_queue_stats_request(State :: term(),
                                  ofp_queue_stats_request()) ->
    {ok, ofp_queue_stats_reply(), NewState :: term()} |
    {error, ofp_error(), NewState :: term()}.

%% Get group statistics.
-callback ofp_group_stats_request(State :: term(),
                                  ofp_group_stats_request()) ->
    {ok, ofp_group_stats_reply(), NewState :: term()} |
    {error, ofp_error(), NewState :: term()}.

%% Get group description statistics.
-callback ofp_group_desc_stats_request(State :: term(),
                                       ofp_group_desc_stats_request()) ->
    {ok, ofp_group_desc_stats_reply(), NewState :: term()} |
    {error, ofp_error(), NewState :: term()}.

%% Get group features statistics.
-callback ofp_group_features_stats_request(State :: term(),
                                           ofp_group_features_stats_request()) ->
    {ok, ofp_group_features_stats_reply(), NewState :: term()} |
    {error, ofp_error(), NewState :: term()}.
