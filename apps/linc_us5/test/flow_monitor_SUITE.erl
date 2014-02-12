%%%=============================================================================
%%% @copyright (C) 1999-2013, Erlang Solutions Ltd
%%% @author Akos Korosmezey <akos.korosmezey@erlang-solutions.com>
%%% @doc <Suite purpose>
%%% @end
%%%=============================================================================

-module(flow_monitor_SUITE).
%% Note: This directive should only be used in test suites.
-compile(export_all).
-include_lib("common_test/include/ct.hrl").
-include_lib("of_protocol/include/of_protocol.hrl").
-include_lib("of_protocol/include/ofp_v5.hrl").

%% HI_IMPORTANCE and LOW_IMPORTANCE were introduced in R15B02
-ifndef(HI_IMPORTANCE).
-define(HI_IMPORTANCE,  75).
-endif.
-ifndef(LOW_IMPORTANCE).
-define(LOW_IMPORTANCE, 25).
-endif.

-type config() :: proplists:proplist().

%%%=============================================================================
%%% Callbacks
%%%=============================================================================

%% @doc returns list of tuples to set default properties for the suite.
-spec suite() -> Config when Config :: config().
suite() ->
    [{timetrap, {minutes, 10}}].

%% @doc returns list of tests (group or testcase) to be run for all of suite.
-spec all() -> Tests | {skip, Reason}
                   when
      Test :: {group, GroupName} | TestCase,
      Tests :: [Test],
      GroupName :: atom(),
      TestCase :: atom(),
      Reason :: term().
all() ->
    [{group, normal},
     {group, paused}
    ].

%% @doc returns list of test case group definitions.
-spec groups() -> [Group]
                      when
      Group :: {GroupName, Properties, Members},
      GroupName :: atom(),
      Properties :: [parallel | sequence | Shuffle | {RepeatType, N}],
      Members :: [Group | {group, GroupName} | TestCase],
      TestCase :: atom(),
      Shuffle :: shuffle | {shuffle, Seed},
      Seed :: {integer(), integer(), integer()},
      RepeatType :: repeat | repeat_until_all_ok | repeat_until_all_fail |
                    repeat_until_any_ok | repeat_until_any_fail,
      N :: integer() | forever.
groups() ->
    [{normal, [sequence], [
                           create_monitor,
                           modify_monitor,
                           delete_monitor,
                           initial_flows_full,
                           initial_flows_abbrev,
                           update_single,
                           update_multiple,
                           update_full,
                           two_controllers
                            ]},
     {paused, [sequence], [
                           single_updates,
                           batch_updates
                          ]}
    ].

%% @doc runs initialization before matching test suite is executed. 
%%      This function may add key/value pairs to Config.
-spec init_per_suite(Config0) ->
                            Config1 | 
                            {skip, Reason} | 
                            {skip_and_save, Reason, Config1}
                                when
      Config0 :: config(),
      Config1 :: config(),
      Reason :: term().
init_per_suite(Config) ->
    compile:file("../../../../scripts/of_controller_v5"),
    
    %% Start applications
    application:load(lager),
    application:set_env(lager, handlers, 
                        [{lager_console_backend, info},
                         {lager_file_backend, 
                          [{"log/error.log", error, 10485760, "$D0", 5},
                           {"log/console.log", info, 10485760, "$D0", 5}]}]),
    
    RLager = lager:start(),
    ct:log("Starting lager: ~p", [RLager]),

    {ok, _} = application:ensure_all_started(of_protocol),
    Config.

%% @doc runs cleanup after matching test suite is executed.
-spec end_per_suite(Config0) -> 
                           ok | {save_config, Config1}
                               when
      Config0 :: config(),
      Config1 :: config().
end_per_suite(_Config) ->
    %% Stop controllers

    %% Stop applications
    application:stop(of_protocol),
    application:stop(lager),
    ok.

%% @doc runs initialization before matching test group is executed.
-spec init_per_group(GroupName, Config0) ->
                            Config1 | {skip, Reason} | {skip_and_save, Reason, Config1}
                                when
      GroupName :: string(),
      Config0 :: config(),
      Config1 :: config(),
      Reason :: term().
init_per_group(normal, Config) ->
    application:load(linc),
    application:load(linc_us5),
    start_linc(Config, 6653, 6654);
