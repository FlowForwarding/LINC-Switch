%%%-----------------------------------------------------------------------------
%%% Use is subject to License terms.
%%% @copyright (C) 2012 FlowForwarding.org
%%% @doc OpenFlow Logical Switch logic.
%%% @end
%%%-----------------------------------------------------------------------------
-module(ofs_logic).
-author("Erlang Solutions Ltd. <openflow@erlang-solutions.com>").

-behaviour(gen_server).

%% API
-export([
         start_link/2,
         message/2,
         send/1,
         register_receiver/2,
         unregister_receiver/1,
         get_connection/1
        ]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-include("of_switch.hrl").
-include_lib("of_protocol/include/of_protocol.hrl").
-include_lib("of_protocol/include/ofp_v3.hrl").

-record(state, {
          connections = [] :: [#connection{}],
          generation_id :: integer(),
          backend_mod :: atom(),
          backend_state :: term(),
          datapath_mac :: binary()
         }).

%%%-----------------------------------------------------------------------------
%%% API functions
%%%-----------------------------------------------------------------------------

%% @doc Start the OF Switch logic.
-spec start_link(atom(), term()) -> {ok, pid()} | {error, any()}.
start_link(BackendMod, BackendOpts) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE,
                          [BackendMod, BackendOpts], []).

%% @doc Deliver message to the OF Switch logic.
-spec message(ofp_message(), pid()) -> any().
message(Message, From) ->
    gen_server:cast(?MODULE, {message, From, Message}).

%% @doc Send message out to controllers.
-spec send(ofp_message()) -> any().
send(Message) ->
    gen_server:cast(?MODULE, {send, Message}).

%% @doc Register receiver.
-spec register_receiver(pid(), port()) -> any().
register_receiver(Pid, Socket) ->
    gen_server:cast(?MODULE, {register, Pid, Socket}).

%% @doc Unregister receiver.
-spec unregister_receiver(pid()) -> any().
unregister_receiver(Pid) ->
    gen_server:cast(?MODULE, {unregister, Pid}).

%% @doc Get connection information.
-spec get_connection(pid()) -> any().
get_connection(Pid) ->
    gen_server:call(?MODULE, {get_connection, Pid}).

%%%-----------------------------------------------------------------------------
%%% gen_server callbacks
%%%-----------------------------------------------------------------------------

init([BackendMod, BackendOpts]) ->
    %% We trap exit signals here to handle shutdown initiated by the supervisor
    %% and run terminate function which invokes terminate in callback modules
    process_flag(trap_exit, true),
    {ok, Controllers} = application:get_env(of_switch, controllers),
    [ofs_receiver_sup:open(Host, Port) || {Host, Port} <- Controllers],
    {ok, BackendState} = BackendMod:start(BackendOpts),
    {ok, #state{backend_mod = BackendMod,
                backend_state = BackendState,
                datapath_mac = get_ifhwaddr()}}.

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
    ?DEBUG("Received: ~p (from ~p)~n", [Message, Connection#connection.socket]),
    NewState = handle_message(Message, Connection, State),
    {noreply, NewState};
handle_cast({send, #ofp_message{body = Body} = Message},
            #state{connections = Connections} = State) ->
    Target = if
                 (is_record(Body, ofp_port_status))
                 orelse (is_record(Body, ofp_error)) ->
                     Connections;
                 (is_record(Body, ofp_packet_in))
                 orelse (is_record(Body, ofp_flow_removed)) ->
                     lists:filter(fun(#connection{role = slave}) ->
                                          false;
                                     (#connection{role = _}) ->
                                          true
                                  end, Connections);
                 true ->
                     []
             end,
    [do_send(Socket, Message) || #connection{socket = Socket} <- Target],
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #state{backend_mod = BackendMod,
                          backend_state = BackendState}) ->
    {ok, Controllers} = application:get_env(of_switch, controllers),
    [ofs_receiver_sup:close(Host, Port) || {Host, Port} <- Controllers],
    BackendMod:stop(BackendState).

code_change(_OldVersion, State, _Extra) ->
    {ok, State}.

%%%-----------------------------------------------------------------------------
%%% Message handling functions
%%%-----------------------------------------------------------------------------

%% @doc Handle different kind of messages.
-spec handle_message(ofp_message(), connection(),
                     #state{}) -> #state{}.
handle_message(#ofp_message{version = ReceivedVersion,
                            body = #ofp_hello{}} = Message,
               #connection{pid = Pid, socket = Socket,
                           version = undefined} = Connection,
               #state{connections = Connections} = State) ->
    %% Wait for hello and decide on version if it's undefined.
    case decide_on_version(ReceivedVersion) of
        {ok, Version} ->
            NewConnection = Connection#connection{version = Version},
            NewConnections = lists:keyreplace(Pid, #connection.pid,
                                              Connections, NewConnection),
            State#state{connections = NewConnections};
        error ->
            send_reply(Socket, Message, #ofp_error{type = hello_failed,
                                                   code = incompatible}),
            State
    end;
handle_message(_Message, #connection{version = undefined}, State) ->
    %% If version is undefined drop all the other messages.
    State;
handle_message(#ofp_message{body = #ofp_hello{}}, _, State) ->
    %% Drop hello messages once version is known.
    State;
handle_message(#ofp_message{body = #ofp_error{type = hello_failed}},
               #connection{pid = Pid}, State) ->
    %% Disconnect when hello_failed was received.
    ofs_receiver:stop(Pid),
    State;
handle_message(#ofp_message{body = #ofp_features_request{}} = Request,
               #connection{socket = Socket},
               #state{datapath_mac = DatapathMac} = State) ->
    FeaturesReply = #ofp_features_reply{datapath_mac = DatapathMac,
                                        datapath_id = 0,
                                        n_buffers = 0,
                                        n_tables = 255},
    send_reply(Socket, Request, FeaturesReply),
    State;
handle_message(#ofp_message{body = #ofp_set_config{}}, _, State) ->
    %% TODO: persist incoming configuration
    State;
handle_message(#ofp_message{body = #ofp_get_config_request{}} = Request,
               #connection{socket = Socket},
               State) ->
    ConfigReply = #ofp_get_config_reply{flags = [],
                                        miss_send_len = ?OFPCML_NO_BUFFER},
    send_reply(Socket, Request, ConfigReply),
    State;
handle_message(#ofp_message{body = #ofp_role_request{}} = Request,
               #connection{socket = Socket} = Connection,
               #state{} = State) ->
    RoleRequest = Request#ofp_message.body,
    {Reply, NewState} = handle_role(RoleRequest, Connection, State),
    send_reply(Socket, Request, Reply),
    NewState;
handle_message(#ofp_message{body = RequestBody} = Request,
               #connection{socket = Socket, role = slave},
               State) when is_record(RequestBody, ofp_flow_mod);
                           is_record(RequestBody, ofp_group_mod);
                           is_record(RequestBody, ofp_port_mod);
                           is_record(RequestBody, ofp_table_mod) ->
    %% Don't allow slave controllers to modify flows, groups, ports and tables.
    send_reply(Socket, Request, #ofp_error{type = bad_request,
                                           code = is_slave}),
    State;
handle_message(#ofp_message{body = #ofp_flow_mod{} = FlowMod} = Request,
               Connection,
               State) ->
    NewState = handle_in_backend(Request, Connection, State),
    #ofp_flow_mod{command = Command, buffer_id = BufferId} = FlowMod,
    case should_do_flow_mod_packet_out(Command, BufferId) of
        true ->
            ok; %% TODO: emulate packet_out
        false ->
            do_nothing
    end,
    NewState;
handle_message(#ofp_message{body = RequestBody} = Request, Connection, State)
  when is_record(RequestBody, ofp_port_mod);
       is_record(RequestBody, ofp_table_mod);
       is_record(RequestBody, ofp_echo_request);
       is_record(RequestBody, ofp_barrier_request);
       is_record(RequestBody, ofp_packet_out);
       is_record(RequestBody, ofp_desc_stats_request);
       is_record(RequestBody, ofp_port_stats_request);
       is_record(RequestBody, ofp_queue_stats_request);
       is_record(RequestBody, ofp_table_stats_request);
       is_record(RequestBody, ofp_group_stats_request);
       is_record(RequestBody, ofp_group_desc_stats_request);
       is_record(RequestBody, ofp_group_features_stats_request);
       is_record(RequestBody, ofp_aggregate_stats_request);
       is_record(RequestBody, ofp_flow_stats_request) ->
    %% handle those requests in backend
    handle_in_backend(Request, Connection, State);
handle_message(_, _, State) ->
    %% Drop everything else.
    State.

%%%-----------------------------------------------------------------------------
%%% Helper functions
%%%-----------------------------------------------------------------------------

-spec decide_on_version(integer()) -> {ok, integer()} | error.
decide_on_version(ReceivedVersion) ->
    {ok, SupportedVersions} = application:get_env(of_switch,
                                                  supported_versions),
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

-spec handle_role(ofp_role_request(), connection(), #state{}) ->
                         {ofp_role_reply(), #state{}}.
handle_role(#ofp_role_request{role = Role,
                              generation_id = GenerationId},
            #connection{pid = Pid} = Connection,
            #state{connections = Connections,
                   generation_id = CurrentGenId} = State) ->
    case Role of
        equal ->
            NewConns = lists:keyreplace(Pid, #connection.pid, Connections,
                                        Connection#connection{role = equal}),
            RoleReply = #ofp_role_reply{role = Role,
                                        generation_id = GenerationId},
            {RoleReply, State#state{connections = NewConns}};
        _ ->
            if
                (CurrentGenId /= undefined)
                andalso (GenerationId - CurrentGenId < 0) ->
                    ErrorReply = #ofp_error{type = role_request_failed,
                                            code = stale},
                    {ErrorReply, State};
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
                    RoleReply = #ofp_role_reply{role = Role,
                                                generation_id = GenerationId},
                    {RoleReply, NewState}
            end
    end.

should_do_flow_mod_packet_out(delete, _) ->
    false;
should_do_flow_mod_packet_out(delete_strict, _) ->
    false;
should_do_flow_mod_packet_out(_, no_buffer) ->
    false;
should_do_flow_mod_packet_out(_, _) ->
    true.

-spec handle_in_backend(#ofp_message{}, #connection{}, #state{}) -> #state{}.
handle_in_backend(#ofp_message{body = RequestBody} = Request,
                  #connection{socket = Socket},
                  #state{backend_mod = BackendMod,
                         backend_state = BackendState} = State) ->
    RequestName = element(1, RequestBody),
    try
        case BackendMod:RequestName(BackendState, RequestBody) of
            {ok, NewBackendState} ->
                ok;
            {ok, ReplyBody, NewBackendState} ->
                send_reply(Socket, Request, ReplyBody);
            {error, ErrorMessage, NewBackendState} ->
                send_reply(Socket, Request, ErrorMessage)
        end,
        State#state{backend_state = NewBackendState}
    catch #ofp_error{} = ErrorMsg ->
        send_reply(Socket, Request, ErrorMsg),
        State#state{backend_state = BackendState}
    end.

-spec do_send(port(), ofp_message()) -> any().
do_send(Socket, Message) ->
    try
        {ok, EncodedMessage} = of_protocol:encode(Message),
        ?DEBUG("Sending: ~p (to ~p)~n", [Message, Socket]),
        gen_tcp:send(Socket, EncodedMessage)
    catch
        E1:E2 ->
            ?ERROR("Encode error: ~p:~p of packet-in msg: ~p",
                   [E1, E2, Message])
    end.

send_reply(Socket, Request, ReplyBody) ->
    do_send(Socket, Request#ofp_message{body = ReplyBody}).

-spec get_ifhwaddr() -> binary().
get_ifhwaddr() ->
    {ok, Ifs}  = inet:getifaddrs(),
    HwAddrs = lists:map(fun({_, Opts}) -> hwaddr(Opts) end, Ifs),
    case lists:filter(fun (undefined) -> false;
                          (_) -> true end,
                      HwAddrs) of
        %% No mac addresses in the system
        [] ->
            %% TODO
            erorr;
        [Addr | _] ->
            Addr
    end.

-spec hwaddr(list()) -> binary() | undefined.
hwaddr([]) ->
    undefined;
hwaddr([{hwaddr, [M1, M2, M3, M4, M5, M6]} | _]) ->
    <<M1, M2, M3, M4, M5, M6>>;
hwaddr([_ | Rest]) ->
    hwaddr(Rest).
