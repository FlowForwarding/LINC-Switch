-module(linc_us4_port_load_regulator_tests).

-include_lib("eunit/include/eunit.hrl").

-include_lib("of_protocol/include/of_protocol.hrl").
-include_lib("of_protocol/include/ofp_v4.hrl").
-include("linc_us4.hrl").
-include("linc_us4_port.hrl").

-define(SWITCH_ID, 0).
-define(PORT_NO, 1).
-define(ZERO_HOUR, {0,0,0}).

%% Test generators --------------------------------------------------------------

load_control_message_test_() ->
    {setup,
     fun setup/0,
     fun teardown/1,
     {"Test if a load control message will be sent periodically",
      fun load_regulation_message_should_be_received_periodically/0}}.

activating_load_regulation_test_() ->
    {setup,
     fun setup/0,
     fun teardown/1,
     [
      {"Test if load regulation is not activated",
       fun load_regulation_should_not_be_activated/0},
      {"Test if load regulation is activated",
       fun load_regulation_should_be_activated/0}
     ]}.

activating_load_regulation_type_test_() ->
    {setup,
     fun setup/0,
     fun teardown/1,
     [
      {"Test if dropping packets on ingress will be activated when no protection"
       " is currently set", fun drop_rx_should_be_activated/0},
      {"Test if dropping packets on egress will be activated when no protection"
       " is currently set", fun drop_tx_should_be_activated/0},
      {"Test if dropping packets on ingress and egress will be activated when"
       " no protection is currently set",
       fun() -> drop_all_should_be_activated(none) end},
      {"Test if any protection will be canceled when dropping on ingress",
       fun() -> none_should_be_activated(drop_rx) end},
      {"Test if dropping packets on ingress and egress will be activated when"
       " dropping on ingress",
       fun() -> drop_all_should_be_activated(drop_rx) end},
      {"Test if any protection will be canceled when dropping on egress",
       fun() -> none_should_be_activated(drop_tx) end},
      {"Test if dropping packets on ingress and egress will be activated when"
       " dropping on egress",
       fun() -> drop_all_should_be_activated(drop_tx) end},
      {"Test if any protection will be canceled when dropping on ingress "
       "and egress", fun() -> none_should_be_activated(drop_all) end}
     ]}.

%% Tests ------------------------------------------------------------------------

load_regulation_should_not_be_activated() ->
    %% GIVEN
    ControlMsg = init_load_control_msg(os:timestamp(), 0, 0),
    PortState = init_port_state(InitProtection = none),
    %% and we assume that linc_us4_port_load_regulator:limit_load_if_necesseary/2
    %% won't execute longer than acceptable delay (as defined in linc_us4_port
    %% by ACCEPTABLE_DELAY_IN_MILSECS)

    %% WHEN
    UpdatedPortState =
        linc_us4_port_load_regulator:limit_load_if_necessary(ControlMsg,
                                                             PortState),

    %% THEN
    NewProtection = UpdatedPortState#state.overload_protection,
    ?assertEqual(InitProtection, NewProtection).

load_regulation_should_be_activated() ->
    %% GIVEN
    ControlMsg = init_load_control_msg(?ZERO_HOUR, 200, 100),
    PortState = init_port_state(InitProtection = none),
    ?assert(timer:now_diff(os:timestamp(), ?ZERO_HOUR)
            > ?ACCEPTABLE_DELAY_IN_MILSECS),

    %% WHEN
    UpdatedPortState =
        linc_us4_port_load_regulator:limit_load_if_necessary(ControlMsg,
                                                             PortState),

    %% THEN
    NewProtection = UpdatedPortState#state.overload_protection,
    ?assertNot(InitProtection == NewProtection).

drop_rx_should_be_activated() ->
    %% GIVEN
    ControlMsg = init_load_control_msg(?ZERO_HOUR, OldRx = 100, OldTx = 100),
    PortState = init_port_state(none),
    update_port_stats(NewRx = 161, NewTx = 139),
    Diff = (RxDiff = NewRx - OldRx) + (NewTx - OldTx),
    ?assert(RxDiff > ?PKTS_RATIO_BETWEEN_RX_AND_SUM_WITHOUT_PROTECTION * Diff),

    %% WHEN
    UpdatedPortState =
        linc_us4_port_load_regulator:limit_load_if_necessary(ControlMsg,
                                                             PortState),

    %% THEN
    NewProtection = UpdatedPortState#state.overload_protection,
    ?assertEqual(drop_rx, NewProtection).

drop_tx_should_be_activated() ->
    %% GIVEN
    ControlMsg = init_load_control_msg(?ZERO_HOUR, OldRx = 100, OldTx = 100),
    PortState = init_port_state(none),
    update_port_stats(NewRx = 139, NewTx = 161),
    Diff = (NewRx - OldRx) + (TxDiff = NewTx - OldTx),
    ?assert(TxDiff > ?PKTS_RATIO_BETWEEN_TX_AND_SUM_WITHOUT_PROTECTION * Diff),

    %% WHEN
    UpdatedPortState =
        linc_us4_port_load_regulator:limit_load_if_necessary(ControlMsg,
                                                             PortState),

    %% THEN
    NewProtection = UpdatedPortState#state.overload_protection,
    ?assertEqual(drop_tx, NewProtection).

