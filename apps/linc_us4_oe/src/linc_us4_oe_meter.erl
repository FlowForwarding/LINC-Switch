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
%% @doc Module for handling per-flow meters.
-module(linc_us4_oe_meter).

-behaviour(gen_server).

%% API
-export([modify/2,
         apply/3,
         update_flow_count/3,
         get_stats/2,
         get_config/2,
         get_features/0,
         is_valid/2]).

%% Internal API
-export([start/2,
         stop/2,
         start_link/2]).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-include_lib("linc/include/linc_logger.hrl").
-include_lib("of_protocol/include/ofp_v4.hrl").
-include("linc_us4_oe.hrl").

-define(SUPPORTED_BANDS, [drop,
                          dscp_remark,
                          experimenter]).
-define(SUPPORTED_FLAGS, [burst,
                          kbps,
                          pktps,
                          stats]).

-record(linc_meter_band, {
          type :: drop | dscp_remark | experimenter,
          rate :: integer(),
          burst_size :: integer(),
          prec_level :: integer() | undefined,
          experimenter :: integer() | undefined,
          pkt_count = 0 :: integer(),
          byte_count = 0 :: integer()
         }).

-record(linc_meter, {
          id :: integer(),
          ets :: integer(),
          rate_value :: kbps | pktps,
          burst :: boolean(),
          stats = true :: boolean(),
          bands = [] :: [#linc_meter_band{}],
          burst_history = [] :: [{erlang:timestamp(), integer()}],
          flow_count = 0 :: integer(),
          pkt_count = 0 :: integer(),
          byte_count = 0 :: integer(),
          install_ts = now() :: {integer(), integer(), integer()}
         }).

-define(BURST_TIME, timer:seconds(30)).

%%------------------------------------------------------------------------------
%% API functions
%%------------------------------------------------------------------------------

%% @doc Add, modify or delete a meter.
-spec modify(integer(), #ofp_meter_mod{}) ->
                    noreply | {reply, Reply :: ofp_message_body()}.
modify(_SwitchId, #ofp_meter_mod{command = add, meter_id = BadId})
  when is_atom(BadId); BadId > ?OFPM_MAX ->
    {reply, error_msg(invalid_meter)};
modify(SwitchId, #ofp_meter_mod{command = add, meter_id = Id} = MeterMod) ->
    case get_meter_pid(SwitchId, Id) of
        undefined ->
            case start(SwitchId, MeterMod) of
                {ok, _Pid} ->
                    noreply;
                {error, Code} ->
                    {reply, error_msg(Code)}
            end;
        _Pid ->
            {reply, error_msg(meter_exists)}
    end;
modify(_SwitchId, #ofp_meter_mod{command = modify, meter_id = BadId})
  when is_atom(BadId); BadId > ?OFPM_MAX ->
    {reply, error_msg(unknown_meter)};
modify(SwitchId, #ofp_meter_mod{command = modify, meter_id = Id} = MeterMod) ->
    case get_meter_pid(SwitchId, Id) of
        undefined ->
            {reply, error_msg(unknown_meter)};
        Pid ->
            case start(SwitchId, MeterMod) of
                {ok, _NewPid} ->
                    stop(SwitchId, Pid),
                    noreply;
                {error, Code} ->
                    {reply, error_msg(Code)}
            end
    end;
modify(SwitchId, #ofp_meter_mod{command = delete, meter_id = all} = MeterMod) ->
    TId = linc:lookup(SwitchId, linc_meter_ets),
    Entries = ets:tab2list(TId),
    [modify(SwitchId, MeterMod#ofp_meter_mod{meter_id = Id})
     || {Id, _Pid} <- Entries],
    noreply;
modify(SwitchId, #ofp_meter_mod{command = delete, meter_id = Id}) ->
    linc_us4_oe_flow:delete_where_meter(SwitchId, Id),
    case get_meter_pid(SwitchId, Id) of
        undefined ->
            ok;
        Pid ->
            stop(SwitchId, Pid)
    end,
    noreply.

%% @doc Update flow entry count associated with a meter.
-spec update_flow_count(integer(), integer(), integer()) -> any().
update_flow_count(SwitchId, Id, Incr) ->
    case get_meter_pid(SwitchId, Id) of
        undefined ->
            ?DEBUG("Updating flow count of an non existing meter ~p", [Id]);
        Pid ->
            gen_server:cast(Pid, {update_flow_count, Incr})
    end.

%% @doc Apply meter to a packet.
-spec apply(integer(), integer(), #linc_pkt{}) ->
                   {continue, NewPkt :: #linc_pkt{}} | drop.
apply(SwitchId, Id, Pkt) ->
    case get_meter_pid(SwitchId, Id) of
        undefined ->
            ?DEBUG("Applying non existing meter ~p", [Id]),
            drop;
        Pid ->
            gen_server:call(Pid, {apply, Pkt})
    end.

%% @doc Get meter statistics.
-spec get_stats(integer(), integer() | all) ->
                       Reply :: #ofp_meter_stats_reply{}.
get_stats(SwitchId, all) ->
    TId = linc:lookup(SwitchId, linc_meter_ets),
    Meters = [gen_server:call(Pid, get_state)
              || {_, Pid} <- lists:keysort(1, ets:tab2list(TId))],
    #ofp_meter_stats_reply{body = [export_stats(Meter) || Meter <- Meters]};
get_stats(SwitchId, Id) when is_integer(Id) ->
    case get_meter_pid(SwitchId, Id) of
        undefined ->
            #ofp_meter_stats_reply{body = []};
        Pid ->
            Meter = gen_server:call(Pid, get_state),
            #ofp_meter_stats_reply{body = [export_stats(Meter)]}
    end.

%% @doc Get meter configuration.
-spec get_config(integer(), integer() | all) ->
                        Reply :: #ofp_meter_config_reply{}.
get_config(SwitchId, all) ->
    TId = linc:lookup(SwitchId, linc_meter_ets),
    Meters = [gen_server:call(Pid, get_state)
              || {_, Pid} <- lists:keysort(1, ets:tab2list(TId))],
    #ofp_meter_config_reply{body = [export_meter(Meter) || Meter <- Meters]};
get_config(SwitchId, Id) when is_integer(Id)  ->
    case get_meter_pid(SwitchId, Id) of
        undefined ->
            #ofp_meter_config_reply{body = []};
        Pid ->
            Meter = gen_server:call(Pid, get_state),
            #ofp_meter_config_reply{body = [export_meter(Meter)]}
    end.

%% @doc Get meter features.
-spec get_features() -> Reply :: #ofp_meter_features_reply{}.
get_features() ->
    #ofp_meter_features_reply{max_meter = ?MAX,
                              band_types = ?SUPPORTED_BANDS,
                              capabilities = ?SUPPORTED_FLAGS,
                              max_bands = ?MAX_BANDS,
                              max_color = 0}.

%% @doc Check if meter with a given id exists.
-spec is_valid(integer(), integer()) -> boolean().
is_valid(SwitchId, Id) ->
    case get_meter_pid(SwitchId, Id) of
        undefined ->
            false;
        _Else ->
            true
    end.

%%------------------------------------------------------------------------------
%% Internal API functions
%%------------------------------------------------------------------------------

start(SwitchId, MeterMod) ->
    Sup = linc:lookup(SwitchId, linc_meter_sup),
    supervisor:start_child(Sup, [MeterMod]).

stop(SwitchId, Pid) ->
    Sup = linc:lookup(SwitchId, linc_meter_sup),
    supervisor:terminate_child(Sup, Pid).

start_link(SwitchId, MeterMod) ->
    gen_server:start_link(?MODULE, [SwitchId, MeterMod], []).

%%------------------------------------------------------------------------------
%% gen_server callbacks
%%------------------------------------------------------------------------------

init([SwitchId, #ofp_meter_mod{meter_id = Id} = MeterMod]) ->
    process_flag(trap_exit, true),
    TId = linc:lookup(SwitchId, linc_meter_ets),
    case import_meter(MeterMod) of
        {ok, State} ->
            ets:insert(TId, {Id, self()}),
            {ok, State#linc_meter{ets = TId}};
        {error, Code} ->
            {stop, Code}
    end.

handle_call({apply, Pkt}, _From, #linc_meter{rate_value = Value,
                                             burst = UseBurstSize,
                                             burst_history = Bursts,
                                             pkt_count = Pkts,
                                             byte_count = Bytes,
                                             bands = Bands} = State) ->
    PktBytes = Pkt#linc_pkt.size,
    NewPkts = Pkts + 1,
    NewBytes = Bytes + PktBytes,
    Now = now(),

    BurstPeriod =
        case Bands of
            _ when not UseBurstSize ->
                0;
            [] ->
                0;
            [_|_] ->
                lists:max(lists:map(fun(#linc_meter_band{
                                           rate = Rate,
                                           burst_size = BurstSize}) ->
                                            BurstSize * 1000000 / Rate
                                    end, Bands))
        end,
    %% Keep history for 1 second, to calculate the current rate, or
    %% for the time needed to accomodate the burst size if that is
    %% longer.
    KeepHistoryFor = max(1000000, BurstPeriod),
    NewBursts = [{Now, PktBytes}] ++
        %% The history list is sorted by decreasing timestamps, so we
        %% can just chop off the tail.
        lists:takewhile(fun({Ts, _}) -> timer:now_diff(Now, Ts) < KeepHistoryFor end,
                        Bursts),

    %% Check packets during the last second, to determine current rate.
    Rate = sum_traffic(Value, Now, 1000000, NewBursts),

    {Reply, NewBands} = apply_band(Value, Now, Rate, Pkt, Bands,
                                   case UseBurstSize of
                                       true ->
                                           NewBursts;
                                       false ->
                                           no_burst_size
                                   end),
    {reply, Reply, State#linc_meter{burst_history = NewBursts,
                                    pkt_count = NewPkts,
                                    byte_count = NewBytes,
                                    bands = NewBands}};
handle_call(get_state, _From, State) ->
    {reply, State, State}.

handle_cast({update_flow_count, Incr},
            #linc_meter{flow_count = Flows} = State) ->
    {noreply, State#linc_meter{flow_count = Flows + Incr}}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #linc_meter{ets = TId,
                               id = Id}) ->
    ets:delete_object(TId, {Id, self()}),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%------------------------------------------------------------------------------
%% Internal functions
%%------------------------------------------------------------------------------

sum_traffic(kbps, Now, KeepInterval, Bursts) ->
    Bytes = sum_bytes(Now, KeepInterval, Bursts, 0),
    Bytes * 8 div 1000;
sum_traffic(pktps, Now, KeepInterval, Bursts) ->
    sum_packets(Now, KeepInterval, Bursts, 0).

sum_bytes(_, _, [], Bytes) ->
    Bytes;
sum_bytes(Now, KeepInterval, [{Ts, PacketBytes} | Tail], Bytes) ->
    case timer:now_diff(Now, Ts) of
        Elapsed when Elapsed < KeepInterval ->
            sum_bytes(Now, KeepInterval, Tail, Bytes + PacketBytes);
        _ ->
            Bytes
    end.

sum_packets(_, _, [], Packets) ->
    Packets;
sum_packets(Now, KeepInterval, [{Ts, _} | Tail], Packets) ->
    case timer:now_diff(Now, Ts) of
        Elapsed when Elapsed < KeepInterval ->
            sum_packets(Now, KeepInterval, Tail, Packets + 1);
        _ ->
            Packets
    end.

apply_band(Unit, Now, Rate, Pkt, Bands, Bursts) ->
    case find_the_right_band(Unit, Now, Rate, Bands, Bursts) of
        false ->
            {{continue, Pkt}, Bands};
        N ->
            R = case lists:nth(N, Bands) of
                    #linc_meter_band{type = drop} ->
                        drop;
                    #linc_meter_band{type = dscp_remark,
                                     prec_level = Prec} ->
                        NewPkt = linc_us4_oe_packet:decrement_dscp(Pkt, Prec),
                        {continue, NewPkt};
                    #linc_meter_band{type = experimenter,
                                     experimenter = _ExperimenterId} ->
                        %%
                        %% Put your EXPERIMENTER band code here
                        %%
                        {continue, Pkt}
                end,
            {R, update_band(N, Bands, Pkt#linc_pkt.size)}
    end.

find_the_right_band(Unit, Now, Rate, Bands, Bursts) ->
    F = fun(#linc_meter_band{rate = BRate, burst_size = BurstSize},
            {HRate, HighN, N}) when Rate > BRate, BRate > HRate ->
                %% The current rate is higher than the rate of
                %% this band.  Are we in a "burst" that should
                %% be allowed for now?
                if Bursts =:= no_burst_size ->
                        %% Burst flag disabled.
                        {BRate, N, N + 1};
                   is_list(Bursts) ->
                        BurstPeriod = BurstSize * 1000000 / BRate,
                        BurstPeriodTraffic = sum_traffic(Unit, Now, BurstPeriod, Bursts),
                        if BurstPeriodTraffic =< BurstSize ->
                                %% The burst is smaller than the
                                %% allowed burst size: allow it.
                                {HRate, HighN, N + 1};
                           BurstPeriodTraffic > BurstSize ->
                                %% The burst exceeds the allowed burst
                                %% size: apply the meter band.
                                {BRate, N, N + 1}
                        end
                end;
           (#linc_meter_band{}, {HRate, HighN, N}) ->
                %% The configured rate of the meter band is either
                %% higher than the current traffic rate, or lower than
                %% another meter band that we've already chosen.
                {HRate, HighN, N + 1}
        end,
    case lists:foldl(F, {-1, 0, 1}, Bands) of
        {-1, 0, _} ->
            false;
        {_, N, _} ->
            N
    end.

update_band(1, [Band | Bands], NewBytes) ->
    #linc_meter_band{pkt_count = Pkts,
                     byte_count = Bytes} = Band,
    [Band#linc_meter_band{pkt_count = Pkts + 1,
                          byte_count = Bytes + NewBytes} | Bands];
update_band(N, [Band | Bands], Bytes) ->
    [Band | update_band(N - 1, Bands, Bytes)].

import_meter(#ofp_meter_mod{meter_id = Id,
                            flags = Flags,
                            bands = Bands}) ->
    case import_flags(Flags) of
        {true, {Value, Burst, Stats}} ->
            NewBands = lists:map(fun import_band/1, Bands),
            case lists:any(fun(X) -> X == error end, NewBands) of
                false ->
                    NewMeter = #linc_meter{id = Id,
                                           rate_value = Value,
                                           burst = Burst,
                                           stats = Stats,
                                           bands = NewBands},
                    {ok, NewMeter};
                true ->
                    {error, bad_band}
            end;
        false ->
            {error, bad_flags}
    end.

-spec import_flags([atom()]) ->
                          {'true', {'pktps' | 'kbps', Burst::boolean(), Stats::boolean()}} |
                          'false'.
import_flags(Flags) ->
    SortFlags = lists:usort(Flags),
    case ordsets:is_subset(SortFlags, ?SUPPORTED_FLAGS)
        andalso not ordsets:is_subset([kbps, pktps], SortFlags) of
        true ->
            Value = case lists:member(pktps, Flags) of
                        true ->
                            pktps;
                        false ->
                            kbps
                    end,
            Burst = lists:member(burst, Flags),
            Stats = lists:member(stats, Flags),
            {true, {Value, Burst, Stats}};
        false ->
            false
    end.

import_band(#ofp_meter_band_drop{rate = Rate,
                                 burst_size = Burst}) ->
    case lists:member(drop, ?SUPPORTED_BANDS) of
        true ->
            #linc_meter_band{type = drop,
                             rate = Rate,
                             burst_size = Burst};
        false ->
            error
    end;
import_band(#ofp_meter_band_dscp_remark{rate = Rate,
                                        burst_size = Burst,
                                        prec_level = Prec}) ->
    case lists:member(dscp_remark, ?SUPPORTED_BANDS) of
        true ->
            #linc_meter_band{type = dscp_remark,
                             rate = Rate,
                             burst_size = Burst,
                             prec_level = Prec};
        false ->
            error
    end;
import_band(#ofp_meter_band_experimenter{rate = Rate,
                                         burst_size = Burst,
                                         experimenter = Exp}) ->
    case lists:member(experimenter, ?SUPPORTED_BANDS) of
        true ->
            #linc_meter_band{type = experimenter,
                             rate = Rate,
                             burst_size = Burst,
                             experimenter = Exp};
        false ->
            error
    end;
import_band(_) ->
    error.

export_stats(#linc_meter{id = Id,
                         stats = StatsEnabled,
                         bands = Bands,
                         install_ts = Then} = Meter) ->
    BandStats = [export_band_stats(StatsEnabled, Band) || Band <- Bands],
    MicroDuration = timer:now_diff(now(), Then),
    {Flows, Pkts, Bytes} = case StatsEnabled of
                               true ->
                                   #linc_meter{flow_count = F,
                                               pkt_count = P,
                                               byte_count = B} = Meter,
                                   {F, P, B};
                               false ->
                                   {-1, -1, -1}
                           end,
    #ofp_meter_stats{meter_id = Id,
                     flow_count = Flows,
                     packet_in_count = Pkts,
                     byte_in_count = Bytes,
                     duration_sec = MicroDuration div 1000000,
                     duration_nsec = (MicroDuration rem 1000) * 1000,
                     band_stats = BandStats}.

