%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2012, Erlang Solutions Ltd.
%%% @doc OpenFlow Channel module.
%%% @end
%%%-----------------------------------------------------------------------------
-module(ofs_logic).

-behaviour(gen_server).

%% API
-export([start_link/2]).
-export([register_receiver/2, unregister_receiver/1, message/2]).
-export([get_connection/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-include("of_switch.hrl").
-include_lib("of_protocol/include/of_protocol.hrl").

-record(state, {
          connections = [] :: [#connection{}],
          generation_id :: integer(),
          backend_mod :: atom(),
          backend_state :: term()
         }).

%%%-----------------------------------------------------------------------------
%%% API functions
%%%-----------------------------------------------------------------------------

%% @doc Start the OF Channel gen_server.
-spec start_link(atom(), term()) -> {ok, pid()} | {error, any()}.
start_link(BackendMod, BackendOpts) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE,
                          [BackendMod, BackendOpts], []).

%% @doc Register receiver.
-spec register_receiver(pid(), port()) -> any().
register_receiver(Pid, Socket) ->
    gen_server:cast(?MODULE, {register, Pid, Socket}).

%% @doc Unregister receiver.
-spec unregister_receiver(pid()) -> any().
unregister_receiver(Pid) ->
    gen_server:cast(?MODULE, {unregister, Pid}).

%% @doc Deliver message to the switch logic.
-spec message(ofp_message(), pid()) -> any().
message(Message, From) ->
    gen_server:cast(?MODULE, {message, From, Message}).

%% @doc Get connection information.
-spec get_connection(pid()) -> any().
get_connection(Pid) ->
    gen_server:call(?MODULE, {get_connection, Pid}).

%%%-----------------------------------------------------------------------------
%%% gen_server callbacks
%%%-----------------------------------------------------------------------------

init([BackendMod, BackendOpts]) ->
    {ok, BackendState} = BackendMod:start(BackendOpts),
    {ok, #state{backend_mod = BackendMod,
                backend_state = BackendState}}.

handle_call({get_connection, Pid}, _From,
            #state{connections = Connections} = State) ->
    Connection = lists:keyfind(Pid, #connection.pid, Connections),
    {reply, Connection, State}.

handle_cast({register, Pid, Socket},
            #state{connections = Connections} = State) ->
    Connection = #connection{pid = Pid, socket = Socket},
    {noreply, State#state{connections = [Connection | Connections]}};
handle_cast({unregister, Pid}, #state{connections = Connections} = State) ->
    NewConnections = lists:keydelete(Pid, #connection.pid, Connections),
    {noreply, State#state{connections = NewConnections}};
handle_cast({message, From, Message},
            #state{connections = Connections} = State) ->
    Connection = lists:keyfind(From, #connection.pid, Connections),
    error_logger:info_msg("Received message from controller (~p): ~p~n",
                          [Connection, Message]),
    NewState = handle_message(Message, Connection, State),
    {noreply, NewState}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #state{backend_mod = BackendMod,
                          backend_state = BackendState}) ->
    BackendMod:stop(BackendState).

code_change(_OldVersion, State, _Extra) ->
    {ok, State}.

%%%-----------------------------------------------------------------------------
%%% Message handling functions
%%%-----------------------------------------------------------------------------

%% @doc Handle different kind of messages.
-spec handle_message(ofp_message(), connection(),
                     #state{}) -> #state{}.
handle_message(#hello{header = #header{version = ReceivedVersion, xid = Xid}},
               #connection{pid = Pid, socket = Socket,
                           version = undefined} = Connection,
               #state{connections = Connections} = State) ->
    %% Wait for hello and decide on version if it's undefined.
    case decide_on_version(ReceivedVersion) of
        {ok, Version} ->
            NewConnection = Connection#connection{version = Version},
            NewConnections = lists:keyreplace(Pid, #connection.pid, Connections,
                                              NewConnection),
            State#state{connections = NewConnections};
        error ->
            do_send(Socket, error_hello_failed(Xid)),
            State
    end;
handle_message(_Message, #connection{version = undefined}, State) ->
    %% If version is undefined drop all the other messages.
    State;
handle_message(#hello{}, _, State) ->
    %% Drop hello messages once version is known.
    State;
handle_message(#error_msg{type = hello_failed},
               #connection{pid = Pid}, State) ->
    %% Disconnect when hello_failed was received.
    ofs_receiver:stop(Pid),
    State;
handle_message(#echo_request{} = EchoRequest,
               #connection{socket = Socket},
               #state{backend_mod = BackendMod,
                      backend_state = BackendState} = State) ->
    case BackendMod:echo_request(BackendState, EchoRequest) of
        {ok, EchoReply, NewBackendState} ->
            do_send(Socket, EchoReply);
        {error, Reason, NewBackendState} ->
            send_error_reply(Socket, EchoRequest, Reason)
    end,
    State#state{backend_state = NewBackendState};
handle_message(#flow_mod{header = #header{xid = Xid}},
               #connection{socket = Socket, role = slave},
               State) ->
    do_send(Socket, error_is_slave(Xid)),
    State;
handle_message(#flow_mod{buffer_id = _BufferId} = FlowMod,
               #connection{socket = Socket},
               #state{backend_mod = BackendMod,
                      backend_state = BackendState} = State) ->
%%    FIXME: uncomment
%%    case BackendMod:modify_flow(BackendState, FlowMod) of
%%        {ok, NewBackendState} ->
%%            %% XXX: look at _BufferId, emulate packet-out
%%            ok;
%%        {error, Reason, NewBackendState} ->
%%            send_error_reply(Socket, FlowMod, Reason)
%%    end,
%%    State#state{backend_state = NewBackendState};
    State;
handle_message(#role_request{header = #header{xid = Xid}, role = Role,
                             generation_id = GenerationId},
               #connection{pid = Pid, socket = Socket} = Connection,
               #state{connections = Connections,
                      generation_id = CurrentGenId} = State) ->
    case Role of
        equal ->
            NewConns = lists:keyreplace(Pid, #connection.pid, Connections,
                                        Connection#connection{role = equal}),
            do_send(Socket, #role_reply{header = #header{xid = Xid},
                                        role = Role,
                                        generation_id = GenerationId}),
            State#state{connections = NewConns};
        _ ->
            if
                (CurrentGenId /= undefined)
                andalso (GenerationId - CurrentGenId < 0) ->
                    do_send(Socket, error_stale(Xid)),
                    State;
                true ->
                    NewConn = Connection#connection{role = Role},
                    NewConns = lists:keyreplace(Pid, #connection.pid,
                                                Connections, NewConn),
                    case Role of
                        master ->
                            Fun = fun(Conn = #connection{role = R}) ->
                                          case R of
                                              master ->
                                                  Conn#connection{role = slave};
                                              _ ->
                                                  Conn
                                          end
                                  end,
                            NewConns2 = lists:map(Fun, NewConns);
                        slave ->
                            NewConns2 = NewConns
                    end,
                    NewState = State#state{connections = NewConns2,
                                           generation_id = GenerationId},
                    do_send(Socket, #role_reply{header = #header{xid = Xid},
                                                role = Role,
                                                generation_id = GenerationId}),
                    NewState
            end
    end;
handle_message(_, _, State) ->
    %% Drop everything else.
    State.

%%%-----------------------------------------------------------------------------
%%% Helper functions
%%%-----------------------------------------------------------------------------

-spec decide_on_version(integer()) -> {ok, integer()} | error.
decide_on_version(ReceivedVersion) ->
    %% TODO: Get supported version from switch configuration.
    SupportedVersions = [3],
    ProposedVersion = lists:max(SupportedVersions),
    if
        ProposedVersion > ReceivedVersion ->
            case lists:member(ReceivedVersion, SupportedVersions) of
                true ->
                    {ok, ReceivedVersion};
                false ->
                    error
            end;
        true ->
            {ok, ProposedVersion}
    end.

-spec error_hello_failed(integer()) -> error_msg().
error_hello_failed(Xid) ->
    #error_msg{header = #header{xid = Xid},
               type = hello_failed, code = incompatible}.

-spec error_is_slave(integer()) -> error_msg().
error_is_slave(Xid) ->
    #error_msg{header = #header{xid = Xid},
               type = bad_request, code = is_slave}.

-spec error_stale(integer()) -> error_msg().
error_stale(Xid) ->
    #error_msg{header = #header{xid = Xid},
               type = role_request_failed,
               code = stale}.

-spec do_send(port(), ofp_message()) -> any().
do_send(Socket, Message) ->
    {ok, EncodedMessage} = of_protocol:encode(Message),
    gen_tcp:send(Socket, EncodedMessage).

send_error_reply(_Socket, Request, Reason) ->
    error_logger:info_msg("Unsupported error reason (~p) "
                          "when handling ~p~n", [Reason, Request]).
