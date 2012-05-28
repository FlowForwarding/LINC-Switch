%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2012, Erlang Solutions Ltd.
%%% @doc OpenFlow 1.2 Controller mock.
%%% @end
%%%-----------------------------------------------------------------------------
-module(of_controller).
-author("Erlang Solutions Ltd. <openflow@erlang-solutions.com>").


-compile([{parse_transform, lager_transform}]).

%% API
-export([start/1,
         stop/1,
         get_connections/1,
         send/3,
         send/4,
         barrier/2]).

%% Message generators
-export([hello/0,
         echo_request/0,
         echo_request/1,
         barrier_request/0]).

-include_lib("of_protocol/include/of_protocol.hrl").

%%%-----------------------------------------------------------------------------
%%% API functions
%%%-----------------------------------------------------------------------------

start(Port) ->
    lager:start(),
    {ok, spawn(fun() ->
                       init(Port)
               end)}.

stop(Pid) ->
    Pid ! stop.

get_connections(Pid) ->
    Pid ! {get_connections, Ref = make_ref(), self()},
    receive
        {connections, Ref, Connections} ->
            {ok, Connections}
    after 1000 ->
            {error, timeout}
    end.

send(Pid, To, Message) ->
    cast(Pid, To, Message).

send(Pid, To, Message, Timeout) ->
    call(Pid, To, Message, Timeout).

barrier(Pid, To) ->
    send(Pid, To, barrier_request(), 1000).

%%%-----------------------------------------------------------------------------
%%% Controller logic
%%%-----------------------------------------------------------------------------

init(Port) ->
    Pid = self(),
    spawn_link(fun() ->
                       Opts = [binary, {packet, raw},
                               {active, once}, {reuseaddr, true}],
                       {ok, LSocket} = gen_tcp:listen(Port, Opts),
                       accept(Pid, LSocket)
               end),
    loop([]).

accept(Parent, LSocket) ->
    {ok, Socket} = gen_tcp:accept(LSocket),
    Pid = spawn_link(fun() ->
                             {ok, EncodedHello} = of_protocol:encode(hello()),
                             gen_tcp:send(Socket, EncodedHello),
                             {ok, Parser} = ofp_parser:new(),
                             inet:setopts(Socket, [{active, once}]),
                             handle(Parent, Socket, Parser)
                     end),
    ok = gen_tcp:controlling_process(Socket, Pid),
    Parent ! {accept, Socket, Pid},
    accept(Parent, LSocket).

loop(Connections) ->
    receive
        {accept, Socket, Pid} ->
            {ok, {Address, Port}} = inet:peername(Socket),
            lager:info("Accepted connection from ~p {~p,~p}",
                       [Socket, Address, Port]),
            loop([{{Address, Port}, Socket, Pid} | Connections]);
        {cast, Message, AddressPort} ->
            NewConnections = filter_connections(Connections),
            do_send(NewConnections, AddressPort, Message),
            loop(NewConnections);
        {call, #ofp_message{xid = Xid} = Message,
         AddressPort, Ref, ReplyPid, Timeout} ->
            NewConnections = filter_connections(Connections),
            do_send(NewConnections, AddressPort, Message),
            receive
                {message, #ofp_message{xid = Xid} = Reply} ->
                    ReplyPid ! {reply, Ref, {reply, Reply}}
            after Timeout ->
                    ReplyPid ! {reply, Ref, {error, timeout}}
            end,
            loop(NewConnections);
        {get_connections, Ref, Pid} ->
            Pid ! {connections, Ref, [AP || {AP,_,_} <- Connections]},
            loop(Connections);
        stop ->
            ok
    end.

handle(Parent, Socket, Parser) ->
    receive
        {tcp, Socket, Data} ->
            {ok, NewParser} = parse_tcp(Socket, Parser, Data),
            handle(Parent, Socket, NewParser);
        {tcp_closed, Socket} ->
            lager:info("Socket ~p closed", [Socket]);
        {tcp_error, Socket, Reason} ->
            lager:error("Error on socket ~p: ~p", [Socket, Reason]);
        {msg, Socket, #ofp_message{
                body = #ofp_error{type = hello_failed,
                                  code = incompatible}} = Message} ->
            lager:error("Received hello_failed from ~p: ~p",
                        [Socket, Message]),
            gen_tcp:close(Socket);
        {msg, Socket, #ofp_message{
                body = #ofp_packet_in{buffer_id = BufferId,
                                      in_port = InPort,
                                      data = Data}} = Message} ->
            lager:info("Received packet_in from ~p: ~p", [Socket, Message]),
            ActionOutput = #ofp_action_output{port = InPort + 1,
                                               max_len = no_buffer},
            PacketOut = Message#ofp_message{
                          body = #ofp_packet_out{buffer_id = BufferId,
                                                 actions = [ActionOutput],
                                                 data = Data}},
            {ok, EncodedPacketOut} = of_protocol:encode(PacketOut),
            gen_tcp:send(Socket, EncodedPacketOut),
            handle(Parent, Socket, Parser);
        {msg, Socket, Message} ->
            lager:info("Received message from ~p: ~p", [Socket, Message]),
            Parent ! {message, Message},
            handle(Parent, Socket, Parser)
    end.

%%%-----------------------------------------------------------------------------
%%% Message generators
%%%-----------------------------------------------------------------------------

hello() ->
    message(#ofp_hello{}).

features_request() ->
    message(#ofp_features_request{}).

echo_request() ->
    echo_request(<<>>).
echo_request(Data) ->
    message(#ofp_echo_request{data = Data}).

barrier_request() ->
    message(#ofp_barrier_request{}).

remove_all_flows() ->
    message(#ofp_flow_mod{command = delete}).

%%% Helpers --------------------------------------------------------------------

message(Body) ->
    #ofp_message{version = 3,
                 xid = get_xid(),
                 body = Body}.

get_xid() ->
    random:uniform(1 bsl 32 - 1).

%%%-----------------------------------------------------------------------------
%%% Helper functions
%%%-----------------------------------------------------------------------------

parse_tcp(Socket, Parser, Data) ->
    lager:info("Received TCP data from ~p: ~p", [Socket, Data]),
    inet:setopts(Socket, [{active, once}]),
    {ok, NewParser, Messages} = ofp_parser:parse(Parser, Data),
    lists:foreach(fun(Message) ->
                          self() ! {msg, Socket, Message}
                  end, Messages),
    {ok, NewParser}.

filter_connections(Connections) ->
    [Conn || {_, _, Pid} = Conn <- Connections, is_process_alive(Pid)].

cast(Pid, To, Message) ->
    case is_process_alive(Pid) of
        true ->
            lager:info("Sending ~p", [Message]),
            Pid ! {cast, Message, To};
        false ->
            {error, controller_dead}
    end.

call(Pid, To, Message, Timeout) ->
    case is_process_alive(Pid) of
        true ->
            lager:info("Sending ~p", [Message]),
            Pid ! {call, Message, To, Ref = make_ref(), self(), Timeout},
            lager:info("Waiting for reply"),
            receive
                {reply, Ref, Reply} ->
                    Reply
            end;
        false ->
            {error, controller_dead}
    end.

do_send(Connections, {Address, Port}, Message) ->
    case lists:keyfind({Address, Port}, 1, Connections) of
        false ->
            lager:error("Sending message failed");
        {{Address, Port}, Socket, _} ->
            {ok, EncodedMessage} = of_protocol:encode(Message),
            ok = gen_tcp:send(Socket, EncodedMessage)
    end.