init_per_group(paused, Config) ->
    application:load(linc),
    application:load(linc_us5),
    application:set_env(linc, monitor_buffer_limit, 3),
    
    meck:new(linc_us5_monitor, [passthrough]),
    meck:expect(linc_us5_monitor, send, 
                fun(C, U) ->
                        timer:sleep(500),
                        M = #ofp_message{version = ?VERSION,
                                         type    = ofp_multipart_reply,
                                         xid     = 0,
                                         body    = #ofp_flow_monitor_reply{flags = [],
                                                                           updates = U}},
                        ofp_client:send(C, M)
                end),
    Config2 = start_linc(Config, 6673, 6674),
    Config2.

%% @doc runs cleanup after matching test group is fully executed.
-spec end_per_group(GroupName, Config0) -> ok | {save_config, Config1}
                                               when
      GroupName :: string(),
      Config0 :: config(),
      Config1 :: config().
end_per_group(_, Config) ->
    {Ctrl1, _} = ?config(controller_1, Config),
    {Ctrl2, _} = ?config(controller_2, Config),
    of_controller_v5:stop(Ctrl1),
    of_controller_v5:stop(Ctrl2),

    application:stop(linc_us5),
    application:stop(linc),
    ok.


%% @doc runs initialization before matching test case. Should not alter or 
%%      remove any key/value pairs to the Config, but may add to it.
-spec init_per_testcase(TestCase, Config0) -> 
                               Config1 | 
                               {skip, Reason} | 
                               {skip_and_save, Reason, Config1}
                                   when
      TestCase :: atom(),
      Config0 :: config(),
      Config1 :: config(),
      Reason :: term().
init_per_testcase(_TestCase, Config) ->
    Config.

%% @doc runs cleanup for matching test case.
-spec end_per_testcase(TestCase, Config0) ->
                              ok | {save_config, Config1} | {fail, Reason}
                                  when
      TestCase :: atom(),
      Config0 :: config(),
      Config1 :: config(),
      Reason :: term().
end_per_testcase(TestCase, _Config) when TestCase =:= create_monitor;
                                         TestCase =:= modify_monitor;
                                         TestCase =:= delete_monitor ->
    ok;
end_per_testcase(_, Config) ->
    %% Remove all monitors
    clean_up(?config(controller_1, Config)),
    ok.

%%%=============================================================================
%%%   Testcases
%%%=============================================================================

%% @doc the test function.
-spec create_monitor(Config0) ->
                             ok | {skip, Reason} | {comment, Comment} |
                             {save_config, Config} | {skip_and_save, Reason, Config}
                                 when
      Config0 :: Config1 :: config(),
                 Reason :: term(),
                 Comment :: term().
create_monitor(Config) ->
    {Controller, Conn} = ?config(controller_1, Config),
    Xid = mk_xid(),
    MonitorId = 1,

    Msg = #ofp_message{version = 5,
                       type    = multipart_request,
                       xid     = Xid,
                       body    = #ofp_flow_monitor_request{
                         flags      = [], 
                         monitor_id = MonitorId,
                         out_port   = any,
                         out_group  = any,
                         monitor_flags = [],
                         table_id   = 0,
                         command    = add,
                         match      = #ofp_match{
                           fields = [#ofp_field{
                                        class    = openflow_basic,
                                        name     = ip_proto,
                                        has_mask = false,
                                        value    = <<50:8>>,
                                        mask     = undefined
                                       }
                                    ]}
                        }
                      },

    %% Send with timeout: call (instead of cast)
    {reply, Reply} = of_controller_v5:send(Controller, Conn, Msg, 1000),
    ct:log(?HI_IMPORTANCE, "Got reply ~p", [Reply]),
    #ofp_message{version = 5,
                 type = multipart_reply,
                 xid = Xid,
                 body = #ofp_flow_monitor_reply{flags = [],
                                                updates = []}} = Reply,
    [{_, MonitorId}] = linc_us5_monitor:list_monitors(0),
    {save_config, [{monitor_id, MonitorId}]}.