drop_all_should_be_activated(InitProtection = none) ->
    %% GIVEN
    ControlMsg = init_load_control_msg(?ZERO_HOUR, OldRx = 100, OldTx = 100),
    PortState = init_port_state(InitProtection),
    update_port_stats(NewRx = 200, NewTx = 200),
    Diff = (RxDiff = NewRx - OldRx) + (TxDiff = NewTx - OldTx),
    ?assertNot(
       RxDiff > ?PKTS_RATIO_BETWEEN_RX_AND_SUM_WITHOUT_PROTECTION * Diff),
    ?assertNot(
       TxDiff > ?PKTS_RATIO_BETWEEN_TX_AND_SUM_WITHOUT_PROTECTION * Diff),

    %% WHEN
    UpdatedPortState =
        linc_us4_port_load_regulator:limit_load_if_necessary(ControlMsg,
                                                             PortState),

    %% THEN
    NewProtection = UpdatedPortState#state.overload_protection,
    ?assertEqual(drop_all, NewProtection);
drop_all_should_be_activated(InitProtection) when
      InitProtection == drop_rx orelse InitProtection == drop_tx  ->
    ControlMsg = init_load_control_msg(?ZERO_HOUR, OldRx = 100, OldTx = 100),
    PortState = init_port_state(InitProtection),
    case InitProtection of
        drop_rx ->
            update_port_stats(NewRx = 109, NewTx = 191),
            Diff = (NewRx - OldRx) + (TxDiff = NewTx - OldTx),
            ?assert(
               TxDiff > ?PKTS_RATIO_BETWEEN_TX_AND_SUM_WITH_DROP_RX * Diff);
        drop_tx ->
            update_port_stats(NewRx = 191, NewTx = 109),
            Diff = (RxDiff = NewRx - OldRx) + (NewTx - OldTx),
            ?assert(
               RxDiff > ?PKTS_RATIO_BETWEEN_RX_AND_SUM_WITH_DROP_TX * Diff)
    end,

    %% WHEN
    UpdatedPortState =
        linc_us4_port_load_regulator:limit_load_if_necessary(ControlMsg,
                                                             PortState),

    %% THEN
    NewProtection = UpdatedPortState#state.overload_protection,
    ?assertEqual(drop_all, NewProtection).

none_should_be_activated(InitProtection) ->
    %% GIVEN
    ControlMsg = init_load_control_msg(os:timestamp(), 100, 100),
    PortState = init_port_state(InitProtection),
    %% and we assume that linc_us4_port_load_regulator:limit_load_if_necesseary/2
    %% won't execute longer than acceptable delay (as defined in linc_us4_port
    %% by ?ACCEPTABLE_DELAY_IN_MILSECS_BEFORE_RECOVERY)

    %% WHEN
    UpdatedPortState =
        linc_us4_port_load_regulator:limit_load_if_necessary(ControlMsg,
                                                             PortState),

    %% THEN
    NewProtection = UpdatedPortState#state.overload_protection,
    ?assertEqual(none, NewProtection).

load_regulation_message_should_be_received_periodically()->
    %% GIVEN
    RespondTo = self(),
    Pid = spawn_link(fun() ->
                             receive
                                 #load_control_message{} ->
                                     ok
                             end,
                             receive
                                 #load_control_message{} ->
                                     RespondTo ! success
                             after
                                 ?PERIODIC_CHECK_INTERVAL_IN_MILISECS * 2 ->
                                     RespondTo ! fail
                             end
                     end),
    ets:insert(linc:lookup(?SWITCH_ID, linc_ports),
               #linc_port{port_no = ?PORT_NO, pid = Pid}),

    %% WHEN
    Tref = linc_us4_port_load_regulator:schedule_periodic_check(?SWITCH_ID,
                                                                ?PORT_NO),

    %% THEN
    receive
        success ->
            ?assertEqual(
               ok, linc_us4_port_load_regulator:cancel_periodic_check(Tref));
        fail ->
            fail("Load control message failed to arrive within expected time")
    after
        ?PERIODIC_CHECK_INTERVAL_IN_MILISECS * 3 ->
            fail("Error occured while testing load control message")
    end.

%% Fixtures ---------------------------------------------------------------------

setup() ->
    linc:create(?SWITCH_ID),
    setup_linc_ports(),
    setup_linc_port_stats().

teardown(_) ->
    ets:delete(linc:lookup(?SWITCH_ID, linc_port_stats)),
    ets:delete(linc:lookup(?SWITCH_ID, linc_ports)),
    linc:delete(?SWITCH_ID).

%% Helpers ----------------------------------------------------------------------

setup_linc_ports() ->
    PortsTid = ets:new(linc_ports, [public,
                                    {keypos, #linc_port.port_no},
                                    {read_concurrency, true}]),
    ets:insert(PortsTid, #linc_port{port_no = ?PORT_NO}),
    linc:register(?SWITCH_ID, linc_ports, PortsTid).

setup_linc_port_stats() ->
    PortStatsTid = ets:new(linc_port_stats, [public,
                                             {keypos, #ofp_port_stats.port_no},
                                             {read_concurrency, true}]),
    ets:insert(PortStatsTid, #ofp_port_stats{port_no = ?PORT_NO}),
    linc:register(?SWITCH_ID, linc_port_stats, PortStatsTid).

init_port_state(InitProtection) ->
    #state{switch_id = ?SWITCH_ID, port = #ofp_port{port_no = ?PORT_NO},
           overload_protection = InitProtection}.

init_load_control_msg(Timestamp, RxPackets, TxPackets) ->
    #load_control_message{timestamp = Timestamp, rx_packets = RxPackets,
                          tx_packets = TxPackets}.

update_port_stats(Rx, Tx) ->
    ets:insert(linc:lookup(?SWITCH_ID, linc_port_stats),
               #ofp_port_stats{port_no = ?PORT_NO, rx_packets = Rx,
                               tx_packets = Tx}).

fail(Msg) ->
    ?debugMsg(Msg),
    ?assert(false).
