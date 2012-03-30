%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2012, Erlang Solutions Ltd.
%%% @author Krzysztof Rutka <krzysztof.rutka@erlang-solutions.com>
%%% @doc Userspace implementation of the OpenFlow Switch logic.
%%% @end
%%%-----------------------------------------------------------------------------
-module(of_switch_userspace).

-behaviour(gen_switch).

%% gen_switch callbacks
-export([init/1, modify_flow/2, modify_table/2, modify_port/2, modify_group/2,
         echo_request/2, get_desc_stats/2, get_flow_stats/2,
         get_aggregate_stats/2, get_table_stats/2, get_port_stats/2,
         get_queue_stats/2, get_group_stats/2, get_group_desc_stats/2,
         get_group_features_stats/2]).

-include_lib("of_protocol/include/of_protocol.hrl").
-include("of_switch_userspace.hrl").

-record(state, {}).

-type state() :: #state{}.

%%%-----------------------------------------------------------------------------
%%% gen_switch callbacks
%%%-----------------------------------------------------------------------------

%% @doc Initialize switch state.
-spec init(any()) -> {ok, state()}.
init(_Opts) ->
    flow_tables = ets:new(flow_tables, [named_table,
                                        {keypos, #flow_table.id},
                                        {read_concurrency, true}]),
    InitialTable = #flow_table{id = 0, entries = [], config = drop},
    ets:insert(flow_tables, InitialTable),
    {ok, #state{}}.

%% @doc Modify flow entry in the flow table.
-spec modify_flow(state(), flow_mod()) -> any().
modify_flow(State, #flow_mod{table_id = TID} = FlowMod) ->
    [Table] = ets:lookup(flow_tables, TID),
    case apply_flow_mod(Table, FlowMod) of
        {ok, NewTable} ->
            ets:insert(flow_tables, NewTable);
        {error, _Err} ->
            %% XXX: send error reply
            send_error_reply
    end,
    % XXX: look at buffer_id
    State.

%% @doc Modify flow table configuration.
-spec modify_table(state(), table_mod()) -> any().
modify_table(#state{} = _State, #table_mod{} = _TableMod) ->
    ok.

%% @doc Modify port configuration.
-spec modify_port(state(), port_mod()) -> any().
modify_port(#state{} = _State, #port_mod{} = _PortMod) ->
    ok.

%% @doc Modify group entry in the group table.
-spec modify_group(state(), group_mod()) -> any().
modify_group(#state{} = _State, #group_mod{} = _GroupMod) ->
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

%%%-----------------------------------------------------------------------------
%%% Helpers
%%%-----------------------------------------------------------------------------

apply_flow_mod(#flow_table{entries = Entries} = Table,
               #flow_mod{command = add,
                         priority = Priority,
                         flags = Flags} = FlowMod) ->
    case has_priority_overlap(Flags, Priority, Entries) of
        true ->
            {error, overflow};
        false ->
            NewEntries = lists:keymerge(#flow_entry.priority,
                                        [flow_mod_to_entry(FlowMod)],
                                        Entries),
            {ok, Table#flow_table{entries = NewEntries}}
    end.

flow_mod_to_entry(#flow_mod{priority = Priority,
                            match = Match,
                            instructions = Instructions}) ->
    #flow_entry{priority = Priority,
                match = Match,
                instructions = Instructions}.

has_priority_overlap(Flags, Priority, Entries) ->
    lists:member(check_overlap, Flags)
    andalso
    lists:keymember(Priority, #flow_entry.priority, Entries).