modify_monitor(Config) ->
    {Controller, Conn} = ?config(controller_1, Config),
    Xid = mk_xid(),
    %% Make sure this tc follows create_monitor
    {create_monitor, OldConfig} = ?config(saved_config, Config),
    MonitorId = ?config(monitor_id, OldConfig),
    [{_, MonitorId}] = linc_us5_monitor:list_monitors(0),

    Mod = #ofp_message{version = 5,
                       type    = multipart_request,
                       xid     = Xid,
                       body    = #ofp_flow_monitor_request{
                         flags      = [], 
                         monitor_id = MonitorId,
                         out_port   = any,
                         out_group  = any,
                         monitor_flags = [],
                         table_id   = 1,          %% <=== Changed from 0
                         command    = modify,
                         match      = #ofp_match{
                           fields = [#ofp_field{
                                        class    = openflow_basic,
                                        name     = ip_proto,
                                        has_mask = false,
                                        value    = <<50:8>>,
                                        mask     = undefined
                                       }
                                    ]}
                        }
                      },

    {reply, ModReply} = of_controller_v5:send(Controller, Conn, Mod, 1000),
    ct:log(?HI_IMPORTANCE, "Got reply ~p", [ModReply]),
    #ofp_message{version = 5,
                 type = multipart_reply,
                 xid = Xid,
                 body = #ofp_flow_monitor_reply{flags = [],
                                                updates = []}} = ModReply,

    %% Check if monitor has changed
    Add = of_controller_v5:flow_add([{table_id, 1},
                                     {idle_timeout, 10000},
                                     {hard_timeout, 100000},
                                     {priority, 7},
                                     {cookie, <<712:64>>},
                                     {flags, [send_flow_rem]}], %% Options
                                    [],   %% Matches
                                    [{write_actions, 
                                      [{output, controller, no_buffer}]}]),
    {cast, _, _} = of_controller_v5:send(Controller, Conn, Add), %% No reply
    ct:log("Added flow entry"),

    %% FIXME: anything changed?

    %% Still one entry in table
    [{_, MonitorId}] = linc_us5_monitor:list_monitors(0),
    {save_config, [{monitor_id, MonitorId}]}.

delete_monitor(Config) ->
    {Controller, Conn} = ?config(controller_1, Config),
    
    %% Still one monitor created by create_monitor
    {modify_monitor, [{_, MonitorId}]} = ?config(saved_config, Config),
    delete_monitor(Controller, Conn, MonitorId),
            
    %% No monitor remained
    [] = linc_us5_monitor:list_monitors(0),
    ok.
      
initial_flows_full(Config) ->
    {Controller, Conn} = ?config(controller_1, Config),
    Xid = mk_xid(),
    
    %% Add a flow
    Add = of_controller_v5:flow_add([{table_id, 1},
                                     {idle_timeout, 10000},
                                     {hard_timeout, 100000},
                                     {priority, 7},
                                     {cookie, <<712:64>>},
                                     {flags, [send_flow_rem]}], %% Options
                                    [],   %% Matches
                                    [{write_actions, 
                                      [{output, controller, no_buffer}]}]),
    {cast, _, _} = of_controller_v5:send(Controller, Conn, Add), %% No reply
    ct:log("Added flow entry"),
    
    Mon = #ofp_message{version = 5,
                       type    = multipart_request,
                       xid     = Xid,
                       body    = #ofp_flow_monitor_request{
                         flags      = [], 
                         monitor_id = 2,
                         out_port   = any,
                         out_group  = any,
                         monitor_flags = [initial, add, removed, modify, 
                                          instructions, no_abbrev, only_own],
                         table_id   = 1,
                         command    = add,
                         match      = #ofp_match{fields = []}
                        }
                      },
    
    %% Send with timeout: call (instead of cast)
    {reply, MonReply} = of_controller_v5:send(Controller, Conn, Mon, 1000),
    ct:log(?HI_IMPORTANCE, "Got reply ~p", [MonReply]),
    [Update] = get_updates_of_reply(MonReply),
    
    initial      = Update#ofp_flow_update_full.event,
    1            = Update#ofp_flow_update_full.table_id,
    idle_timeout = Update#ofp_flow_update_full.reason,
    true         = Update#ofp_flow_update_full.idle_timeout > 0,
    true         = Update#ofp_flow_update_full.hard_timeout > 0,
    7            = Update#ofp_flow_update_full.priority,
    <<712:64>>   = Update#ofp_flow_update_full.cookie,
    #ofp_match{fields = []} = Update#ofp_flow_update_full.match,
    [{ofp_instruction_write_actions,4,
      [{ofp_action_output,16,controller,
        no_buffer}]}] = Update#ofp_flow_update_full.instructions,
    ok.

