%%------------------------------------------------------------------------------
%% Copyright 2014 FlowForwarding.org
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
%% @copyright 2014 FlowForwarding.org
%% @doc Module providing load regulation for an Open Flow port.
-module(linc_us4_port_load_regulator).

%% API exports
-export([schedule_periodic_check/2,
         cancel_periodic_check/1,
         limit_load_if_necessary/2]).

%% Internal exports
-export([send_load_control_message/2]).

-include_lib("of_protocol/include/of_protocol.hrl").
-include_lib("of_protocol/include/ofp_v4.hrl").
-include_lib("linc/include/linc_logger.hrl").
-include("linc_us4.hrl").
-include("linc_us4_port.hrl").

%%%-----------------------------------------------------------------------------
%%% API functions
%%%-----------------------------------------------------------------------------

-spec schedule_periodic_check(integer(), ofp_port_no()) -> timer:tref().
schedule_periodic_check(SwitchId, PortNo) ->
    {ok, TRef} = timer:apply_interval(?PERIODIC_CHECK_INTERVAL_IN_MILISECS,
                                      ?MODULE,
                                      send_load_control_message,
                                      [SwitchId, PortNo]),
    TRef.

-spec cancel_periodic_check(timer:tref()) -> ok.
cancel_periodic_check(TRef) ->
    {ok, cancel} = timer:cancel(TRef),
    ok.

%% @doc Limit load on an Open Flow port based on a control message delay.
%%
%% This function is called by an linc_us4_port while receiving a periodic
%% load control message. The message contains a time stamp created just before
%% sending. The message delay is calculated based on this time stamp and if it's
%% longer than some threshold, it's assumed that the port is overloaded.
%%
%% To determine if the overload is caused by ingress or egress traffic, number
%% of packets that had been processed during the control message
%% message was sitting in the process queue is calculated. Then if on input
%% there were more than X percent of overall traffic it's blocked; otherwise
%% output is blocked. The X value vary depending on whether the port is in normal
%% or whether it is in blocking state.
%%
%% to block input, an appropriate state is set for linc_us4_port, so that
%% packets are dropped. To block output, a flag is set in ETS table with ports.
%% Then a port that wants to send traffic through overloaded port knows
%% that it cannot do so. And as a result packets have to be dropped. A port
%% quits blocking state after the delay goes down below some threshold.
%%
%% There're 4 states of overload protection: none, drop_tx, drop_rx, drop_all.
%% Possible transitions are as follows:
%% none -> drop_tx | drop_rx | drop_all,
%% drop_rx/drop_tx -> none | drop_all,
%% drop_all -> none.
-spec limit_load_if_necessary(load_control_message(), state()) -> state().
limit_load_if_necessary(ControlMessage, State) ->
    NewProtection = calculate_overload_protection(ControlMessage, State),
    apply_overload_protection(NewProtection, State),
    log_if_protection_changed(NewProtection, State),
    State#state{overload_protection = NewProtection}.

%%%-----------------------------------------------------------------------------
%%% Internal functions
%%%-----------------------------------------------------------------------------

send_load_control_message(SwitchId, PortNo) ->
    Pid = get_port_pid(SwitchId, PortNo),
    Pid ! create_load_control_message(SwitchId, PortNo).

get_port_pid(SwitchId, PortNo) ->
    [#linc_port{pid = Pid}] = ets:lookup(linc:lookup(SwitchId, linc_ports),
                                         PortNo),
    Pid.

create_load_control_message(SwitchId, PortNo) ->
    {Rx, Tx} = get_port_packet_counters(SwitchId, PortNo),
    #load_control_message{timestamp = os:timestamp(),
                          rx_packets = Rx,
                          tx_packets = Tx}.

get_port_packet_counters(SwitchId, PortNo) ->
    [PortStats] = ets:lookup(linc:lookup(SwitchId, linc_port_stats), PortNo),
    #ofp_port_stats{rx_packets = Rx, tx_packets = Tx} = PortStats,
    {Rx, Tx}.

