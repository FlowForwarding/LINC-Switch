%%%===================================================================
%%% Use is subject to License terms.
%%% @copyright (C) 2012 FlowForwarding.org
%%% @doc Module implementing port's queues in userspace switch
%%% @end
%%%===================================================================

-module(ofs_userspace_queue).
-author("Erlang Solutions Ltd. <openflow@erlang-solutions.com>").

-export([start_link/6,
         send/2,
         stop/1]).

-include("ofs_userspace.hrl").

%% have history of 10 buckets and total length of one second
-define(HIST_BUCKET_SIZE, 100).
-define(HIST_BUCKET_COUNT, 10).
-define(HIST_LEN_MS, (?HIST_BUCKET_SIZE * ?HIST_BUCKET_COUNT)).
-define(PAUSE_ON_FULL, 10). % 10ms

%%--------------------------------------------------------------------
%% Public API
%%--------------------------------------------------------------------

-spec start_link({ofp_port_no(), ofp_queue_id()},
                 integer(), integer(), integer(),
                 ets:tid(), fun()) -> {ok, pid()}.
start_link({_, QueueNo} = MyKey, MinRateBps, MaxRateBps, PortRateBps,
           ThrottlingEts, SendFun) ->
    History = sliding_window:new(?HIST_BUCKET_COUNT, ?HIST_BUCKET_SIZE),
    MinRate = bps_to_bphistlen(MinRateBps),
    MaxRate = bps_to_bphistlen(MaxRateBps),
    PortRate = bps_to_bphistlen(PortRateBps),
    ets:insert(ThrottlingEts, #ofs_queue_throttling{queue_no = QueueNo,
                                                    min_rate = MinRate,
                                                    max_rate = MaxRate,
                                                    rate = 0}),
    Pid = proc_lib:spawn_link(fun() ->
                                      loop(MyKey,
                                           MinRate, MaxRate, PortRate,
                                           ThrottlingEts, History, SendFun)
                              end),
    {ok, Pid}.

-spec send(pid(), #ofs_pkt{}) -> ok.
send(Pid, Packet) ->
    Pid ! {send, Packet},
    ok.

-spec stop(pid()) -> ok.
stop(Pid) ->
    gen:call(Pid, cmd, stop).

%%--------------------------------------------------------------------
%% Main loop
%%--------------------------------------------------------------------

-spec loop({ofp_port_no(), ofp_queue_id()}, integer(), integer(), integer(),
           ets:tid(), sliding_window:sliding_window(), fun()) -> no_return().
loop({OutPort, OutQueue} = MyKey, MinRate, MaxRate, PortRate,
     ThrottlingEts, History, SendFun) ->
    receive
        {send, #ofs_pkt{packet = Packet} = OFSPkt} ->
            Frame = pkt:encapsulate(Packet),
            NewHistory = sleep_and_send(MyKey, MinRate, MaxRate, PortRate,
                                        ThrottlingEts, History,
                                        SendFun, Frame),
            update_port_transmitted_counters(MyKey, byte_size(Frame)),
            loop(MyKey, MinRate, MaxRate, PortRate,
                 ThrottlingEts, NewHistory, SendFun);
        {cmd, From, stop} ->
            gen:reply(From, ok)
    end.

sleep_and_send(_MyKey, no_qos, _MaxRate, _PortRate, _ThrottlingEts,
               History, SendFun, Frame) ->
    SendFun(Frame),
    History;
sleep_and_send(MyKey, MinRate, MaxRate, PortRate, ThrottlingEts,
               History, SendFun, Frame) ->
    FrameSize = bit_size(Frame),
    History1 = sliding_window:refresh(History),
    TotalTransfer = sliding_window:total_transfer(History1),
    HistoryLenMs = sliding_window:length_ms(History1),
    MaxTransfer = max_transfer(MinRate, MaxRate, PortRate, ThrottlingEts),
    OverTransfer = max(0, TotalTransfer + FrameSize - MaxTransfer),
    PauseMs = pause_len(OverTransfer, HistoryLenMs, MaxTransfer),
    try
        Transfer = (TotalTransfer + FrameSize) div (HistoryLenMs + PauseMs),
        update_transfer(MyKey, ThrottlingEts, Transfer),
        timer:sleep(PauseMs),
        SendFun(Frame),
        History2 = sliding_window:bump_transfer(History1, FrameSize),
        History2
    catch
        E1:E2 ->
            lager:error("Error ~p:~p Total transfer: ~p, Frame Size: ~p, "
                        "HistoryLenMs: ~p, PauseMs: ~p",
                        [E1, E2, TotalTransfer, FrameSize,
                         HistoryLenMs, PauseMs]),
            lager:error("History1: ~p", [History1]),
            History1
    end.

%%--------------------------------------------------------------------
%% Helpers
%%--------------------------------------------------------------------

pause_len(_OverTransfer, _HistoryLenMs, 0) ->
    ?PAUSE_ON_FULL;
pause_len(OverTransfer, HistoryLenMs, MaxTransfer) ->
    OverTransfer * HistoryLenMs div MaxTransfer.

max_transfer(MinRate, MaxRate, PortRate, ThrottlingEts) ->
    TotalRate = ets:foldl(fun(#ofs_queue_throttling{rate = Rate}, Acc) ->
                              Rate + Acc
                          end, 0, ThrottlingEts),
    FreeRate = PortRate - TotalRate,
    InterestedCount = ets:info(ThrottlingEts, size),
    %% TODO: count only queues interested in sending more than their MinRate
    MySlice = MinRate + FreeRate div InterestedCount,
    min(MySlice, MaxRate).

update_transfer({_, QueueId}, ThrottlingEts, Rate) ->
    ets:update_element(ThrottlingEts,
                       QueueId,
                       {#ofs_queue_throttling.rate, Rate}).

bps_to_bphistlen(Bps) when is_integer(Bps) ->
    Bps * 1000 div ?HIST_LEN_MS;
bps_to_bphistlen(Special) when is_atom(Special) ->
    Special.

-spec update_port_transmitted_counters({ofp_port_no(), ofp_queue_id()},
                                       integer()) -> any().
update_port_transmitted_counters({PortNum, Queue} = Key, Bytes) ->
    try ets:update_counter(ofs_port_queue, Key,
                           [{#ofs_port_queue.tx_packets, 1},
                            {#ofs_port_queue.tx_bytes, Bytes}])
    catch
        E1:E2 ->
            ?ERROR("Queue ~p for port ~p doesn't exist because: ~p:~p "
                   "cannot update queue stats", [Queue, PortNum, E1, E2])
    end,
    try
        ets:update_counter(port_stats, PortNum,
                           [{#ofp_port_stats.tx_packets, 1},
                            {#ofp_port_stats.tx_bytes, Bytes}])
    catch
        E3:E4 ->
            ?ERROR("Cannot update port stats for port ~p because of ~p ~p",
                   [PortNum, E3, E4])
    end.