initial_flows_abbrev(Config) ->
    {Controller, Conn} = ?config(controller_1, Config),
    
    %% Add a flow
    Add = of_controller_v5:flow_add([{table_id, 1},
                                     {idle_timeout, 10000},
                                     {hard_timeout, 100000},
                                     {priority, 7},
                                     {cookie, <<712:64>>},
                                     {flags, [send_flow_rem]}], %% Options
                                    [],   %% Matches
                                    [{write_actions, 
                                      [{output, controller, no_buffer}]}]),
    {cast, _, _} = of_controller_v5:send(Controller, Conn, Add), %% No reply
    ct:log("Added flow entry ~p", [Add]),
    
    Mon = #ofp_message{version = 5,
                       type    = multipart_request,
                       xid     = 765,
                       body    = #ofp_flow_monitor_request{
                         flags      = [], 
                         monitor_id = 3,
                         out_port   = any,
                         out_group  = any,
                         monitor_flags = [initial, add, removed, modify, 
                                          instructions, only_own],
                         table_id   = 1,
                         command    = add,
                         match      = #ofp_match{fields = []}
                        }
                      },
    
    %% Send with timeout: call (instead of cast)
    {reply, MonReply} = of_controller_v5:send(Controller, Conn, Mon, 1000),
    ct:log(?HI_IMPORTANCE, "Got reply ~p", [MonReply]),
    [Update] = get_updates_of_reply(MonReply),
    #ofp_flow_update_abbrev{xid = 0} = Update,
    ok.

update_single(Config) ->
    {Controller, Conn} = ?config(controller_1, Config),
    Xid = mk_xid(),
    
    Mon = #ofp_message{version = 5,
                       type    = multipart_request,
                       xid     = Xid,
                       body    = #ofp_flow_monitor_request{
                         flags      = [], 
                         monitor_id = 2,
                         out_port   = any,
                         out_group  = any,
                         monitor_flags = [add, removed],
                         table_id   = 1,
                         command    = add,
                         match      = #ofp_match{fields = []}
                        }
                      },
    
    %% Send with timeout: call (instead of cast)
    {reply, MonReply} = of_controller_v5:send(Controller, Conn, Mon, 1000),
    ct:log(?HI_IMPORTANCE, "Got reply ~p", [MonReply]),
    [] = get_updates_of_reply(MonReply),
    
    %% Add a flow: flow update must be received
    Add = of_controller_v5:flow_add([{table_id, 1},
                                     {idle_timeout, 10000},
                                     {hard_timeout, 100000},
                                     {priority, 7},
                                     {cookie, <<712:64>>},
                                     {flags, [send_flow_rem]}], %% Options
                                    [],   %% Matches
                                    [{write_actions, 
                                      [{output, controller, no_buffer}]}]),
    AddXid = Add#ofp_message.xid,
    %% Treat flow update as response to the flowe_mod
    {update, AddUpdate} = of_controller_v5:send(Controller, Conn, Add, 1000),
    ct:log("Added flow (xid = ~p), got update ~p", 
           [AddXid, AddUpdate]),
    [AddContent] = get_updates_of_reply(AddUpdate),
    AddXid = AddContent#ofp_flow_update_abbrev.xid,
    
    %% Modify flow: no update shall be sent (no modify flag in monitor)
    ModBody = (Add#ofp_message.body)#ofp_flow_mod{command = modify},
    Mod = Add#ofp_message{xid = mk_xid(), body = ModBody},
    %% Submit mod: shall time out as no update expected
    ct:log("Modifying flow: no flow update expected"),
    {error, timeout} = of_controller_v5:send(Controller, Conn, Mod, 1000),

    %% Remove flow: shall produce update
    RemBody = (Add#ofp_message.body)#ofp_flow_mod{command = delete},
    RemXid = mk_xid(),
    Rem = Add#ofp_message{xid = RemXid, body = RemBody},
    %% Submit mod: shall time out as no update expected. In fact, this is
    %% a (1-element) batch of updates.
    {update, RemUpdate} = of_controller_v5:send(Controller, Conn, Rem, 1000),
    ct:log(?HI_IMPORTANCE, "Deleted flowe (xid = ~p), got update ~p", 
           [RemXid, RemUpdate]),
    [RemContent] = get_updates_of_reply(RemUpdate),
    RemXid = RemContent#ofp_flow_update_abbrev.xid,

    ok.

update_multiple(Config) ->
    {Controller, Conn} = ?config(controller_1, Config),
    Xid = mk_xid(),
    
    Mon = #ofp_message{version = 5,
                       type    = multipart_request,
                       xid     = Xid,
                       body    = #ofp_flow_monitor_request{
                         flags      = [], 
                         monitor_id = 1,
                         out_port   = any,
                         out_group  = any,
                         monitor_flags = [add, removed],
                         table_id   = all,
                         command    = add,
                         match      = #ofp_match{fields = []}
                        }
                      },
    
    %% Send with timeout: call (instead of cast)
    {reply, MonReply} = of_controller_v5:send(Controller, Conn, Mon, 1000),
    ct:log(?HI_IMPORTANCE, "Got reply ~p", [MonReply]),
    [] = get_updates_of_reply(MonReply),
    
    %% Add a flow: flow update must be received
    Add1 = of_controller_v5:flow_add([{table_id, 0},
                                      {idle_timeout, 10000},
                                      {hard_timeout, 100000},
                                      {priority, 7},
                                      {cookie, <<573:64>>},
                                      {flags, []}], %% Options
                                     [],   %% Matches
                                     []),
    Add1Xid = Add1#ofp_message.xid,
    %% Treat flow update as response to the flowe_mod
    {update, Add1Update} = of_controller_v5:send(Controller, Conn, Add1, 1000),
    ct:log("Added flow (xid = ~p), got update ~p", 
           [Add1Xid, Add1Update]),
    [Add1Content] = get_updates_of_reply(Add1Update),
    Add1Xid = Add1Content#ofp_flow_update_abbrev.xid,
    
    %% Add another flow: flow update must be received
    Add2 = of_controller_v5:flow_add([{table_id, 1},
                                     {idle_timeout, 10000},
                                     {hard_timeout, 100000},
                                     {priority, 7},
                                     {cookie, <<846:64>>},
                                     {flags, []}], %% Options
                                    [],   %% Matches
                                    []),
    Add2Xid = Add2#ofp_message.xid,
    %% Treat flow update as response to the flowe_mod
    {update, Add2Update} = of_controller_v5:send(Controller, Conn, Add2, 1000),
    ct:log("Added flow (xid = ~p), got update ~p", 
           [Add2Xid, Add2Update]),
    [Add2Content] = get_updates_of_reply(Add2Update),
    Add2Xid = Add2Content#ofp_flow_update_abbrev.xid,

    %% Remove flows: shall produce two updates in one message
    RemBody = #ofp_flow_mod{table_id = all,
                            command = delete},
    RemXid = mk_xid(),
    Rem = Add1#ofp_message{xid = RemXid, body = RemBody},
    %% Submit mod: shall time out as no update expected. In fact, this is
    %% a (1-element) batch of updates.
    {update, RemUpdate} = of_controller_v5:send(Controller, Conn, Rem, 1000),
    ct:log(?HI_IMPORTANCE, "Deleted flowe (xid = ~p), got update ~p", 
           [RemXid, RemUpdate]),
    [C1, C2] = get_updates_of_reply(RemUpdate),
    RemXid = C1#ofp_flow_update_abbrev.xid,
    RemXid = C2#ofp_flow_update_abbrev.xid,

    ok.