calculate_overload_protection(ControlMsg,
                              #state{overload_protection = Current} = State) ->
    Delay = calculate_delay_in_miliseconds(
              ControlMsg#load_control_message.timestamp),
    case is_port_delay_acceptable(Delay, Current) of
        true ->
            none;
        false ->
            recalculate_overload_protection(ControlMsg, State)
    end.

calculate_delay_in_miliseconds(OldTimestamp) ->
    (_InMicro = timer:now_diff(os:timestamp(), OldTimestamp)) div 1000.

is_port_delay_acceptable(DelayInMiliSecs, none) ->
    DelayInMiliSecs < ?ACCEPTABLE_DELAY_IN_MILSECS;
is_port_delay_acceptable(DelayInMiliSecs, _SomeProtection) ->
    DelayInMiliSecs < ?ACCEPTABLE_DELAY_IN_MILSECS_BEFORE_RECOVERY.

recalculate_overload_protection(_, #state{
                                  overload_protection = drop_all = Current}) ->
    Current;
recalculate_overload_protection(ControlMsg,
                                #state{switch_id = SwitchId,
                                       port = #ofp_port{port_no = PortNo},
                                       overload_protection = Current}) ->
    OldCounters = {ControlMsg#load_control_message.rx_packets,
                   ControlMsg#load_control_message.tx_packets},
    CurrentCounters = get_port_packet_counters(SwitchId, PortNo),
    CountersDiff = calculate_counters_diff(OldCounters, CurrentCounters),
    calculate_protection_by_packet_counters(CountersDiff, Current).

calculate_protection_by_packet_counters({RxDiff, TxDiff}, none) ->
    Sum = (RxDiff + TxDiff),
    if
        RxDiff > ?PKTS_RATIO_BETWEEN_RX_AND_SUM_WITHOUT_PROTECTION * Sum ->
            drop_rx;
        TxDiff > ?PKTS_RATIO_BETWEEN_TX_AND_SUM_WITHOUT_PROTECTION * Sum ->
            drop_tx;
        true ->
            drop_all
    end;
calculate_protection_by_packet_counters({RxDiff, TxDiff}, drop_rx = Current) ->
    if
        TxDiff >
        ?PKTS_RATIO_BETWEEN_TX_AND_SUM_WITH_DROP_RX * (RxDiff + TxDiff) ->
            drop_all;
        true ->
            Current
    end;
calculate_protection_by_packet_counters({RxDiff, TxDiff}, drop_tx = Current) ->
    if
        RxDiff >
        ?PKTS_RATIO_BETWEEN_RX_AND_SUM_WITH_DROP_TX * (RxDiff + TxDiff) ->
            drop_all;
        true ->
            Current
    end.

calculate_counters_diff({OldRx, OldTx}, {CurrentRx, CurrentTx}) ->
    {CurrentRx - OldRx, CurrentTx - OldTx}.

apply_overload_protection(New, #state{overload_protection = Current})
  when New == Current ->
    Current;
apply_overload_protection(New, #state{switch_id = SwitchId,
                                      port = #ofp_port{port_no = PortNo}}) ->
    case New of
        P when P == drop_rx orelse P == none ->
            set_drop_tx(SwitchId, PortNo, false);
        P when P == drop_tx orelse P == drop_all ->
            set_drop_tx(SwitchId, PortNo, true)
    end.

set_drop_tx(SwitchId, PortNo, DropTxState) ->
    true = ets:update_element(linc:lookup(SwitchId, linc_ports), PortNo,
                              {#linc_port.drop_tx, DropTxState}).

log_if_protection_changed(New, #state{switch_id = SwitchId,
                                      port = #ofp_port{port_no = PortNo},
                                      overload_protection = Current}) ->
    [?DEBUG("Switch ID: ~p | Port no: ~p | Protection set to to: ~p",
            [SwitchId, PortNo, New]) || New /= Current].
