-module(switch_tests).
-author("Erlang Solutions Ltd. <openflow@erlang-solutions.com>").


-compile(export_all).

-include_lib("of_switch/include/ofs_userspace.hrl").
-include_lib("eunit/include/eunit.hrl").

setup() ->
    lager:start(),
    lager:set_loglevel(lager_console_backend, notice),

    application:load(of_switch),
    application:set_env(of_switch, controllers, []),
    application:set_env(of_switch, ports, []),
    application:start(of_switch).

teardown() ->
    application:stop(of_switch),
    application:unload(of_switch).

match_and_group_test() ->
    setup(),
    meck:new(ofs_userspace_port, [passthrough]),
    GroupId = 100,
    OutPort = 1,
    Match = #ofp_match{oxm_fields = [#ofp_field{
                                        field = eth_src,
                                        value = <<1,2,3>>
                                       }]},
    Pkt = #ofs_pkt{fields = Match,
                   actions = []},
    FlowMod = #ofp_flow_mod{
      command = add,
      table_id = 0,
      priority = 1,
      cookie = cookie,
      match = Match,
      instructions = [#ofp_instruction_write_actions{
                         actions = [
                                    %% this action should be omitted in the
                                    %% favour of group action
                                    #ofp_action_output{
                                       port = 200
                                      },
                                    #ofp_action_group{
                                                       group_id = GroupId
                                                     }
                                   ]
                        }]},
    GroupMod = #ofp_group_mod{
      command = add,
      group_id = GroupId,
      type = all,
      buckets = [#ofp_bucket{
                    actions = [#ofp_action_output{
                                  port = OutPort
                                 }]
                   }]
     },
    meck:expect(ofs_userspace_port, send_to_wire,
                fun(Port, Queue, OutPkt) ->
                    ?assertEqual(OutPort, Port),
                    ?assertEqual(0, Queue),
                    ?assertEqual(1, length(OutPkt#ofs_pkt.actions))
                end),
    ?assertEqual({ok, state}, ofs_userspace:ofp_flow_mod(state, FlowMod)),
    ?assertEqual({ok, state}, ofs_userspace:ofp_group_mod(state, GroupMod)),
    ?assertEqual({match, 0, output}, ofs_userspace_routing:do_route(Pkt, 0)),
    meck:unload(ofs_userspace_port),
    teardown().

match_and_apply_actions_test() ->
    meck:new(ofs_userspace_port, [passthrough]),
    setup(),
    OutPort = 1,
    Match = #ofp_match{oxm_fields = [#ofp_field{
                                        field = eth_src,
                                        value = <<1,2,3>>
                                       }]},
    Pkt = #ofs_pkt{fields = Match,
                   actions = []},
    FlowMod = #ofp_flow_mod{command = add,
                            table_id = 0,
                            priority = 1,
                            cookie = cookie,
                            match = Match,
                            instructions = [#ofp_instruction_apply_actions{
                                               actions = [
                                                          #ofp_action_output{
                                                             port = OutPort
                                                            }
                                                         ]
                                              }]},
    meck:expect(ofs_userspace_port, send, fun(Port, Queue, OutPkt) ->
                                                  ?assertEqual(OutPort, Port),
                                                  ?assertEqual(0, Queue),
                                                  ?assertEqual(0, length(OutPkt#ofs_pkt.actions))
                                          end),
    ?assertEqual({ok, state}, ofs_userspace:ofp_flow_mod(state, FlowMod)),
    %% Copy of the packet is sent to output in apply actions instruction,
    %% but original packet is dropped because there is no group/output
    %% instruction in the matching flow entry.
    ?assertEqual({match, 0, drop}, ofs_userspace_routing:do_route(Pkt, 0)),
    meck:unload(ofs_userspace_port),
    teardown().

match_but_drop_test() ->
    setup(),
    Match = #ofp_match{oxm_fields = [#ofp_field{
                                        field = eth_src,
                                        value = <<1,2,3>>
                                       }]},
    Pkt = #ofs_pkt{fields = Match},
    FlowMod = #ofp_flow_mod{command = add,
                            table_id = 0,
                            priority = 1,
                            cookie = cookie,
                            match = Match,
                            instructions = []},
    ?assertEqual({ok, state}, ofs_userspace:ofp_flow_mod(state, FlowMod)),
    ?assertEqual({match, 0, drop}, ofs_userspace_routing:do_route(Pkt, 0)),
    teardown().