update_full(Config) ->
    {Controller, Conn} = ?config(controller_1, Config),
    Xid = mk_xid(),
    
    Mon = #ofp_message{version = 5,
                       type    = multipart_request,
                       xid     = Xid,
                       body    = #ofp_flow_monitor_request{
                         flags      = [], 
                         monitor_id = 2,
                         out_port   = any,
                         out_group  = any,
                         monitor_flags = [add, no_abbrev],
                         table_id   = 1,
                         command    = add,
                         match      = #ofp_match{fields = []}
                        }
                      },
    
    {reply, MonReply} = of_controller_v5:send(Controller, Conn, Mon, 1000),
    ct:log(?HI_IMPORTANCE, "Got reply ~p", [MonReply]),
    [] = get_updates_of_reply(MonReply),
    
    %% Add a flow: flow update must be received
    Add = of_controller_v5:flow_add([{table_id, 1},
                                     {idle_timeout, 10000},
                                     {hard_timeout, 100000},
                                     {priority, 7},
                                     {cookie, <<712:64>>},
                                     {flags, [send_flow_rem]}], %% Options
                                    [],   %% Matches
                                    [{write_actions, 
                                      [{output, controller, no_buffer}]}]),
    AddXid = Add#ofp_message.xid,
    %% Treat flow update as response to the flowe_mod
    {update, AddUpdate} = of_controller_v5:send(Controller, Conn, Add, 1000),
    ct:log("Added flow (xid = ~p), got update ~p", 
           [AddXid, AddUpdate]),
    [C] = get_updates_of_reply(AddUpdate),
    added        = C#ofp_flow_update_full.event,
    1            = C#ofp_flow_update_full.table_id,
    idle_timeout = C#ofp_flow_update_full.reason,
    true         = C#ofp_flow_update_full.idle_timeout > 0,
    true         = C#ofp_flow_update_full.hard_timeout > 0,
    7            = C#ofp_flow_update_full.priority,
    <<712:64>>   = C#ofp_flow_update_full.cookie,
    #ofp_match{fields = []} = C#ofp_flow_update_full.match,
    [] = C#ofp_flow_update_full.instructions,
    ok.

