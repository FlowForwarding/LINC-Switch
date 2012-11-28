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
-module(linc_us4_meters).

%% API
-export([initialize/0,
         terminate/0,
         modify/1,
         update_flow_count/2,
         apply/2,
         get_stats/1,
         get_config/1,
         get_features/0,
         is_valid/1]).

-include_lib("of_protocol/include/ofp_v4.hrl").

-define(SUPPORTED_BANDS, [drop,
                          dscp_remark,
                          experimenter]).
-define(SUPPORTED_FLAGS, [%% burst,
                          kbps,
                          pktps,
                          stats]).

-record(linc_meter_band, {
          type :: drop | dscp_remark | experimenter,
          rate :: integer(),
          prec_level :: integer() | undefined,
          experimenter :: integer() | undefined,
          pkt_count = 0 :: integer(),
          byte_count = 0 :: integer()
         }).

-record(linc_meter, {
          id :: integer(),
          rate_value :: kbps | pktps | {burst, kbps | pktps},
          stats = true :: boolean(),
          bands :: [#linc_meter_band{}],
          flow_count = 0 :: integer(),
          pkt_count = 0 :: integer(),
          byte_count = 0 :: integer(),
          install_ts = now() :: {integer(), integer(), integer()}
         }).

-define(TAB, linc_meters).

%% FIXME: Get from "linc_us4.hrl"
-define(MAX, (1 bsl 24)).

%%------------------------------------------------------------------------------
%% API functions
%%------------------------------------------------------------------------------

%% @doc Setup meters.
-spec initialize() -> any().
initialize() ->
    ets:new(?TAB,
            [named_table, public,
             {keypos, #linc_meter.id},
             {read_concurrency, true}]).

%% @doc Cleanup after meters.
-spec terminate() -> any().
terminate() ->
    ets:delete(?TAB).

%% @doc Add, modify or delete a meter.
-spec modify(#ofp_meter_mod{}) -> noreply | {reply, Reply :: ofp_message_body()}.
modify(#ofp_meter_mod{command = add, meter_id = Id} = MeterMod) ->
    case ets:lookup(?TAB, Id) of
        [] ->
            case add_meter(MeterMod) of
                ok ->
                    noreply;
                {error, Code} ->
                    {reply, #ofp_error_msg{type = meter_mod_failed,
                                           code = Code}}
            end;
        _Else ->
            {reply, #ofp_error_msg{type = meter_mod_failed,
                                   code = meter_exists}}
    end;
modify(#ofp_meter_mod{command = modify, meter_id = Id} = MeterMod) ->
    case ets:lookup(?TAB, Id) of
        [] ->
            {reply, #ofp_error_msg{type = meter_mod_failed,
                                   code = unknown_meter}};
        _Else ->
            case add_meter(MeterMod) of
                ok ->
                    noreply;
                {error, Code} ->
                    {reply, #ofp_error_msg{type = meter_mod_failed,
                                           code = Code}}
            end
    end;
modify(#ofp_meter_mod{command = delete, meter_id = Id}) ->
    %% FIXME:
    %% linc_us4_flows:delete_where_meter(Id),
    ets:delete(?TAB, Id),
    noreply.

%% @doc Update flow entry count associated with a meter.
-spec update_flow_count(integer(), integer()) -> any().
update_flow_count(Id, Incr) ->
    ets:update_counter(?TAB, Id, {#linc_meter.flow_count, Incr}).

%% @doc Apply meter to a packet.
%% FIXME:
%% -spec apply(integer(), #ofs_pkt{}) -> {continue, NewPkt :: #ofs_pkt{}} | drop.
apply(Id, Pkt) ->
    [#linc_meter{rate_value = Value,
                 install_ts = Then,
                 bands = Bands} = Meter] = ets:lookup(?TAB, Id),
    Seconds = timer:now_diff(now(), Then) div 1000000,
    Rate = case Value of
               kbps ->
                   #linc_meter{byte_count = Bytes} = Meter,
                   ((Bytes * 8) div 1000) / Seconds;
               pktps ->
                   #linc_meter{pkt_count = Pkts} = Meter,
                   Pkts / Seconds
               %% TODO:
               %% {burst, kbps} ->
               %%     todo;
               %% {burst, pktps} ->
               %%     todo
           end,
    apply_band(Rate, Pkt, Bands).

%% @doc Get meter statistics.
-spec get_stats(integer() | all) -> Reply :: #ofp_meter_stats_reply{}.
get_stats(all) ->
    #ofp_meter_stats_reply{body = [export_stats(Meter)
                                   || Meter <- ets:tab2list(?TAB)]};
get_stats(Id) when is_integer(Id) ->
    #ofp_meter_stats_reply{body = [export_stats(Meter)
                                   || Meter <- ets:lookup(?TAB, Id)]}.

%% @doc Get meter configuration.
-spec get_config(integer() | all) -> Reply :: #ofp_meter_config_reply{}.
get_config(all) ->
    #ofp_meter_config_reply{body = [export_meter(Meter)
                                    || Meter <- ets:tab2list(?TAB)]};
