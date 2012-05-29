%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2012, Erlang Solutions Ltd.
%%% @doc EUnit system tests for OpenFlow Switch application.
%%% @end
%%%-----------------------------------------------------------------------------
-module(ofs_tests).
-author("Erlang Solutions Ltd. <openflow@erlang-solutions.com>").


-include_lib("eunit/include/eunit.hrl").
-include_lib("of_protocol/include/of_protocol.hrl").

%%%-----------------------------------------------------------------------------
%%% EUnit tests
%%%-----------------------------------------------------------------------------

request_reply_test_() ->
    {setup,
     fun setup/0,
     fun teardown/1,
     fun (Config) ->
             [
              request_reply(Config, echo),
              request_reply(Config, desc_stats),
              request_reply(Config, flow_stats),
              request_reply(Config, aggregate_stats),
              request_reply(Config, table_stats),
              request_reply(Config, port_stats),
              request_reply(Config, queue_stats),
              request_reply(Config, group_stats),
              request_reply(Config, group_desc_stats),
              request_reply(Config, group_features_stats)
             ]
     end}.

request_reply(Config, MessageType) ->
    {controller, ControllerPid} = lists:keyfind(controller, 1, Config),
    {connection, ConnectionId} = lists:keyfind(connection, 1, Config),

    %% Get next xid
    Xid = case get(xid) of
               undefined ->
                   100;
               Value ->
                   Value
    end,
    put(xid, Xid + 1),

    Request = #ofp_message{version = 3,
                           xid = Xid,
                           body = get_request(MessageType)},

    case of_controller:send(ControllerPid, ConnectionId, Request, 5000) of
        {reply, #ofp_message{version = 3, xid = ReplyXid, body = ReplyBody}} ->
            RecordTag = element(1, get_reply(MessageType)),
            ?_assert(is_record(ReplyBody, RecordTag)),
            ?_assertEqual(Xid, ReplyXid);
        Other ->
            throw({bad_reply, Other})
    end.

%%%-----------------------------------------------------------------------------
%%% Setup/teardown fixtures
%%%-----------------------------------------------------------------------------

setup() ->
    code:add_path("../../of_protocol/ebin"),

    %% Suppress lager output
    lager:start(),
    lager:set_loglevel(lager_console_backend, notice),

    %% Start the controller
    {ok, ControllerPid} = of_controller:start(6634),

    %% Start the switch
    application:load(of_switch),
    application:set_env(of_switch, controllers, [{"localhost", 6634}]),
    application:set_env(of_switch, ports, []),
    application:start(of_switch),

    %% Wait for connection
    {ok, ConnectionId} = wait_for_connection(ControllerPid, 100),

    timer:sleep(500),

    [{controller, ControllerPid}, {connection, ConnectionId}].

teardown(Config) ->
    %% Stop the controller
    {controller, ControllerPid} = lists:keyfind(controller, 1, Config),
    of_controller:stop(ControllerPid),

    %% Stop the switch
    application:stop(of_switch).

%%%-----------------------------------------------------------------------------
%%% Helper functions
%%%-----------------------------------------------------------------------------

wait_for_connection(_Ctrl, 0) ->
    {error, timeout};
wait_for_connection(Ctrl, N) ->
    {ok, Connections} = of_controller:get_connections(Ctrl),
    case Connections of
        [] ->
            timer:sleep(100),
            wait_for_connection(Ctrl, N-1);
        [Conn] ->
            {ok, Conn};
        [Conn | _] = TooMany ->
            io:format("Too many connections: ~p~n", [TooMany]),
            {ok, Conn}
    end.

get_request(echo) ->
    #ofp_echo_request{};
get_request(desc_stats) ->
    #ofp_desc_stats_request{};
get_request(flow_stats) ->
    #ofp_flow_stats_request{};
get_request(aggregate_stats) ->
    #ofp_aggregate_stats_request{};
get_request(table_stats) ->
    #ofp_table_stats_request{};
get_request(port_stats) ->
    #ofp_port_stats_request{port_no = 1};
get_request(queue_stats) ->
    #ofp_queue_stats_request{};
get_request(group_stats) ->
    #ofp_group_stats_request{};
get_request(group_desc_stats) ->
    #ofp_group_desc_stats_request{};
get_request(group_features_stats) ->
    #ofp_group_features_stats_request{}.

get_reply(echo) ->
    #ofp_echo_reply{};
get_reply(desc_stats) ->
    #ofp_desc_stats_reply{};
get_reply(flow_stats) ->
    #ofp_flow_stats_reply{};
get_reply(aggregate_stats) ->
    #ofp_aggregate_stats_reply{};
get_reply(table_stats) ->
    #ofp_table_stats_reply{};
get_reply(port_stats) ->
    #ofp_port_stats_reply{};
get_reply(queue_stats) ->
    #ofp_queue_stats_reply{};
get_reply(group_stats) ->
    #ofp_group_stats_reply{};
get_reply(group_desc_stats) ->
    #ofp_group_desc_stats_reply{};
get_reply(group_features_stats) ->
    #ofp_group_features_stats_reply{}.