two_controllers(Config) ->
    {Ctrl1, Conn1} = ?config(controller_1, Config),
    {Ctrl2, Conn2} = ?config(controller_2, Config),
    Xid = mk_xid(),
    
    Mon = #ofp_message{version = 5,
                       type    = multipart_request,
                       xid     = Xid,
                       body    = #ofp_flow_monitor_request{
                         flags      = [], 
                         monitor_id = 1,
                         out_port   = any,
                         out_group  = any,
                         monitor_flags = [add],
                         table_id   = 1,
                         command    = add,
                         match      = #ofp_match{fields = []}
                        }
                      },
    
    {reply, MonReply1} = of_controller_v5:send(Ctrl1, Conn1, Mon, 1000),
    ct:log("Ctrl1 added monitor with reply ~p", [MonReply1]),
    [] = get_updates_of_reply(MonReply1),

    Mon2 = Mon#ofp_message{body = Mon#ofp_message.body#ofp_flow_monitor_request{monitor_id = 2}},
    {reply, MonReply2} = of_controller_v5:send(Ctrl2, Conn2, Mon2, 1000),
    ct:log("Ctrl1 added monitor with reply ~p", [MonReply2]),
    [] = get_updates_of_reply(MonReply2),
    
    %% Add a flow: flow update must be received
    Add = of_controller_v5:flow_add([{table_id, 1},
                                     {idle_timeout, 10000},
                                     {hard_timeout, 100000},
                                     {priority, 7},
                                     {cookie, <<712:64>>},
                                     {flags, [send_flow_rem]}], %% Options
                                    [],   %% Matches
                                    []),
    AddXid = Add#ofp_message.xid,

    %% Treat flow update as response to the flowe_mod
    {update, AddUpdate1} = of_controller_v5:send(Ctrl1, Conn1, Add, 1000),
    ct:log("Added flow (xid = ~p), got update ~p", 
           [AddXid, AddUpdate1]),

    {update, AddUpdate2} = of_controller_v5:send(Ctrl2, Conn2, wait_for_message, 1000),
    ct:log("2nd controller got update ~p", [AddUpdate2]),

    %% Abbrev flow update to own controller
    [C1] = get_updates_of_reply(AddUpdate1),
    AddXid = C1#ofp_flow_update_abbrev.xid,

    %% Full update to other one
    [C2] = get_updates_of_reply(AddUpdate2),
    added        = C2#ofp_flow_update_full.event,
    1            = C2#ofp_flow_update_full.table_id,
    idle_timeout = C2#ofp_flow_update_full.reason,
    true         = C2#ofp_flow_update_full.idle_timeout > 0,
    true         = C2#ofp_flow_update_full.hard_timeout > 0,
    7            = C2#ofp_flow_update_full.priority,
    <<712:64>>   = C2#ofp_flow_update_full.cookie,
    #ofp_match{fields = []} = C2#ofp_flow_update_full.match,
    [] = C2#ofp_flow_update_full.instructions,
    ok.

