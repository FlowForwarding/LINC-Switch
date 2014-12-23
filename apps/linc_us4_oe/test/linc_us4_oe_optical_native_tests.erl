-module(linc_us4_oe_optical_native_tests).

-include_lib("eunit/include/eunit.hrl").

optical_port_test_() ->
    {setup, fun setup/0, fun teardown/1,
     {timeout, 10,
      [{"Test messages passes between two optical ports",
        fun messages_passes/0}]}
    }.

messages_passes() ->
    setup_test_process(),
    [Port1, Port2] = start_two_optical_ports_and_assert_link_is_up(),
    assert_messages_pass(Port1, Port2),
    stop_optical_ports([Port1, Port2]).

fail() ->
    ?assert(false).

setup() ->
    ok = meck:new(linc_oe),
    ok = meck:expect(linc_oe, add_mapping_ofp_to_optical_port,
                     fun(_, _, _) ->
                             ok
                     end),
    ok = meck:expect(linc_oe, get_optical_peer_pid,
                     fun(_, _) ->
                             throw(optical_peer_not_ready)
                     end),
    ok = meck:new(linc_us4_oe_port),
    ok = meck:expect(linc_us4_oe_port, set_state,
                     fun(_, _, _) ->
                             ok
                     end).

teardown(_) ->
    [meck:unload(M) || M <- [linc_oe, linc_us4_oe_port]].

assert_messages_pass(OpticalPort1, OpticalPort2) ->
    [begin
         {Port1, Port2} = shuffle_pair({OpticalPort1, OpticalPort2}),
         send_message(Port1, Msg = random_message()),
         assert_message_received(Port2, Msg)
     end || _ <- lists:seq(1, 100)].

send_message(From, Msg) ->
    linc_us4_oe_optical_native:send(From, Msg).

assert_message_received(From, Msg) ->
    receive
        {optical_data, From, Msg} ->
            ok
    after 1000 ->
            fail()
    end.

shuffle_pair({E1, E2} = Pair) ->
    case random:uniform(2) of
        1 ->
            Pair;
        _ ->
            {E2, E1}
    end.

random_message() ->
    << <<(random:uniform(255))>> || _ <- lists:seq(1, 10) >>.
        
setup_test_process() ->
    process_flag(trap_exit, true),
    random:seed().

start_two_optical_ports_and_assert_link_is_up() ->
    OFPPortPid = self(),
    Pids = [OpticalPort1, OpticalPort2] =
        [begin
             {ok, Pid} =linc_us4_oe_optical_native:start_link(SwitchId,
                                                              PortNo,
                                                              OFPPortPid),
             Pid
         end || {SwitchId, PortNo} <- [{0, 1}, {1, 2}]],
    ok = meck:expect(linc_us4_oe_port, set_state,
                     fun(_, _, []) ->
                             OFPPortPid ! {link_up, self()},
                             ok
                     end),
    ok = meck:expect(linc_oe, get_optical_peer_pid,
                     fun(0, 1) ->
                             OpticalPort2;
                        (1, 2) ->
                             OpticalPort1
                     end),
    receive
        {link_up, OpticalPort1} ->
            ok
    end,
    receive
        {link_up, OpticalPort2} ->
            ok
    end,
    Pids.

stop_optical_ports(Pids) ->
    ok = meck:expect(linc_us4_oe_port, set_state,
                     fun(_, _, _) ->
                             ok
                     end),
    [linc_us4_oe_optical_native:stop(P) || P <- Pids].
