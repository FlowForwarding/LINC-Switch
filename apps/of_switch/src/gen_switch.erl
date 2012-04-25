%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2012, Erlang Solutions Ltd.
%%% @doc OpenFlow Switch behaviour.
%%% @end
%%%-----------------------------------------------------------------------------
-module(gen_switch).

-include_lib("of_protocol/include/of_protocol.hrl").

%% @doc Start the switch.
-callback start(Args :: term()) ->
    {ok, State :: term()}.

%% @doc Stop the switch.
-callback stop(State :: term()) ->
    term().

%% @doc Modify flow entry in the flow table.
-callback ofp_flow_mod(State :: term(),
                       ofp_flow_mod()) ->
    {ok, NewState :: term()} |
    {error, ofp_error(), NewState :: term()}.

%% @doc Modify flow table configuration.
-callback ofp_table_mod(State :: term(),
                        ofp_table_mod()) ->
    {ok, NewState :: term()} |
    {error, ofp_error(), NewState :: term()}.

%% @doc Modify port configuration.
-callback ofp_port_mod(State :: term(),
                       ofp_port_mod()) ->
    {ok, NewState :: term()} |
    {error, ofp_error(), NewState :: term()}.

%% @doc Modify group entry in the group table.
-callback ofp_group_mod(State :: term(),
                        ofp_group_mod()) ->
    {ok, NewState :: term()} |
    {error, ofp_error(), NewState :: term()}.

%% @doc Send packet to controller
-callback ofp_packet_out(State :: term(),
                         ofp_packet_out()) ->
    {ok, NewState :: term()} |
    {error, ofp_error(), NewState :: term()}.

%% @doc Reply to echo request.
-callback ofp_echo_request(State :: term(),
                           ofp_echo_request()) ->
    {ok, ofp_echo_reply(), NewState :: term()} |
    {error, ofp_error(), NewState :: term()}.

%% @doc Reply to barrier request.
-callback ofp_barrier_request(State :: term(),
                              ofp_barrier_request()) ->
    {ok, ofp_barrier_request(), NewState :: term()} |
    {error, ofp_error(), NewState :: term()}.

%% @doc Get switch description statistics.
-callback ofp_desc_stats_request(State :: term(),
                                 ofp_desc_stats_request()) ->
    {ok, ofp_desc_stats_reply(), NewState :: term()} |
    {error, ofp_error(), NewState :: term()}.

%% @doc Get flow entry statistics.
-callback ofp_flow_stats_request(State :: term(),
                                 ofp_flow_stats_request()) ->
    {ok, ofp_flow_stats_reply(), NewState :: term()} |
    {error, ofp_error(), NewState :: term()}.

%% @doc Get aggregated flow statistics.
-callback ofp_aggregate_stats_request(State :: term(),
                                      ofp_aggregate_stats_request()) ->
    {ok, ofp_aggregate_stats_reply(), NewState :: term()} |
    {error, ofp_error(), NewState :: term()}.

%% @doc Get flow table statistics.
-callback ofp_table_stats_request(State :: term(),
                                  ofp_table_stats_request()) ->
    {ok, ofp_table_stats_reply(), NewState :: term()} |
    {error, ofp_error(), NewState :: term()}.

%% @doc Get port statistics.
-callback ofp_port_stats_request(State :: term(),
                                 ofp_port_stats_request()) ->
    {ok, ofp_port_stats_reply(), NewState :: term()} |
    {error, ofp_error(), NewState :: term()}.

%% @doc Get queue statistics.
-callback ofp_queue_stats_request(State :: term(),
                                  ofp_queue_stats_request()) ->
    {ok, ofp_queue_stats_reply(), NewState :: term()} |
    {error, ofp_error(), NewState :: term()}.

%% @doc Get group statistics.
-callback ofp_group_stats_request(State :: term(),
                                  ofp_group_stats_request()) ->
    {ok, ofp_group_stats_reply(), NewState :: term()} |
    {error, ofp_error(), NewState :: term()}.

%% @doc Get group description statistics.
-callback ofp_group_desc_stats_request(State :: term(),
                                       ofp_group_desc_stats_request()) ->
    {ok, ofp_group_desc_stats_reply(), NewState :: term()} |
    {error, ofp_error(), NewState :: term()}.

%% @doc Get group features statistics.
-callback ofp_group_features_stats_request(State :: term(),
                                           ofp_group_features_stats_request()) ->
    {ok, ofp_group_features_stats_reply(), NewState :: term()} |
    {error, ofp_error(), NewState :: term()}.
