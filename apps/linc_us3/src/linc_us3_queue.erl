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
%% @doc Module implementing port's queues in userspace switch
-module(linc_us3_queue).

%% Queue API
-export([attach_all/4,
         detach_all/2,
         get_stats/2,
         send/4,
         set_min_rate/4,
         set_max_rate/4,
         get_all_queues_state/2,
         is_valid/3]).

%% Internal API
-export([start_link/2,
         initialize/1,
         terminate/1]).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-include_lib("of_config/include/of_config.hrl").
-include_lib("of_protocol/include/of_protocol.hrl").
-include_lib("of_protocol/include/ofp_v3.hrl").
-include_lib("linc/include/linc_logger.hrl").
-include("linc_us3.hrl").
-include("linc_us3_queue.hrl").

%% have history of 10 buckets and total length of one second
-define(HIST_BUCKET_SIZE, 100).
-define(HIST_BUCKET_COUNT, 10).
-define(HIST_LEN_MS, (?HIST_BUCKET_SIZE * ?HIST_BUCKET_COUNT)).
-define(PAUSE_ON_FULL, 10). % 10ms
-define(DEFAULT_QUEUE, default).

-record(state, {queue_key :: {ofp_port_no(), ofp_queue_id()},
                resource_id :: string(),
                port_rate_bps :: integer(),
                min_rate_bps :: integer(),
                max_rate_bps :: integer(),
                port_rate :: integer(),
                min_rate :: integer(),
                max_rate :: integer(),
                history,
                send_fun,
                switch_id :: integer(),
                throttling_ets}).

%%------------------------------------------------------------------------------
%% Queue API
%%------------------------------------------------------------------------------

