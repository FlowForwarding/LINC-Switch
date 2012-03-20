%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2012, Erlang Solutions Ltd.
%%% @author Grzegorz Stanislawski <grzegorz.stanislawski@erlang-solutions.com>
%%% @doc Linux Netlink interface library module. Netlink API Mgr
%%% Interface will follow usage of openvswitch tools:
%%% ovs-vsctl and ovs-ofctl
%%% @end
%%%-----------------------------------------------------------------------------
-module(of_netlink_mgr).
-behaviour(gen_server).
-include("netlink_rec.hrl").
%-include_lib("procket/include/procket.hrl").

%% API
-export([start_link/0,
         listbr/0, addbr/1, showbr/1, delbr/1,
         listports/1, addport/2, delport/2
        ]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(SERVER, ?MODULE).
-record(state, {
        mgr_pid, % do i need this?
        dp_id = undefined,
        vp_id = undefined,
        fl_id = undefined,
        pk_id = undefined
         }).

%%%===================================================================
%%% API
%%%===================================================================
%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

listbr() ->
    gen_server:call(?SERVER, listbr).
addbr(Br) ->
    gen_server:call(?SERVER, {addbr,Br}).
showbr(Br) ->
    gen_server:call(?SERVER, {showbr,Br}).
delbr(Br) ->
    gen_server:call(?SERVER, {delbr,Br}).
listports(Br) ->
    gen_server:call(?SERVER, {listports,Br}).
addport(Br,Port) ->
    gen_server:call(?SERVER, {addport,Br,Port}).
delport(Br,Port) ->
    gen_server:call(?SERVER, {delport,Br,Port}).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================
%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
init([]) ->
    error_logger:info_msg("[~p] started pid=~p~n",[?MODULE,self()]),
    Pkt1=#nlmsg{len = undefined, type = 16,request = 1,multi = 0,ack = 0, echo = 0,dumpintr = 0,seq = undefined,pid = undefined,
        payload = #genlmsg{cmd = 3,version = 1,
        payload = [#nla_attr{type = 2,n = 0,o = 0, data = "ovs_datapath"}]}},
    Pkt2=#nlmsg{len = undefined, type = 16,request = 1,multi = 0,ack = 0, echo = 0,dumpintr = 0,seq = undefined,pid = undefined,
        payload = #genlmsg{cmd = 3,version = 1,
        payload = [#nla_attr{type = 2,n = 0,o = 0, data = "ovs_vport"}]}},
    Pkt3=#nlmsg{len = undefined, type = 16,request = 1,multi = 0,ack = 0, echo = 0,dumpintr = 0,seq = undefined,pid = undefined,
        payload = #genlmsg{cmd = 3,version = 1,
        payload = [#nla_attr{type = 2,n = 0,o = 0, data = "ovs_flow"}]}},
    Pkt4=#nlmsg{len = undefined, type = 16,request = 1,multi = 0,ack = 0, echo = 0,dumpintr = 0,seq = undefined,pid = undefined,
        payload = #genlmsg{cmd = 3,version = 1,
        payload = [#nla_attr{type = 2,n = 0,o = 0, data = "ovs_packet"}]}},
%    Pkt5=#nlmsg{len = undefined, type = 16,request = 1,multi = 0,ack = 0, echo = 0,dumpintr = 0,seq = undefined,pid = undefined,
%        payload = #genlmsg{cmd = 3,version = 1,
%        payload = [#nla_attr{type = 2,n = 0,o = 0, data = "ovs_vport"}]}},
    Reply1=gen_server:call(netlink_mgr,{sendpkt,Pkt1}),
    [_,#nla_attr{type=1,data=Dp}|_]=(Reply1#nlmsg.payload)#genlmsg.payload,
    ok=gen_server:call(netlink_mgr,{set,ovs_datapath,Dp}),
    Reply2=gen_server:call(netlink_mgr,{sendpkt,Pkt2}),
    [_,#nla_attr{type=1,data=Vp}|_]=(Reply2#nlmsg.payload)#genlmsg.payload,
    ok=gen_server:call(netlink_mgr,{set,ovs_vport,Vp}),
    Reply3=gen_server:call(netlink_mgr,{sendpkt,Pkt3}),
    [_,#nla_attr{type=1,data=Fl}|_]=(Reply3#nlmsg.payload)#genlmsg.payload,
    ok=gen_server:call(netlink_mgr,{set,ovs_flow,Fl}),
    Reply4=gen_server:call(netlink_mgr,{sendpkt,Pkt4}),
    [_,#nla_attr{type=1,data=Pk}|_]=(Reply4#nlmsg.payload)#genlmsg.payload,
    ok=gen_server:call(netlink_mgr,{set,ovs_packet,Pk}),
    {ok, #state{dp_id = Dp, vp_id = Vp, fl_id = Fl, pk_id = Pk}}.
%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%% @end
%%--------------------------------------------------------------------
handle_call(listbr, From, State) ->
    error_logger:info_msg("[~p]  listbr call from ~p~nwhen in state: ~p~n",
        [?MODULE, From, State]),
    {reply, ok, State};

handle_call({addbr,Br}, From, State=#state{dp_id=Dp}) ->
    error_logger:info_msg("[~p] addbr ~p call from ~p~nwhen in state: ~p~n",
        [?MODULE, Br,From, State]),
    Pkt=#nlmsg{len = undefined, type = Dp,request = 1,multi = 0,ack = 1, echo = 1,dumpintr = 0,seq = undefined,pid = undefined,
        payload = #ovsdpmsg{cmd = 1,version = 1,ifindex = 0, payload =[#nla_attr{type = 1,n = 0,o = 0,data = Br},
        #nla_attr{type = 2,n = 0,o = 0,data = 0}]}},
     Reply=gen_server:call(netlink_mgr,{sendpkt,Pkt},30000),
    {reply, Reply, State};

handle_call({showbr,Br}, From, State=#state{dp_id=Dp}) ->
    error_logger:info_msg("[~p] showbr ~p call from ~p~nwhen in state: ~p~n",
        [?MODULE, Br, From, State]),
    Pkt=#nlmsg{len = undefined, type = Dp,request = 1,multi = 0,ack = 1, echo = 1,dumpintr = 0,seq = undefined,pid = undefined,
    payload = #ovsdpmsg{cmd = 3,version = 1,ifindex = 0, payload =[#nla_attr{type = 1,n = 0,o = 0,data = Br}]}},
    Reply=gen_server:call(netlink_mgr,{sendpkt,Pkt},30000),
    {reply, Reply, State};

handle_call({delbr,Br}, From, State=#state{dp_id=Dp}) ->
    error_logger:info_msg("[~p] delbr ~p call from ~p~nwhen in state: ~p~n",
        [?MODULE, Br, From, State]),
    Pkt=#nlmsg{len = undefined, type = Dp,request = 1,multi = 0,ack = 1, echo = 1,dumpintr = 0,seq = undefined,pid = undefined,
        payload = #ovsdpmsg{cmd = 2,version = 1,ifindex = 0, payload =[#nla_attr{type = 1,n = 0,o = 0,data = Br},
        #nla_attr{type = 2,n = 0,o = 0,data = 0}]}},
    Reply=gen_server:call(netlink_mgr,{sendpkt,Pkt},30000),
    {reply, Reply, State};

handle_call({listports,Br}, From, State) ->
    error_logger:info_msg("[~p] listports call from ~p~nwhen in state: ~p~n",
        [?MODULE, Br, From, State]),
    {reply, ok, State};

handle_call({addport,Br,Port}, From, State) ->
    error_logger:info_msg("[~p] addport ~p ~p call from ~p~nwhen in state: ~p~n",
        [?MODULE, Br, Port, From, State]),
    {reply, ok, State};

handle_call({delport,Br,Port}, From, State) ->
    error_logger:info_msg("[~p] delport ~p ~p call from ~p~nwhen in state: ~p~n",
        [?MODULE, Br, Port, From, State]),
    {reply, ok, State};

handle_call(Request, From, State) ->
    error_logger:info_msg("[~p] unhandled call from ~p: ~p~nwhen in state: ~p~n",
        [?MODULE, From, Request, State]),
    {reply, ok, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%% @end
%%--------------------------------------------------------------------

handle_cast(Request, State) ->
    error_logger:info_msg("[~p] unhandled cast: ~p~nwhen in state: ~p~n",
        [?MODULE, Request, State]),
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%% @end
%%--------------------------------------------------------------------
handle_info(Request, State) ->
    error_logger:info_msg("[~p] unhandled msg: ~p~nwhen in state: ~p~n",
        [?MODULE, Request, State]),
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------

terminate(Reason, State) ->
    error_logger:info_msg("[~p] terminate: ~p~nwhen in state: ~p", [?MODULE, Reason, State]),
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
%%%===================================================================
%%% Internal functions
%%%===================================================================

