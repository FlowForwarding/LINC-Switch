%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2012, Erlang Solutions Ltd.
%%% @doc OpenFlow 1.2 Controller.
%%% @end
%%%-----------------------------------------------------------------------------
-module(of_controller).

-compile([{parse_transform, lager_transform}]).

%% To start the controller issue following commands:
%%
%% {ok, Pid} = of_controller:start(6633).
%% {ok, [Conn]} = of_controller:get_connections(Pid).
%% of_controller:send(Pid, Conn, of_controller:echo_request()).
%% of_controller:send(Pid, Conn, of_controller:table_config(controller)).

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
         barrier_request/0,
         features_request/0,
         remove_all_flows/0,
         table_config/1]).

-include_lib("of_protocol/include/of_protocol.hrl").
-include_lib("pkt/include/pkt.hrl").

-record(cstate, {
          parent :: pid(),
          socket,
          parser,
          fwd_table = [] :: [{binary(), integer()}]
         }).

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
                             handle(#cstate{parent = Parent,
                                            socket = Socket,
                                            parser = Parser})
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
            %% Setting switch to route all frames to controller
            Msg = of_controller:table_config(controller),
            {ok, EncodedMessage} = of_protocol:encode(Msg),
            ok = gen_tcp:send(Socket, EncodedMessage),

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

handle(#cstate{parent = Parent, socket = Socket,
               parser = Parser, fwd_table = FwdTable} = State) ->
    receive
        {tcp, Socket, Data} ->
            {ok, NewParser} = parse_tcp(Socket, Parser, Data),
            handle(State#cstate{parser = NewParser});
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
                                      %% in_port = InPort,
                                      match = Match,
                                      data = Data}} = Message} ->
            lager:debug("Received packet_in from ~p: ~p", [Socket, Message]),

            %% ActionOutput = #ofp_action_output{port = InPort + 1,
            %%                                   max_len = no_buffer},
            %% PacketOut = Message#ofp_message{
            %%               body = #ofp_packet_out{buffer_id = BufferId,
            %%                                      actions = [ActionOutput],
            %%                                      data = Data}},

            try
                [EthHeader | _] = pkt:decapsulate(Data),
                EthSrc = EthHeader#ether.shost,
                EthDst = EthHeader#ether.dhost,
                #ofp_field{value = <<InPort:32>>} = lists:keyfind(in_port, #ofp_field.field,
                                                                  Match#ofp_match.oxm_fields),
                NewMatch = #ofp_match{oxm_fields = [#ofp_field{field = eth_dst,
                                                               value = EthSrc}]},
                ApplyActions = #ofp_instruction_apply_actions{
                  actions = [#ofp_action_output{port = controller}]},
                ActionOutput = #ofp_instruction_write_actions{
                  actions = [#ofp_action_output{port = InPort}]},
                case lists:keyfind(EthSrc, 1, FwdTable) of
                    {EthSrc, InPort} ->
                        %% lager:info("Already exists: ~p | ~p", [EthSrc, InPort]),
                        NewFwdTable = FwdTable,
                        ok;
                    {EthSrc, OtherPort} ->
                        FlowMod = message(#ofp_flow_mod{table_id = 0,
                                                        command = modify_strict,
                                                        match = NewMatch,
                                                        instructions = [ApplyActions,
                                                                        ActionOutput]}),
                        lager:info("Modifying existing entry: ~p | ~p  ->  ~p | ~p", [EthSrc, OtherPort,
                                                                                      EthSrc, InPort]),
                        {ok, EncodedFlowMod} = of_protocol:encode(FlowMod),
                        NewFwdTable = lists:keyreplace(EthSrc, 1, FwdTable, {EthSrc, InPort}),
                        gen_tcp:send(Socket, EncodedFlowMod);
                    false ->
                        FlowMod = message(#ofp_flow_mod{table_id = 0,
                                                        command = add,
                                                        match = NewMatch,
                                                        instructions = [ApplyActions,
                                                                        ActionOutput]}),
                        MAC = binary_to_hex(EthSrc),
                        lager:info("Adding new entry: ~1w | ~18s | ~p",
                                   [InPort, MAC, EthSrc]),
                        {ok, EncodedFlowMod} = of_protocol:encode(FlowMod),
                        NewFwdTable = [{EthSrc, InPort} | FwdTable],
                        gen_tcp:send(Socket, EncodedFlowMod)
                end,
                case lists:keymember(EthDst, 1, FwdTable) of
                    true ->
                        ok;
                    false ->
                        OutputToAll = #ofp_action_output{port = all},
                        PacketOut = Message#ofp_message{
                                      body = #ofp_packet_out{buffer_id = BufferId,
                                                             in_port = InPort,
                                                             actions = [OutputToAll],
                                                             data = Data}},
                        %% lager:info("Send packet to all ports"),
                        {ok, EncodedPacketOut} = of_protocol:encode(PacketOut),
                        gen_tcp:send(Socket, EncodedPacketOut)
                end,
                %% lager:info("Forwarding table: ~p", [NewFwdTable]),
                handle(State#cstate{fwd_table = NewFwdTable})
            catch
                E1:E2 ->
                    lager:error("Pkt decapsulate error: ~p:~p", [E1, E2]),
                    lager:error("Probably received malformed frame", []),
                    lager:error("With data: ~p", [Data]),
                    handle(State)
            end;
        {msg, Socket, Message} ->
            lager:debug("Received message from ~p: ~p", [Socket, Message]),
            Parent ! {message, Message},
            handle(State)
    end.

binary_to_hex(Bin) ->
    binary_to_hex(Bin, "").

binary_to_hex(<<>>, Result) ->
    Result;
binary_to_hex(<<B:8, Rest/bits>>, Result) ->
    Hex = erlang:integer_to_list(B, 16),
    NewResult = Result ++ ":" ++ Hex,
    binary_to_hex(Rest, NewResult).

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

table_config(Config) ->
    message(#ofp_table_mod{config = Config}).

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
    lager:debug("Received TCP data from ~p: ~p", [Socket, Data]),
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