export_band_stats(true, #linc_meter_band{pkt_count = Pkts,
                                         byte_count = Bytes}) ->
    #ofp_meter_band_stats{packet_band_count = Pkts,
                          byte_band_count = Bytes};
export_band_stats(false, _Band) ->
    #ofp_meter_band_stats{packet_band_count = -1,
                          byte_band_count = -1}.

export_meter(#linc_meter{id = Id,
                         rate_value = Value,
                         burst = Burst,
                         stats = Stats,
                         bands = Bands}) ->
    NewBands = lists:map(fun export_band/1, Bands),
    #ofp_meter_config{flags = export_flags(Value, Burst, Stats),
                      meter_id = Id,
                      bands = NewBands}.

export_band(#linc_meter_band{type = Type,
                             rate = Rate,
                             burst_size = Burst,
                             prec_level = Prec,
                             experimenter = Exp}) ->
    case Type of
        drop ->
            #ofp_meter_band_drop{type = Type,
                                 rate = Rate,
                                 burst_size = Burst};
        dscp_remark ->
            #ofp_meter_band_dscp_remark{type = Type,
                                        rate = Rate,
                                        burst_size = Burst,
                                        prec_level = Prec};
        experimenter ->
            #ofp_meter_band_experimenter{type = Type,
                                         rate = Rate,
                                         burst_size = Burst,
                                         experimenter = Exp}
    end.

export_flags(Value, true, true) ->
    [Value, burst, stats];
export_flags(Value, true, false) ->
    [Value, burst];
export_flags(Value, false, true) ->
    [Value, stats];
export_flags(Value, false, false) ->
    [Value].

get_meter_pid(SwitchId, Id) ->
    TId = linc:lookup(SwitchId, linc_meter_ets),
    case ets:lookup(TId, Id) of
        [] ->
            undefined;
        [{Id, Pid}] ->
            Pid
    end.

error_msg(Code) ->
    #ofp_error_msg{type = meter_mod_failed,
                   code = Code}.
