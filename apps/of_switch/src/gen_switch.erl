%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2012, Erlang Solutions Ltd.
%%% @author Krzysztof Rutka <krzysztof.rutka@erlang-solutions.com>
%%% @doc OpenFlow Switch behaviour.
%%% @end
%%%-----------------------------------------------------------------------------
-module(gen_switch).

-export([behaviour_info/1, start/1]).
-export([modify_flow/2,
         modify_table/2,
         modify_port/2,
         modify_group/2,
         echo_request/2,
         get_desc_stats/2,
         get_flow_stats/2,
         get_aggregate_stats/2,
         get_table_stats/2,
         get_port_stats/2,
         get_queue_stats/2,
         get_group_stats/2,
         get_group_desc_stats/2,
         get_group_features_stats/2]).

-include_lib("of_protocol/include/of_protocol.hrl").

-record(handler, {
          module :: atom(),
          state :: any()
         }).

-type handler() :: #handler{}.

%%%-----------------------------------------------------------------------------
%%% Behaviour info function
%%%-----------------------------------------------------------------------------

behaviour_info(callbacks) ->
    [{init, 1},
     {modify_flow, 2},
     {modify_table, 2},
     {modify_port, 2},
     {modify_group, 2},
     {echo_request, 2},
     {get_desc_stats, 2},
     {get_flow_stats, 2},
     {get_aggregate_stats, 2},
     {get_table_stats, 2},
     {get_port_stats, 2},
     {get_queue_stats, 2},
     {get_group_stats, 2},
     {get_group_desc_stats, 2},
     {get_group_features_stats, 2}];
behaviour_info(_) ->
    undefined.

%%%-----------------------------------------------------------------------------
%%% API functions
%%%-----------------------------------------------------------------------------

%% @doc Start OpenFlow switch backend.
-spec start(atom()) -> {ok, handler()}.
start(Module) ->
    {ok, State} = Module:init(),
    {ok, #handler{module = Module, state = State}}.

%% @doc Add, modify or delete flow entry in the flow table.
-spec modify_flow(handler(), flow_mod()) -> any().
modify_flow(#handler{module = Module, state = State}, FlowMod) ->
    Module:modify_flow(State, FlowMod).

%% @doc Modify flow table configuration.
-spec modify_table(handler(), table_mod()) -> any().
modify_table(#handler{module = Module, state = State}, TableMod) ->
    Module:modify_table(State, TableMod).

%% @doc Modify port configuration.
-spec modify_port(handler(), port_mod()) -> any().
modify_port(#handler{module = Module, state = State}, PortMod) ->
    Module:modify_port(State, PortMod).

%% @doc Add, modify or delete group entry in the group table.
-spec modify_group(handler(), group_mod()) -> any().
modify_group(#handler{module = Module, state = State}, GroupMod) ->
    Module:modify_group(State, GroupMod).

%% @doc Reply to echo request.
-spec echo_request(handler(), echo_request()) -> any().
echo_request(#handler{module = Module, state = State}, EchoRequest) ->
    Module:echo_request(State, EchoRequest).

%% @doc Get switch description statistics.
-spec get_desc_stats(handler(), desc_stats_request()) ->
                            {ok, desc_stats_reply()}.
get_desc_stats(#handler{module = Module, state = State}, StatsRequest) ->
    Module:get_desc_stats(State, StatsRequest).

%% @doc Get flow entry statistics.
-spec get_flow_stats(handler(), flow_stats_request()) ->
                            {ok, flow_stats_reply()}.
get_flow_stats(#handler{module = Module, state = State}, StatsRequest) ->
    Module:get_flow_stats(State, StatsRequest).

%% @doc Get aggregated flow statistics.
-spec get_aggregate_stats(handler(), aggregate_stats_request()) ->
                                 {ok, aggregate_stats_reply()}.
get_aggregate_stats(#handler{module = Module, state = State}, StatsRequest) ->
    Module:get_aggregate_stats(State, StatsRequest).

%% @doc Get flow table statistics.
-spec get_table_stats(handler(), table_stats_request()) ->
                             {ok, table_stats_reply()}.
get_table_stats(#handler{module = Module, state = State}, StatsRequest) ->
    Module:get_table_stats(State, StatsRequest).

%% @doc Get port statistics.
-spec get_port_stats(handler(), port_stats_request()) ->
                            {ok, port_stats_reply()}.
get_port_stats(#handler{module = Module, state = State}, StatsRequest) ->
    Module:get_port_stats(State, StatsRequest).

%% @doc Get queue statistics.
-spec get_queue_stats(handler(), queue_stats_request()) ->
                             {ok, queue_stats_reply()}.
get_queue_stats(#handler{module = Module, state = State}, StatsRequest) ->
    Module:get_queue_stats(State, StatsRequest).

%% @doc Get group statistics.
-spec get_group_stats(handler(), group_stats_request()) ->
                             {ok, group_stats_reply()}.
get_group_stats(#handler{module = Module, state = State}, StatsRequest) ->
    Module:get_group_stats(State, StatsRequest).

%% @doc Get group description statistics.
-spec get_group_desc_stats(handler(), group_desc_stats_request()) ->
                                  {ok, group_desc_stats_reply()}.
get_group_desc_stats(#handler{module = Module, state = State}, StatsRequest) ->
    Module:get_group_desc_stats(State, StatsRequest).

%% @doc Get group features statistics.
-spec get_group_features_stats(handler(), group_features_stats_request()) ->
                                      {ok, group_features_stats_reply()}.
get_group_features_stats(#handler{module = Module,
                                  state = State}, StatsRequest) ->
    Module:get_group_features_stats(State, StatsRequest).