get_config(Id) when is_integer(Id)  ->
    #ofp_meter_config_reply{body = [export_meter(Meter)
                                    || Meter <- ets:lookup(?TAB, Id)]}.

%% @doc Get meter features.
-spec get_features() -> Reply :: #ofp_meter_features_reply{}.
get_features() ->
    #ofp_meter_features_reply{max_meter = ?MAX,
                              band_types = ?SUPPORTED_BANDS,
                              capabilities = ?SUPPORTED_FLAGS,
                              max_bands = ?MAX,
                              max_color = 0}.

%% @doc Check if meter with a given id exists.
-spec is_valid(integer()) -> boolean().
is_valid(Id) ->
    case ets:lookup(?TAB, Id) of
        [] ->
            false;
        _Else ->
            true
    end.

%%------------------------------------------------------------------------------
%% Internal functions
%%------------------------------------------------------------------------------

apply_band(Rate, Pkt, Bands) ->
    case find_the_right_band(Rate, Bands) of
        false ->
            {continue, Pkt};
        #linc_meter_band{type = drop} ->
            drop;
        #linc_meter_band{type = dscp_remark,
                         prec_level = _Prec} ->
            %% FIXME:
            %% NewPkt = linc_us4_packet:descrement_dscp(Pkt, Prec),
            NewPkt = Pkt,
            {continue, NewPkt};
        #linc_meter_band{type = experimenter,
                         experimenter = _ExperimenterId} ->
            %%
            %% Put your EXPERIMENTER band code here
            %%
            {continue, Pkt}
    end.

find_the_right_band(Rate, Bands) ->
    F = fun(Band, Acc) ->
                HRate = Acc#linc_meter_band.rate,
                BRate = Band#linc_meter_band.rate,
                case Rate > BRate andalso BRate > HRate of
                    true ->
                        Band;
                    false ->
                        Acc
                end
        end,
    lists:foldl(F, #linc_meter_band{rate = -1}, Bands).

add_meter(#ofp_meter_mod{meter_id = Id,
                         flags = Flags,
                         bands = Bands}) ->
    case import_flags(Flags) of
        {true, {Value, Stats}} ->
            NewBands = [import_band(Value, Band) || Band <- Bands],
            case lists:any(fun(X) -> X == error end, NewBands) of
                false ->
                    NewMeter = #linc_meter{id = Id,
                                           rate_value = Value,
                                           stats = Stats,
                                           bands = NewBands},
                    ets:insert(?TAB, NewMeter),
                    ok;
                true ->
                    {error, bad_band}
            end;
        false ->
            {error, bad_flags}
    end.

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
            Value2 = case lists:member(burst, Flags) of
                         true ->
                             {burst, Value};
                         false ->
                             Value
                     end,
            {true, {Value2, lists:member(stats, Flags)}};
        false ->
            false
    end.

import_band(Value, #ofp_meter_band_drop{rate = Rate,
                                        burst_size = Burst}) ->
    case lists:member(drop, ?SUPPORTED_BANDS) of
        true ->
            #linc_meter_band{type = drop,
                             rate = case Value of
                                        {burst, _} ->
                                            Burst;
                                        _Else ->
                                            Rate
                                    end};
        false ->
            error
    end;
import_band(Value, #ofp_meter_band_dscp_remark{rate = Rate,
                                               burst_size = Burst,
                                               prec_level = Prec}) ->
    case lists:member(dscp_remark, ?SUPPORTED_BANDS) of
        true ->
            #linc_meter_band{type = dscp_remark,
                             rate = case Value of
                                        {burst, _} ->
                                            Burst;
                                        _Else ->
                                            Rate
                                    end,
                             prec_level = Prec};
        false ->
            error
    end;
import_band(Value, #ofp_meter_band_experimenter{rate = Rate,
                                                burst_size = Burst,
                                                experimenter = Exp}) ->
    case lists:member(experimenter, ?SUPPORTED_BANDS) of
        true ->
            #linc_meter_band{type = experimenter,
                             rate = case Value of
                                        {burst, _} ->
                                            Burst;
                                        _Else ->
                                            Rate
                                    end,
                             experimenter = Exp};
        false ->
            error
    end.

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
                     duration_nsec = MicroDuration * 1000,
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
                         stats = Stats,
                         bands = Bands}) ->
    NewBands = [export_band(Value, Band) || Band <- Bands],
    #ofp_meter_config{flags = export_flags(Value, Stats),
                      meter_id = Id,
                      bands = NewBands}.

export_band(Value, #linc_meter_band{type = Type,
                                    rate = MyRate,
                                    prec_level = Prec,
                                    experimenter = Exp}) ->
    {Rate, Burst} = export_values(Value, MyRate),
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

export_flags({burst, Value}, true) ->
    [Value, burst, stats];
export_flags({burst, Value}, false) ->
    [Value, burst];
export_flags(Value, true) ->
    [Value, stats];
export_flags(Value, false) ->
    [Value].

export_values({burst, _}, Rate) ->
    {-1, Rate};
export_values(_Else, Rate) ->
    {Rate, -1}.