match_and_goto_test() ->
    setup(),
    Match = #ofp_match{oxm_fields = [#ofp_field{
                                        field = eth_src,
                                        value = <<1,2,3>>
                                       }]},
    Pkt = #ofs_pkt{fields = Match},
    FlowMod = #ofp_flow_mod{command = add,
                            table_id = 0,
                            priority = 1,
                            cookie = cookie,
                            match = Match,
                            instructions = [#ofp_instruction_goto_table{
                                               table_id = 1
                                              }]},
    ?assertEqual({ok, state}, ofs_userspace:ofp_flow_mod(state, FlowMod)),
    ?assertEqual({nomatch, 1, controller}, ofs_userspace_routing:do_route(Pkt, 0)),
    teardown().

match_and_clear_actions_with_queue_test() ->
    meck:new(ofs_userspace_port, [passthrough]),
    setup(),
    OutPort = 1,
    QueueId = 1,
    Match = #ofp_match{oxm_fields = [#ofp_field{
                                        field = eth_src,
                                        value = <<1,2,3>>
                                       }]},
    Pkt = #ofs_pkt{fields = Match,
                   actions = [#ofp_action_copy_ttl_in{},
                              #ofp_action_pop_vlan{}]},
    FlowMod = #ofp_flow_mod{command = add,
                            table_id = 0,
                            priority = 1,
                            cookie = cookie,
                            match = Match,
                            instructions = [#ofp_instruction_clear_actions{},
                                            #ofp_instruction_write_actions{
                                                                            actions = [
                                                                                       #ofp_action_set_queue{
                                                                                          port = OutPort,
                                                                                          queue_id = QueueId
                                                                                         },
                                                                                       #ofp_action_output{
                                                                                                           port = OutPort
                                                                                                         }
                                                                                      ]}]},
    meck:expect(ofs_userspace_port, send, fun(Port, Queue, OutPkt) ->
                                                  ?assertEqual(OutPort, Port),
                                                  ?assertEqual(QueueId, Queue),
                                                  ?assertEqual(2, length(OutPkt#ofs_pkt.actions))
                                          end),
    ?assertEqual({ok, state}, ofs_userspace:ofp_flow_mod(state, FlowMod)),
    ?assertEqual({match, 0, output}, ofs_userspace_routing:do_route(Pkt, 0)),
    meck:unload(ofs_userspace_port),
    teardown().

match_and_output_with_metadata_test() ->
    meck:new(ofs_userspace_port, [passthrough]),
    setup(),
    OutPort = 1,
    QueueId = 1,
    PktMetadata = <<0,0,0,0,1,0,0,0>>,
    FlowMetadata = <<1,1,1,1,1,1,1,1>>,
    FlowMask = <<1,1,1,0,0,0,0,1>>,
    ResultMetadata = <<1,1,1,0,1,0,0,1>>,
    Match = #ofp_match{oxm_fields = [#ofp_field{
                                        field = eth_src,
                                        value = <<1,2,3>>
                                       }]},
    Pkt = #ofs_pkt{fields = Match,
                   metadata = PktMetadata},
    FlowMod = #ofp_flow_mod{command = add,
                            table_id = 0,
                            priority = 1,
                            cookie = cookie,
                            match = Match,
                            instructions = [#ofp_instruction_write_metadata{
                                               metadata = FlowMetadata,
                                               metadata_mask = FlowMask
                                              },
                                            #ofp_instruction_write_actions{
                                                                            actions = [
                                                                                       #ofp_action_set_queue{
                                                                                          port = OutPort,
                                                                                          queue_id = QueueId
                                                                                         },
                                                                                       #ofp_action_output{
                                                                                          port = OutPort
                                                                                         }
                                                                                      ]
                                                                          }]},
    meck:expect(ofs_userspace_port, send, fun(Port, Queue, OutPkt) ->
                                                  ?assertEqual(OutPort, Port),
                                                  ?assertEqual(QueueId, Queue),
                                                  ?assertEqual(ResultMetadata, OutPkt#ofs_pkt.metadata)
                                          end),
    ?assertEqual({ok, state}, ofs_userspace:ofp_flow_mod(state, FlowMod)),
    ?assertEqual({match, 0, output}, ofs_userspace_routing:do_route(Pkt, 0)),
    meck:unload(ofs_userspace_port),
    teardown().

table_miss_test() ->
    setup(),
    Pkt = #ofs_pkt{},
    TMDrop = #ofp_table_mod{table_id = 0, config = drop},
    ?assertEqual({ok, state},
                 ofs_userspace:ofp_table_mod(state, TMDrop)),
    assert_table_config(0, drop),
    ?assertEqual({nomatch, 0, drop}, ofs_userspace_routing:do_route(Pkt, 0)),
    TMContinue = #ofp_table_mod{table_id = 0, config = continue},
    ?assertEqual({ok, state},
                 ofs_userspace:ofp_table_mod(state, TMContinue)),
    assert_table_config(0, continue),
    ?assertEqual({nomatch, 1, controller},
                 ofs_userspace_routing:do_route(Pkt, 0)),
    TMController = #ofp_table_mod{table_id = 0, config = controller},
    ?assertEqual({ok, state},
                 ofs_userspace:ofp_table_mod(state, TMController)),
    assert_table_config(0, controller),
    ?assertEqual({nomatch, 0, controller},
                 ofs_userspace_routing:do_route(Pkt, 0)),
    teardown().

assert_table_config(TableId, Config) ->
    {ok, #ofp_table_stats_reply{stats = Stats}, state} =
        ofs_userspace:ofp_table_stats_request(state, #ofp_table_stats_request{}),
    T = lists:keyfind(TableId, #ofp_table_stats.table_id, Stats),
    ?assertEqual(Config, T#ofp_table_stats.config).

apply_action_group_test() ->
    setup(),

    Pkt = #ofs_pkt{},
    TableId = 0,
    NonExistentGroupId = 1,

    ?assertEqual(Pkt, ofs_userspace_routing:apply_action_list(TableId,
                                                              [#ofp_action_group{group_id = NonExistentGroupId}],
                                                              Pkt)),
    teardown().

apply_action_queue_and_output_test() ->
    setup(),

    Pkt = #ofs_pkt{},
    TableId = 0,
    PortId = 1,
    QueueId = 1,

    NewPkt1 = ofs_userspace_routing:apply_action_list(TableId,
                                                      [#ofp_action_set_queue{queue_id = QueueId}],
                                                      Pkt),
    ?assertEqual(QueueId, NewPkt1#ofs_pkt.queue_id),

    meck:new(ofs_userspace_port),
    meck:expect(ofs_userspace_port,
                send,
                fun(P, Q, _) when P == PortId andalso Q == QueueId ->
                        ok
                end),
    NewPkt1 = ofs_userspace_routing:apply_action_list(TableId,
                                                      [#ofp_action_output{port = PortId}],
                                                      NewPkt1),
    ?assertEqual(QueueId, NewPkt1#ofs_pkt.queue_id),
    ?assert(meck:validate(ofs_userspace_port)),
    meck:unload(ofs_userspace_port),
    teardown().

port_test() ->
    setup(),
    GoodPort = 1,
    BadPort = 99,
    GoodQueue1 = 1,
    GoodQueue2 = 2,
    BadQueue = 999,
    Pkt = #ofs_pkt{},

    %% Mock packet creation
    meck:new(pkt),
    meck:expect(pkt, encapsulate, fun(_) -> <<>> end),

    meck:new(ofs_userspace_port_procket),
    meck:expect(ofs_userspace_port_procket, send, fun(_, _) -> ok end),
    meck:expect(ofs_userspace_port_procket, close, fun(_) -> ok end),

    %% Mock usage of libpcap by switch to receive ethernet frames
    meck:new(epcap),
    meck:expect(epcap, start, fun(_) -> {ok, pid} end),
    meck:expect(epcap, stop, fun(_) -> ok end),

    %% Mock creation of RAW socket under Mac
    meck:new(bpf),
    meck:expect(bpf, open, fun(Iface) -> {ok, Iface, 0} end),
    meck:expect(bpf, ctl, fun(_, _, _) -> ok end),

    %% Mock creation of RAW socket under Linux
    meck:new(packet),
    meck:expect(packet, socket, fun() -> {ok, 0} end),
    meck:expect(packet, ifindex, fun(_, _) -> 0 end),
    meck:expect(packet, promiscuous, fun(_, _) -> ok end),
    meck:expect(packet, bind, fun(_, _) -> ok end),
    meck:expect(packet, send, fun(_, _, _) -> ok end),

    ?assertEqual([], ofs_userspace_port:list_ports()),

    application:load(of_switch),
    application:set_env(of_switch, backends,
                        [{userspace, [{ports,
                                       [{GoodPort, [{interface, "zxc5"}]}]
                                      }]}]),

    ofs_userspace:add_port(physical, {GoodPort,[{rate, {10, kbps}},
                                                {queues, [{0, []}]}]}),
    ?assertEqual(1, length(ofs_userspace_port:list_ports())),
    ?assertEqual(1, length(ofs_userspace_port:get_port_stats())),
    ?assert(is_record(ofs_userspace_port:get_port_stats(GoodPort),
                      ofp_port_stats)),
    ?assertEqual(bad_port, ofs_userspace_port:get_port_stats(BadPort)),

    ?assertEqual(bad_port, ofs_userspace_port:list_queues(BadPort)),
    ?assertEqual(2, length(ofs_userspace_port:list_queues(GoodPort))),

    ?assertEqual(bad_port, ofs_userspace_port:attach_queue(BadPort,
                                                           GoodQueue1,
                                                           [])),
    ofs_userspace_port:attach_queue(GoodPort, GoodQueue1, []),
    ofs_userspace_port:attach_queue(GoodPort, GoodQueue2, []),
    ?assertEqual(4, length(ofs_userspace_port:list_queues(GoodPort))),

    ?assertEqual(4, length(ofs_userspace_port:get_queue_stats())),
    ?assertEqual(0, length(ofs_userspace_port:get_queue_stats(BadPort))),
    ?assertEqual(4, length(ofs_userspace_port:get_queue_stats(GoodPort))),
    ?assertEqual(undefined, ofs_userspace_port:get_queue_stats(GoodPort,
                                                               BadQueue)),
    ?assert(is_record(ofs_userspace_port:get_queue_stats(GoodPort, GoodQueue1),
                      ofp_queue_stats)),

    ?assertEqual(bad_port, ofs_userspace_port:detach_queue(BadPort,
                                                           GoodQueue1)),
    ?assertEqual(ok, ofs_userspace_port:detach_queue(GoodPort,
                                                     BadQueue)),
    ?assertEqual(4, length(ofs_userspace_port:list_queues(GoodPort))),
    ?assertEqual(ok, ofs_userspace_port:detach_queue(GoodPort,
                                                     GoodQueue1)),
    ?assertEqual(3, length(ofs_userspace_port:list_queues(GoodPort))),

    ?assertEqual(bad_port, ofs_userspace_port:send(BadPort, Pkt)),
    ?assertEqual(ok, ofs_userspace_port:send(GoodPort, Pkt)),
    ?assertEqual(bad_queue, ofs_userspace_port:send(GoodPort, BadQueue, Pkt)),
    ?assertEqual(ok, ofs_userspace_port:send(GoodPort, GoodQueue2, Pkt)),

    %% %% avoid race condition:
    %% %% wait for packets to be routed before removing the port
    %% timer:sleep(20),

    ?assertEqual(bad_port, ofs_userspace_port:remove(BadPort)),
    ?assertEqual(ok, ofs_userspace_port:remove(GoodPort)),
    ?assertEqual(0, length(ofs_userspace_port:list_ports())),

    meck:unload(pkt),
    meck:unload(ofs_userspace_port_procket),
    meck:unload(epcap),
    meck:unload(bpf),
    meck:unload(packet),

    teardown().

group_mod_test() ->
    setup(),
    State = [],

    %% add to group
    GroupAdd = #ofp_group_mod{command = add, group_id = 1, buckets = []},
    ?assertEqual({ok, State},
                 ofs_userspace:ofp_group_mod(State, GroupAdd)),
    GroupExists = {error,{ofp_error,group_mod_failed,group_exists,<<>>},[]},
    ?assertEqual(GroupExists,
                 ofs_userspace:ofp_group_mod(State, GroupAdd)),

    %% modify group
    GroupMod = #ofp_group_mod{command = modify, group_id = 1, buckets = some},
    ?assertEqual({ok, State},
                 ofs_userspace:ofp_group_mod(State, GroupMod)),
    ?assertEqual(some, ets:lookup_element(group_table, 1, #group.buckets)),

    GroupModBad = #ofp_group_mod{command = modify, group_id = 99, buckets = []},
    GroupModFailed = {error,{ofp_error,group_mod_failed,unknown_group,<<>>},[]},
    ?assertEqual(GroupModFailed,
                 ofs_userspace:ofp_group_mod(State, GroupModBad)),

    %% delete from group
    AddGroup2 = #ofp_group_mod{command = add, group_id = 2, buckets = []},
    AddGroup3 = #ofp_group_mod{command = add, group_id = 3, buckets = []},
    AddGroup4 = #ofp_group_mod{command = add, group_id = 4, buckets = []},
    ofs_userspace:ofp_group_mod(State, AddGroup2),
    ofs_userspace:ofp_group_mod(State, AddGroup3),
    ofs_userspace:ofp_group_mod(State, AddGroup4),

    DeleteGroup2 = #ofp_group_mod{command = delete, group_id = 2},
    ?assertEqual({ok, State},
                 ofs_userspace:ofp_group_mod(State, DeleteGroup2)),
    ?assertEqual([], ets:lookup(group_table, 2)),

    DeleteAll = #ofp_group_mod{command = delete, group_id = all},
    ?assertEqual({ok, State},
                 ofs_userspace:ofp_group_mod(State, DeleteAll)),
    ?assertEqual([], ets:tab2list(group_table)),
    teardown().
