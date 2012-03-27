%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2012, Erlang Solutions Ltd.
%%% @author Krzysztof Rutka <krzysztof.rutka@erlang-solutions.com>
%%% @doc Userspace implementation of the OpenFlow Switch logic.
%%% @end
%%%-----------------------------------------------------------------------------
-module(of_switch_userspace).

-behaviour(gen_switch).

%% gen_switch callbacks
-export([init/1, add_flow/2, modify_flow/2, delete_flow/2, modify_table/2,
         modify_port/2, add_group/2, modify_group/2, delete_group/2,
         echo_request/2, get_desc_stats/2, get_flow_stats/2,
         get_aggregate_stats/2, get_table_stats/2, get_port_stats/2,
         get_queue_stats/2, get_group_stats/2, get_group_desc_stats/2,
         get_group_features_stats/2]).

-include_lib("of_protocol/include/of_protocol.hrl").

-record(state, {}).

-type state() :: #state{}.

%%%-----------------------------------------------------------------------------
%%% gen_switch callbacks
%%%-----------------------------------------------------------------------------

%% @doc Initialize switch state.
-spec init(any()) -> {ok, state()}.
init(_Opts) ->
    {ok, #state{}}.

%% @doc Add a new flow entry to the flow table.
-spec add_flow(state(), flow_mod()) -> any().
add_flow(#state{} = _State, #flow_mod{} = _FlowMod) ->
    ok.

%% @doc Modify flow entry in the flow table.
-spec modify_flow(state(), flow_mod()) -> any().
modify_flow(#state{} = _State, #flow_mod{} = _FlowMod) ->
    ok.

%% @doc Delete flow entry from the flow table.
-spec delete_flow(state(), flow_mod()) -> any().
delete_flow(#state{} = _State, #flow_mod{} = _FlowMod) ->
    ok.

%% @doc Modify flow table configuration.
-spec modify_table(state(), table_mod()) -> any().
modify_table(#state{} = _State, #table_mod{} = _TableMod) ->
    ok.

%% @doc Modify port configuration.
-spec modify_port(state(), port_mod()) -> any().
modify_port(#state{} = _State, #port_mod{} = _PortMod) ->
    ok.

%% @doc Add a new group entry to the group table.
-spec add_group(state(), group_mod()) -> any().
add_group(#state{} = _State, #group_mod{} = _GroupMod) ->
    ok.

%% @doc Modify group entry in the group table.
-spec modify_group(state(), group_mod()) -> any().
modify_group(#state{} = _State, #group_mod{} = _GroupMod) ->
    ok.

%% @doc Delete group entry from the group table.
-spec delete_group(state(), group_mod()) -> any().
delete_group(#state{} = _State, #group_mod{} = _GroupMod) ->
    ok.

%% @doc Reply to echo request.
-spec echo_request(state(), echo_request()) -> any().
echo_request(#state{} = _State, #echo_request{} = _EchoRequest) ->
    ok.

%% @doc Get switch description statistics.
-spec get_desc_stats(state(), desc_stats_request()) -> {ok, desc_stats_reply()}.
get_desc_stats(#state{} = _State, #desc_stats_request{} = _StatsRequest) ->
    {ok, #desc_stats_reply{}}.

%% @doc Get flow entry statistics.
-spec get_flow_stats(state(), flow_stats_request()) -> {ok, flow_stats_reply()}.
get_flow_stats(#state{} = _State, #flow_stats_request{} = _StatsRequest) ->
    {ok, #flow_stats_reply{}}.

%% @doc Get aggregated flow statistics.
-spec get_aggregate_stats(state(), aggregate_stats_request()) ->
                                 {ok, aggregate_stats_reply()}.
get_aggregate_stats(#state{} = _State,
                    #aggregate_stats_request{} = _StatsRequest) ->
    {ok, #aggregate_stats_reply{}}.

%% @doc Get flow table statistics.
-spec get_table_stats(state(), table_stats_request()) ->
                             {ok, table_stats_reply()}.
get_table_stats(#state{} = _State, #table_stats_request{} = _StatsRequest) ->
    {ok, #table_stats_reply{}}.

%% @doc Get port statistics.
-spec get_port_stats(state(), port_stats_request()) -> {ok, port_stats_reply()}.
get_port_stats(#state{} = _State, #port_stats_request{} = _StatsRequest) ->
    {ok, #port_stats_reply{}}.

%% @doc Get queue statistics.
-spec get_queue_stats(state(), queue_stats_request()) ->
                             {ok, queue_stats_reply()}.
get_queue_stats(#state{} = _State, #queue_stats_request{} = _StatsRequest) ->
    {ok, #queue_stats_reply{}}.

%% @doc Get group statistics.
-spec get_group_stats(state(), group_stats_request()) ->
                             {ok, group_stats_reply()}.
get_group_stats(#state{} = _State, #group_stats_request{} = _StatsRequest) ->
    {ok, #group_stats_reply{}}.

%% @doc Get group description statistics.
-spec get_group_desc_stats(state(), group_desc_stats_request()) ->
                                  {ok, group_desc_stats_reply()}.
get_group_desc_stats(#state{} = _State,
                     #group_desc_stats_request{} = _StatsRequest) ->
    {ok, #group_desc_stats_reply{}}.

%% @doc Get group features statistics.
-spec get_group_features_stats(state(), group_features_stats_request()) ->
                                      {ok, group_features_stats_reply()}.
get_group_features_stats(#state{} = _State,
                         #group_features_stats_request{} = _StatsRequest) ->
    {ok, #group_features_stats_reply{}}.