-spec attach_all(integer(), ofp_port_no(), fun(), [term()]) -> ok.
attach_all(SwitchId, PortNo, SendFun, QueuesConfig) ->
    ThrottlingETS = ets:new(queue_throttling,
                            [public,
                             {read_concurrency, true},
                             {keypos,
                              #linc_queue_throttling.queue_no}]),

    case lists:keyfind(PortNo, 2, QueuesConfig) of
        {port, PortNo, PortOpts} ->
            {port_rate, PortRateDesc} = lists:keyfind(port_rate, 1, PortOpts),
            {port_queues, PortQueues} = lists:keyfind(port_queues, 1, PortOpts);
        false ->
            PortRateDesc = {1000, mbps},
            PortQueues = []
    end,
    Sup = linc:lookup(SwitchId, linc_us3_queue_sup),
    lists:foreach(fun({QueueId, QueueProps}) ->
                          Args = [{PortNo, QueueId}, PortRateDesc,
                                  ThrottlingETS,
                                  SendFun, QueueProps],
                          supervisor:start_child(Sup, [Args])
                  end, [{?DEFAULT_QUEUE, []}] ++ PortQueues).

-spec detach_all(integer(), ofp_port_no()) -> ok.
detach_all(SwitchId, PortNo) ->
    lists:foreach(fun(#linc_port_queue{queue_pid = Pid}) ->
                          gen_server:call(Pid, detach)
                  end, get_queues(SwitchId, PortNo)).

%% @doc Return queue stats for the given OF port and queue id.
-spec get_stats(integer(), ofp_queue_stats_request()) -> ofp_queue_stats_reply().
get_stats(SwitchId, #ofp_queue_stats_request{port_no = PortNo,
                                             queue_id = QueueId}) ->
    match_queue(SwitchId, PortNo, QueueId).

-spec send(integer(), ofp_port_no(), ofp_queue_id(), binary()) -> ok | bad_queue.
send(SwitchId, PortNo, QueueId, Frame) ->
    case get_queue_pid(SwitchId, PortNo, QueueId) of
        {error, bad_queue} ->
            bad_queue;
        Pid ->
            gen_server:cast(Pid, {send, Frame})
    end.

update_queue_prop(SwitchId, QueueKey, K, V) ->
    LincPortQueue = linc:lookup(SwitchId, linc_port_queue),
    case ets:lookup(LincPortQueue, QueueKey) of
        [#linc_port_queue{properties = Prop}] ->
            Prop2 = lists:keyreplace(K, 1, Prop, {K, V}),
            ets:update_element(LincPortQueue, QueueKey,
                               [{#linc_port_queue.properties, Prop2}])
    end.

-spec set_min_rate(integer(), ofp_port_no(), ofp_queue_id(), integer()) ->
                          ok |
                          bad_queue.
set_min_rate(SwitchId, PortNo, QueueId, Rate) ->
    case get_queue_pid(SwitchId, PortNo, QueueId) of
        {error, bad_queue} ->
            bad_queue;
        Pid ->
            gen_server:cast(Pid, {set_min_rate, Rate})
    end.

-spec set_max_rate(integer(), ofp_port_no(), ofp_queue_id(), integer()) ->
                          ok |
                          bad_queue.
set_max_rate(SwitchId, PortNo, QueueId, Rate) ->
    case get_queue_pid(SwitchId, PortNo, QueueId) of
        {error, bad_queue} ->
            bad_queue;
        Pid ->
            gen_server:cast(Pid, {set_max_rate, Rate})
    end.

-spec get_all_queues_state(integer(), ofp_port_no()) ->
                                  tuple(string(), integer(), integer(),
                                        integer(), integer()).
get_all_queues_state(SwitchId, PortNo) ->
    lists:map(fun(#linc_port_queue{queue_pid = Pid, properties=Prop}) ->
                      {ResourceId, QueueId, PortNo, _, _} =
                          gen_server:call(Pid, get_state),
                      MinRate = proplists:get_value(min_rate, Prop, no_qos),
                      MaxRate = proplists:get_value(max_rate, Prop,
                                                    no_max_rate),
                      {ResourceId, QueueId, PortNo, MinRate, MaxRate}
              end, get_queues(SwitchId, PortNo)).

-spec is_valid(integer(), ofp_port_no(), ofp_queue_id()) -> boolean().
is_valid(SwitchId, PortNo, QueueId) ->
    case get_queue_pid(SwitchId, PortNo, QueueId) of
        {error, bad_queue} ->
            false;
        _Pid ->
            true
    end.

%%------------------------------------------------------------------------------
%% Internal API
%%------------------------------------------------------------------------------

initialize(SwitchId) ->
    LincPortQueue = ets:new(linc_port_queue,
                            [public,
                             {keypos, #linc_port_queue.key},
                             {read_concurrency, true}]),
    linc:register(SwitchId, linc_port_queue, LincPortQueue),
    QueueSup = {linc_us3_queue_sup,
                {linc_us3_queue_sup, start_link, [SwitchId]},
                permanent, 5000, supervisor, [linc_us3_queue_sup]},
    supervisor:start_child(linc:lookup(SwitchId, linc_us3_sup), QueueSup).

terminate(SwitchId) ->
    true = ets:delete(linc:lookup(SwitchId, linc_port_queue)),
    ok.

start_link(SwitchId, QueueOpts) ->
    gen_server:start_link(?MODULE, [SwitchId, QueueOpts], []).

%%%-----------------------------------------------------------------------------
%%% gen_server callbacks
%%%-----------------------------------------------------------------------------

init([SwitchId, [{PortNo, QueueNo} = Key, PortRateDesc, ThrottlingETS,
                 SendFun, QueueProps]]) ->

    History = linc_us3_sliding_window:new(?HIST_BUCKET_COUNT, ?HIST_BUCKET_SIZE),

    PortRateBps = rate_desc_to_bps(PortRateDesc),
    MinRateBps = get_min_rate_bps(QueueProps, PortRateBps),
    MaxRateBps = get_max_rate_bps(QueueProps, PortRateBps),

    PortRate = bps_to_bphistlen(PortRateBps),
    MinRate = bps_to_bphistlen(MinRateBps),
    MaxRate = bps_to_bphistlen(MaxRateBps),

    LincPortQueue = linc:lookup(SwitchId, linc_port_queue),
    ets:insert(LincPortQueue, #linc_port_queue{key = Key,
                                               properties = QueueProps,
                                               queue_pid = self(),
                                               install_time = erlang:now()}),
    ets:insert(ThrottlingETS, #linc_queue_throttling{queue_no = QueueNo,
                                                     min_rate = MinRate,
                                                     max_rate = MaxRate,
                                                     rate = 0}),
    ResourceId =
        "LogicalSwitch" ++ integer_to_list(SwitchId) ++ "-" ++
        "Port" ++ integer_to_list(PortNo) ++ "-" ++
        case QueueNo of
            default -> "DefaultQueue";
            _ -> "Queue" ++ integer_to_list(QueueNo)
        end,
    {ok, #state{queue_key = Key,
                resource_id = ResourceId,
                port_rate_bps = PortRateBps,
                min_rate_bps = MinRateBps,
                max_rate_bps = MaxRateBps,
                port_rate = PortRate,
                min_rate = MinRate,
                max_rate = MaxRate,
                history = History, send_fun = SendFun,
                switch_id = SwitchId,
                throttling_ets = ThrottlingETS}}.

handle_call(detach, _From, #state{queue_key = QueueKey,
                                  switch_id = SwitchId,
                                  throttling_ets = ThrottlingETS} = State) ->
    {_PortNo, QueueId} = QueueKey,
    LincPortQueue = linc:lookup(SwitchId, linc_port_queue),
    ets:delete(LincPortQueue, QueueKey),
    ets:delete(ThrottlingETS, QueueId),
    {reply, ok, State};
handle_call(get_state, _From, #state{resource_id = ResourceId,
                                     queue_key = {PortNo, QueueId},
                                     min_rate = MinRate,
                                     max_rate = MaxRate} = State) ->
    Queue = {ResourceId, QueueId, PortNo, MinRate, MaxRate},
    {reply, Queue, State}.

handle_cast({send, Frame}, #state{queue_key = QueueKey,
                                  min_rate = MinRate, max_rate = MaxRate,
                                  port_rate = PortRate, history = History,
                                  send_fun = SendFun,
                                  switch_id = SwitchId,
                                  throttling_ets = ThrottlingETS} = State) ->
    NewHistory = sleep_and_send(QueueKey, MinRate, MaxRate,
                                PortRate, ThrottlingETS,
                                History, SendFun, Frame),
    update_queue_tx_counters(SwitchId, QueueKey, byte_size(Frame)),
    {noreply, State#state{history = NewHistory}};
handle_cast({set_min_rate, MinRatePermil},
            #state{queue_key = QueueKey,
                   switch_id = SwitchId,
                   port_rate_bps = PortRateBps,
                   throttling_ets = ThrottlingETS} = State) ->
    MinRateBps = get_min_rate_bps([{min_rate, MinRatePermil}], PortRateBps),
    MinRate = bps_to_bphistlen(MinRateBps),
    {_PortNo, QueueId} = QueueKey,
    ets:update_element(ThrottlingETS, QueueId,
                       {#linc_queue_throttling.min_rate, MinRate}),
    update_queue_prop(SwitchId, QueueKey, min_rate, MinRatePermil),
    {noreply, State#state{min_rate = MinRate}};
handle_cast({set_max_rate, MaxRatePermil},
            #state{queue_key = QueueKey,
                   switch_id = SwitchId,
                   port_rate_bps = PortRateBps,
                   throttling_ets = ThrottlingETS} = State) ->
    MaxRateBps = get_max_rate_bps([{max_rate, MaxRatePermil}], PortRateBps),
    MaxRate = bps_to_bphistlen(MaxRateBps),
    {_PortNo, QueueId} = QueueKey,
    ets:update_element(ThrottlingETS, QueueId,
                       {#linc_queue_throttling.max_rate, MaxRate}),
    update_queue_prop(SwitchId, QueueKey, max_rate, MaxRatePermil),
    {noreply, State#state{max_rate = MaxRate}}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVersion, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%% Helpers
%%--------------------------------------------------------------------

sleep_and_send(_MyKey, no_qos, _MaxRate, _PortRate, _ThrottlingETS,
               History, SendFun, Frame) ->
    SendFun(Frame),
    History;
sleep_and_send(MyKey, MinRate, MaxRate, PortRate, ThrottlingETS,
               History, SendFun, Frame) ->
    FrameSize = bit_size(Frame),
    History1 = linc_us3_sliding_window:refresh(History),
    TotalTransfer = linc_us3_sliding_window:total_transfer(History1),
    HistoryLenMs = linc_us3_sliding_window:length_ms(History1),
    MaxTransfer = max_transfer(MinRate, MaxRate, PortRate, ThrottlingETS),
    OverTransfer = max(0, TotalTransfer + FrameSize - MaxTransfer),
    PauseMs = pause_len(OverTransfer, HistoryLenMs, MaxTransfer),
    try
        Transfer = (TotalTransfer + FrameSize) div (HistoryLenMs + PauseMs),
        update_transfer(MyKey, Transfer, ThrottlingETS),
        timer:sleep(PauseMs),
        SendFun(Frame),
        History2 = linc_us3_sliding_window:bump_transfer(History1, FrameSize),
        History2
    catch
        E1:E2 ->
            ?ERROR("Error ~p:~p Total transfer: ~p, Frame Size: ~p, "
                   "HistoryLenMs: ~p, PauseMs: ~p",
                   [E1, E2, TotalTransfer, FrameSize,
                    HistoryLenMs, PauseMs]),
            ?ERROR("History1: ~p", [History1]),
            History1
    end.

pause_len(_OverTransfer, _HistoryLenMs, 0) ->
    ?PAUSE_ON_FULL;
pause_len(OverTransfer, HistoryLenMs, MaxTransfer) ->
    OverTransfer * HistoryLenMs div MaxTransfer.

max_transfer(MinRate, MaxRate, PortRate, ThrottlingETS) ->
    TotalRate = ets:foldl(fun(#linc_queue_throttling{rate = Rate}, Acc) ->
                                  Rate + Acc
                          end, 0, ThrottlingETS),
    FreeRate = PortRate - TotalRate,
    InterestedCount = ets:info(ThrottlingETS, size),
    %% TODO: count only queues interested in sending more than their MinRate
    MySlice = MinRate + FreeRate div InterestedCount,
    min(MySlice, MaxRate).

update_transfer({_, QueueId}, Rate, ThrottlingETS) ->
    ets:update_element(ThrottlingETS,
                       QueueId,
                       {#linc_queue_throttling.rate, Rate}).

bps_to_bphistlen(Bps) when is_integer(Bps) ->
    Bps * 1000 div ?HIST_LEN_MS;
bps_to_bphistlen(Special) when is_atom(Special) ->
    Special.

-spec update_queue_tx_counters(integer(), {ofp_port_no(), ofp_queue_id()},
                               integer()) -> any().
update_queue_tx_counters(SwitchId, {PortNum, Queue} = Key, Bytes) ->
    LincPortQueue = linc:lookup(SwitchId, linc_port_queue),
    try ets:update_counter(LincPortQueue, Key,
                           [{#linc_port_queue.tx_packets, 1},
                            {#linc_port_queue.tx_bytes, Bytes}])
    catch
        E1:E2 ->
            ?ERROR("Queue ~p for port ~p doesn't exist because: ~p:~p "
                   "cannot update queue stats", [Queue, PortNum, E1, E2])
    end.

-spec get_queue_pid(integer(), ofp_port_no(), ofp_queue_id()) -> pid() |
                                                                 {error, bad_queue}.
get_queue_pid(SwitchId, PortNo, QueueId) ->
    LincPortQueue = linc:lookup(SwitchId, linc_port_queue),
    case ets:lookup(LincPortQueue, {PortNo, QueueId}) of
        [#linc_port_queue{queue_pid = Pid}] ->
            Pid;
        [] ->
            {error, bad_queue}
    end.

-spec get_queues(integer(), ofp_port_no()) -> list(#linc_port_queue{}).
get_queues(SwitchId, PortNo) ->
    LincPortQueue = linc:lookup(SwitchId, linc_port_queue),
    MatchSpec = #linc_port_queue{key = {PortNo, '_'}, _ = '_'},
    case catch ets:match_object(LincPortQueue, MatchSpec) of
        {'EXIT', _} ->
            [];
        Match ->
            Match
    end.

match_queue(SwitchId, any, all) ->
    match_queue(SwitchId, any, '_', '_');
match_queue(SwitchId, any, QueueMatch) ->
    match_queue(SwitchId, any, '_', QueueMatch);
match_queue(SwitchId, PortNo, all) ->
    match_queue(SwitchId, PortNo, PortNo, '_');
match_queue(SwitchId, PortMatch, QueueMatch) ->
    match_queue(SwitchId, PortMatch, PortMatch, QueueMatch).

match_queue(SwitchId, PortNo, PortMatch, QueueMatch) ->
    case linc_us3_port:is_valid(SwitchId, PortNo) of
        false ->
            #ofp_error_msg{type = queue_op_failed, code = bad_port};
        true ->
            MatchSpec = #linc_port_queue{key = {PortMatch, QueueMatch},
                                         _ = '_'},
            LincPortQueue = linc:lookup(SwitchId, linc_port_queue),
            case catch ets:match_object(LincPortQueue, MatchSpec) of
                [] ->
                    #ofp_error_msg{type = queue_op_failed, code = bad_queue};
                {'EXIT', _} ->
                    #ofp_error_msg{type = queue_op_failed, code = bad_queue};
                L ->
                    F = fun(#linc_port_queue{key = {_, default}}) ->
                                false;
                           (_) ->
                                true
                        end,
                    Queues = lists:filter(F, L),
                    QueueStats = queue_stats_convert(Queues),
                    #ofp_queue_stats_reply{stats = QueueStats}
            end
    end.

-spec queue_stats_convert([#linc_port_queue{}]) -> [ofp_queue_stats()].
queue_stats_convert(Queues) ->
    lists:map(fun(#linc_port_queue{key = {PortNo, QueueId},
                                   tx_bytes = TxBytes,
                                   tx_packets = TxPackets,
                                   tx_errors = TxErrors}) ->
                      #ofp_queue_stats{port_no = PortNo,
                                       queue_id = QueueId,
                                       tx_bytes = TxBytes,
                                       tx_packets = TxPackets,
                                       tx_errors = TxErrors}
              end, Queues).

rate_desc_to_bps(Bps) when is_integer(Bps) ->
    Bps;
rate_desc_to_bps({Value, Unit}) ->
    Value * unit_to_bps(Unit).

unit_to_bps(bps) -> 1;
unit_to_bps(kbps) -> 1000;
unit_to_bps(kibps) -> 1024;
unit_to_bps(mbps) -> 1000 * 1000;
unit_to_bps(mibps) -> 1024 * 1024;
unit_to_bps(gbps) -> 1000 * 1000 * 1000;
unit_to_bps(gibps) -> 1024 * 1024 * 1024.

get_min_rate_bps(QueueProps, PortRateBps) ->
    case lists:keyfind(min_rate, 1, QueueProps) of
        {min_rate, Rate} when Rate =< 1000 ->
            Rate * PortRateBps div 1000;
        false ->
            no_qos
    end.

get_max_rate_bps(QueueProps, PortRateBps) ->
    case lists:keyfind(max_rate, 1, QueueProps) of
        {max_rate, Rate} when Rate =< 1000 ->
            Rate * PortRateBps div 1000;
        _ ->
            no_max_rate
    end.
