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
-callback modify_flow(State :: term(),
                      of_protocol:flow_mod()) ->
    {ok, NewState :: term()} |
    {error, atom(), NewState :: term()}.

%% @doc Modify flow table configuration.
-callback modify_table(State :: term(),
                       of_protocol:table_mod()) ->
    {ok, NewState :: term()} |
    {error, atom(), NewState :: term()}.

%% @doc Modify port configuration.
-callback modify_port(State :: term(),
                      of_protocol:port_mod()) ->
    {ok, NewState :: term()} |
    {error, atom(), NewState :: term()}.

%% @doc Modify group entry in the group table.
-callback modify_group(State :: term(),
                       of_protocol:group_mod()) ->
    {ok, NewState :: term()} |
    {error, atom(), NewState :: term()}.

%% @doc Reply to echo request.
-callback echo_request(State :: term(),
                       of_protocol:echo_request()) ->
    {ok, of_protocol:echo_reply(), NewState :: term()} |
    {error, atom(), NewState :: term()}.

%% @doc Reply to barrier request.
-callback barrier_request(State :: term(),
                          of_protocol:barrier_request()) ->
    {ok, of_protocol:barrier_request(), NewState :: term()} |
    {error, atom(), NewState :: term()}.

%% @doc Get switch description statistics.
-callback get_desc_stats(State :: term(),
                         of_protocol:desc_stats_request()) ->
    {ok, of_protocol:desc_stats_reply(), NewState :: term()} |
    {error, atom(), NewState :: term()}.

%% @doc Get flow entry statistics.
-callback get_flow_stats(State :: term(),
                         of_protocol:flow_stats_request()) ->
    {ok, of_protocol:flow_stats_reply(), NewState :: term()} |
    {error, atom(), NewState :: term()}.

%% @doc Get aggregated flow statistics.
-callback get_aggregate_stats(State :: term(),
                              of_protocol:aggregate_stats_request()) ->
    {ok, of_protocol:aggregate_stats_reply(), NewState :: term()} |
    {error, atom(), NewState :: term()}.

%% @doc Get flow table statistics.
-callback get_table_stats(State :: term(),
                          of_protocol:table_stats_request()) ->
    {ok, of_protocol:table_stats_reply(), NewState :: term()} |
    {error, atom(), NewState :: term()}.

%% @doc Get port statistics.
-callback get_port_stats(State :: term(),
                         of_protocol:port_stats_request()) ->
    {ok, of_protocol:port_stats_reply(), NewState :: term()} |
    {error, atom(), NewState :: term()}.

%% @doc Get queue statistics.
-callback get_queue_stats(State :: term(),
                          of_protocol:queue_stats_request()) ->
    {ok, of_protocol:queue_stats_reply(), NewState :: term()} |
    {error, atom(), NewState :: term()}.

%% @doc Get group statistics.
-callback get_group_stats(State :: term(),
                          of_protocol:group_stats_request()) ->
    {ok, of_protocol:group_stats_reply(), NewState :: term()} |
    {error, atom(), NewState :: term()}.

%% @doc Get group description statistics.
-callback get_group_desc_stats(State :: term(),
                               of_protocol:group_desc_stats_request()) ->
    {ok, of_protocol:group_desc_stats_reply(), NewState :: term()} |
    {error, atom(), NewState :: term()}.

%% @doc Get group features statistics.
-callback get_group_features_stats(State :: term(),
                                   of_protocol:group_features_stats_request()) ->
    {ok, of_protocol:group_features_stats_reply(), NewState :: term()} |
    {error, atom(), NewState :: term()}.
