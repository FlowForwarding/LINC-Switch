%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2012, Erlang Solutions Ltd.
%%% @doc OpenFlow Switch behaviour.
%%% @end
%%%-----------------------------------------------------------------------------
-module(gen_switch).

%% @doc Start the switch.
-callback start(Args :: term()) ->
    {ok, State :: term()}.

%% @doc Stop the switch.
-callback stop(State :: term()) ->
    term().

%% @doc Modify flow entry in the flow table.
-callback flow_mod(State :: term(),
                   of_protocol:flow_mod()) ->
    {ok, NewState :: term()} |
    {error, of_protocol:error_msg(), NewState :: term()}.

%% @doc Modify flow table configuration.
-callback table_mod(State :: term(),
                    of_protocol:table_mod()) ->
    {ok, NewState :: term()} |
    {error, of_protocol:error_msg(), NewState :: term()}.

%% @doc Modify port configuration.
-callback port_mod(State :: term(),
                   of_protocol:port_mod()) ->
    {ok, NewState :: term()} |
    {error, of_protocol:error_msg(), NewState :: term()}.

%% @doc Modify group entry in the group table.
-callback group_mod(State :: term(),
                    of_protocol:group_mod()) ->
    {ok, NewState :: term()} |
    {error, of_protocol:error_msg(), NewState :: term()}.

%% @doc Send packet to controller
-callback packet_out(State :: term(),
                     of_protocol:packet_out()) ->
    {ok, NewState :: term()} |
    {error, of_protocol:error_msg(), NewState :: term()}.

%% @doc Reply to echo request.
-callback echo_request(State :: term(),
                       of_protocol:echo_request()) ->
    {ok, of_protocol:echo_reply(), NewState :: term()} |
    {error, of_protocol:error_msg(), NewState :: term()}.

%% @doc Reply to barrier request.
-callback barrier_request(State :: term(),
                          of_protocol:barrier_request()) ->
    {ok, of_protocol:barrier_request(), NewState :: term()} |
    {error, of_protocol:error_msg(), NewState :: term()}.

%% @doc Get switch description statistics.
-callback desc_stats_request(State :: term(),
                             of_protocol:desc_stats_request()) ->
    {ok, of_protocol:desc_stats_reply(), NewState :: term()} |
    {error, of_protocol:error_msg(), NewState :: term()}.

%% @doc Get flow entry statistics.
-callback flow_stats_request(State :: term(),
                             of_protocol:flow_stats_request()) ->
    {ok, of_protocol:flow_stats_reply(), NewState :: term()} |
    {error, of_protocol:error_msg(), NewState :: term()}.

%% @doc Get aggregated flow statistics.
-callback aggregate_stats_request(State :: term(),
                                  of_protocol:aggregate_stats_request()) ->
    {ok, of_protocol:aggregate_stats_reply(), NewState :: term()} |
    {error, of_protocol:error_msg(), NewState :: term()}.

%% @doc Get flow table statistics.
-callback table_stats_request(State :: term(),
                              of_protocol:table_stats_request()) ->
    {ok, of_protocol:table_stats_reply(), NewState :: term()} |
    {error, of_protocol:error_msg(), NewState :: term()}.

%% @doc Get port statistics.
-callback port_stats_request(State :: term(),
                             of_protocol:port_stats_request()) ->
    {ok, of_protocol:port_stats_reply(), NewState :: term()} |
    {error, of_protocol:error_msg(), NewState :: term()}.

%% @doc Get queue statistics.
-callback queue_stats_request(State :: term(),
                              of_protocol:queue_stats_request()) ->
    {ok, of_protocol:queue_stats_reply(), NewState :: term()} |
    {error, of_protocol:error_msg(), NewState :: term()}.

%% @doc Get group statistics.
-callback group_stats_request(State :: term(),
                              of_protocol:group_stats_request()) ->
    {ok, of_protocol:group_stats_reply(), NewState :: term()} |
    {error, of_protocol:error_msg(), NewState :: term()}.

%% @doc Get group description statistics.
-callback group_desc_stats_request(State :: term(),
                                   of_protocol:group_desc_stats_request()) ->
    {ok, of_protocol:group_desc_stats_reply(), NewState :: term()} |
    {error, of_protocol:error_msg(), NewState :: term()}.

%% @doc Get group features statistics.
-callback group_features_stats_request(State :: term(),
                                       of_protocol:group_features_stats_request()) ->
    {ok, of_protocol:group_features_stats_reply(), NewState :: term()} |
    {error, of_protocol:error_msg(), NewState :: term()}.