single_updates(Config) ->
    {Controller, Conn} = ?config(controller_1, Config),
    Xid = mk_xid(),
    
    Mon = #ofp_message{version = 5,
                       type    = multipart_request,
                       xid     = Xid,
                       body    = #ofp_flow_monitor_request{
                         flags      = [], 
                         monitor_id = 1,
                         out_port   = any,
                         out_group  = any,
                         monitor_flags = [add, removed, modify],
                         table_id   = all,
                         command    = add,
                         match      = #ofp_match{fields = []}
                        }
                      },
    
    %% Send with timeout: call (instead of cast)
    {reply, MonReply} = of_controller_v5:send(Controller, Conn, Mon, 1000),
    ct:log(?HI_IMPORTANCE, "Added monitor, reply ~p", [MonReply]),
    [] = get_updates_of_reply(MonReply),
    
    Add0 = of_controller_v5:flow_add([{table_id, 0},
                                      {idle_timeout, 10000},
                                      {hard_timeout, 100000},
                                      {priority, 7},
                                      {cookie, <<1:64>>},
                                      {flags, []}], %% Options
                                     [],   %% Matches
                                     []),
    AddBody = Add0#ofp_message.body,

    %% Add 4 flows, do not wait for updates. 
    %% Must cause monitoring to pause.
    FlowMods = 
        %% These shall pause monitoring (buffer limit = 3 now), last add
        %% shall be withheld
        [Add0#ofp_message{xid = I,
                          body = AddBody#ofp_flow_mod{table_id = I}} ||
            I <- lists:seq(1, 5)] ++
        [
         %% Delete: shall be let through in paused mode, too 
         Add0#ofp_message{xid = 6,
                          body = AddBody#ofp_flow_mod{command = delete,
                                                      table_id = 1}},
         %% Modify: will be dropped as flow 5 created during pause
         Add0#ofp_message{xid = 7,
                          body = AddBody#ofp_flow_mod{command = modify,
                                                      table_id = 5,
                                                      priority = 5}},
         %% Delete: passed through and shall remove the last add and the previous modify
         Add0#ofp_message{xid = 8,
                          body = AddBody#ofp_flow_mod{command = delete,
                                                      table_id = 5}},
         %% Add: withheld
         Add0#ofp_message{xid = 9,
                          body = AddBody#ofp_flow_mod{table_id = 6,
                                                      priority = 4}},
         %% Modify: withheld but kept as modifies a pre-exiting flow
         Add0#ofp_message{xid = 10,
                          body = AddBody#ofp_flow_mod{command = modify,
                                                      table_id = 3,
                                                      priority = 6}}
        ],
    %% Submit all flow_mods, do not wait for updates. 
    %% Must cause monitoring to pause (buffer limit == 3).
    [{cast, _, _} = of_controller_v5:send(Controller, Conn, F) ||
        F <- FlowMods],

    [1, 2, 3, 4, paused, 6, 8, resumed, 9, 10] = 
        [begin
             {update, M} = of_controller_v5:send(Controller, Conn, wait_for_message, 10000),
             Us = get_updates_of_reply(M),
             ct:log("Flow update received: ~p", [Us]),
             case Us of
                 [#ofp_flow_update_abbrev{xid = X}] -> X;
                 #ofp_flow_update_paused{event = E} -> E
             end
         end || _I <- lists:seq(1, 10)],

    ok.

batch_updates(Config) ->
    {Controller, Conn} = ?config(controller_1, Config),
    Xid = mk_xid(),
    
    Mon = #ofp_message{version = 5,
                       type    = multipart_request,
                       xid     = Xid,
                       body    = #ofp_flow_monitor_request{
                         flags      = [], 
                         monitor_id = 1,
                         out_port   = any,
                         out_group  = any,
                         monitor_flags = [add, removed, modify, no_abbrev],
                         table_id   = all,
                         command    = add,
                         match      = #ofp_match{fields = []}
                        }
                      },
    
    %% Send with timeout: call (instead of cast)
    {reply, MonReply} = of_controller_v5:send(Controller, Conn, Mon, 1000),
    ct:log(?HI_IMPORTANCE, "Added monitor, reply ~p", [MonReply]),
    [] = get_updates_of_reply(MonReply),
    
    Add0 = of_controller_v5:flow_add([{table_id, 0},
                                      {idle_timeout, 10000},
                                      {hard_timeout, 100000},
                                      {priority, 7},
                                      {cookie, <<1:64>>},
                                      {flags, []}], %% Options
                                     [],   %% Matches
                                     []),
    AddBody = Add0#ofp_message.body,

    %% Add 4 flows, do not wait for updates. 
    %% Must cause monitoring to pause.
    FlowMods = 
        %% These shall pause monitoring (buffer limit = 3 now), last add
        %% shall be withheld
        [Add0#ofp_message{xid = I,
                          body = AddBody#ofp_flow_mod{
                                   match = #ofp_match{fields = [match_in_port(I)]}}} ||
                             I <- lists:seq(1, 5)] ++
        [
         %% Modify: will be dropped as flow 5 created during pause
         Add0#ofp_message{xid = 6,
                          body = AddBody#ofp_flow_mod{command = modify,
                                                      cookie = <<1:64>>,
                                                      priority = 5}}
        ],
    %% Submit all flow_mods, do not wait for updates. 
    %% Must cause monitoring to pause (buffer limit == 3).
    [{cast, _, _} = of_controller_v5:send(Controller, Conn, F) ||
        F <- FlowMods],
    
    [{added, [1]}, {added, [2]}, {added, [3]}, {added, [4]}, paused, resumed, 
     {added, [5]}, {modified, [1, 2, 3, 4]}] = 
        [begin
             {update, M} = of_controller_v5:send(Controller, Conn, wait_for_message, 10000),
             Us = get_updates_of_reply(M),
             ct:log("Flow update received: ~p", [Us]),
             case Us of
                 [#ofp_flow_update_full{event = E} | _] ->
                     {E, [get_in_port(Match) || 
                             #ofp_flow_update_full{match = Match} <- Us]};
                 #ofp_flow_update_paused{event = E} -> E
             end
         end || _I <- lists:seq(1, 8)],

    ok.

%%%=============================================================================
%%% Utility functions
%%%=============================================================================

start_linc(Config, Port1, Port2) ->
    application:set_env(linc, of_config, disabled),
    application:set_env(linc, capable_switch_ports, 
                        [{port, 1, [{port_rate, {100, kbps}}, {interface, "lo"}]},
                         {port, 2, [{port_rate, {100, kbps}}, {interface, "lo"}]}]),
    application:set_env(linc, capable_switch_queues, []),
    application:set_env(linc, logical_switches,
                        [{switch, 0, 
                          [{backend, linc_us5},
                           {controllers,
                            [{"Switch0-DefaultController", "localhost", Port1, tcp},
                             {"Switch0-SecondaryController", "localhost", Port2, tcp}
                            ]},
                           {controllers_listener, disabled},
                           {queues_status, disabled},
                           {ports, [{port, 1, {queues, []}},
                                    {port, 2, {queues, []}}
                                   ]}
                          ]}
                        ]),
    {ok, _} = application:ensure_all_started(linc), %% Requires >= R16B02,
    {ok, _} = application:ensure_all_started(linc_us5),
    ct:log("Started LINC.~nRunning applications: ~p", 
           [application:which_applications()]),
    
    %% Start up two controllers
        %% Launch controller, submit flow monitoring request
    {Ctrl1, Conn1} = start_controller(Port1),
    {Ctrl2, Conn2} = start_controller(Port2),
    timer:sleep(3000),
    [{port_1, Port1}, {controller_1, {Ctrl1, Conn1}},
     {port_2, Port2}, {controller_2, {Ctrl2, Conn2}} | Config].


start_controller(Port) ->
    {ok, Ctrl} = of_controller_v5:start_scenario(Port, idle),
    {ok, Connection} = wait_for_connection(Ctrl, 10000),
    ct:log(?LOW_IMPORTANCE, "controller ~p started on port ~p. Connection: ~p", [Ctrl, Port, Connection]),
    {Ctrl, Connection}.


wait_for_connection(_Ctrl, Timeout) when Timeout < 0 ->
    {error, failed_to_connect};
wait_for_connection(Ctrl, Timeout) ->
    case of_controller_v5:get_connections(Ctrl) of
        {ok, []} ->
            Dt = 1000,
            timer:sleep(Dt),
            wait_for_connection(Ctrl, Timeout - Dt);
        {ok, List} ->
            {ok, hd(List)}
    end.

mk_xid() ->
    random:uniform(10000).

get_updates_of_reply(#ofp_message{type    = multipart_reply,
                                  body = Body}) ->
    Body#ofp_flow_monitor_reply.updates.

match_in_port(InPort) ->
    #ofp_field{class = openflow_basic,
               has_mask = false,
               name = in_port,
               value = <<InPort:32>>}.

get_in_port(#ofp_match{fields = [InPortField]}) ->
    <<R:32>> = InPortField#ofp_field.value,
    R.

delete_monitor(Controller, Conn, MonitorId) ->
    ct:log(?LOW_IMPORTANCE, "Deleting monitor ~p", [MonitorId]),
    Xid = random:uniform(10000),
    Msg = #ofp_message{version = 5,
                       type    = multipart_request,
                       xid     = Xid,
                       body    = #ofp_flow_monitor_request{
                         flags      = [], 
                         monitor_id = MonitorId,
                         out_port   = any,
                         out_group  = any,
                         monitor_flags = [],
                         table_id   = 1,
                         command    = delete,
                         match      = #ofp_match{fields = []}
                        }
                      },

    %% Send with timeout: call (instead of cast)
    {reply, Reply} = of_controller_v5:send(Controller, Conn, Msg, 1000),
    ct:log(?HI_IMPORTANCE, "Delete: got reply ~p", [Reply]),
    #ofp_message{version = 5,
                 type = multipart_reply,
                 xid = Xid,
                 body = #ofp_flow_monitor_reply{flags = [],
                                                updates = []}} = Reply,
    ok.

%% @doc Clean up all monitors and flow tables
clean_up({Controller, Conn}) ->
    Monitors = linc_us5_monitor:list_monitors(0),
    ct:log("Deleting existing monitors: ~p", [Monitors]),
    [catch delete_monitor(Controller, Conn, MonitorId) || 
        {_, MonitorId} <- Monitors],
    
    %% Remove all flows
    Del = #ofp_message{version = 5,
                       xid = mk_xid(),
                       body = #ofp_flow_mod{table_id = all,
                                            command = delete}},
    {cast, _, _} = of_controller_v5:send(Controller, Conn, Del).
  
