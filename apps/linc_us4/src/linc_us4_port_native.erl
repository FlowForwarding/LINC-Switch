%%------------------------------------------------------------------------------
%% Copyright 2012 FlowForwarding.org
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%-----------------------------------------------------------------------------

%% @author Erlang Solutions Ltd. <openflow@erlang-solutions.com>
%% @copyright 2012 FlowForwarding.org
-module(linc_us4_port_native).

-export([tap/2,
         eth/1,
         send/3,
         close/1,
         operstate_change/3]).

-ifdef(TEST).
-compile([export_all]).
-endif.

-include_lib("of_protocol/include/of_protocol.hrl").
-include_lib("of_protocol/include/ofp_v4.hrl").
-include_lib("linc/include/linc_logger.hrl").
-include("linc_us4.hrl").
-include("linc_us4_port.hrl").

-spec tap(string(), list(term())) -> {port(), pid(), binary()} |
                                     {stop, shutdown}.
tap(Interface, PortOpts) ->
    case tuncer:create(Interface) of
        {ok, Pid} ->
            case os:type() of
                %% Under MacOS we configure TAP interfaces
                %% programatically as they can't be created in
                %% persistent mode before node startup.
                {unix, darwin} ->
                    {ip, IP} = lists:keyfind(ip, 1, PortOpts),
                    ok = tuncer:up(Pid, IP);
                %% We assume that under linux and NetBSD TAP interfaces are
                %% already set up in persistent state and
                %% configured with proper IP addresses.
                {unix, linux} ->
                    ok;
                {unix, netbsd} ->
                    ok
            end,
            Fd = tuncer:getfd(Pid),
            Port = open_port({fd, Fd, Fd}, [binary]),
            HwAddr = get_hw_addr(Interface),
            {OperstateChangesRef, Operstate} =
                get_operstate_and_subscribe_for_changes(Interface),
            {Port, Pid, HwAddr, OperstateChangesRef, Operstate};
        {error, Error} ->
            ?ERROR("Tuncer error ~p for interface ~p",
                   [Error, Interface]),
            {stop, shutdown}
    end.

eth(Interface) ->
    {ok, Pid} = epcap:start(epcap_options(Interface)),
    {Socket, IfIndex} = case os:type() of
                            {unix, darwin} ->
                                bpf_raw_socket(Interface);
                            {unix, netbsd} ->
                                bpf_raw_socket(Interface);
                            {unix, linux} ->
                                linux_raw_socket(Interface)
                        end,
    HwAddr = get_hw_addr(Interface),
    {OperstateChangesRef, Operstate} =
        get_operstate_and_subscribe_for_changes(Interface),
    {Socket, IfIndex, Pid, HwAddr, OperstateChangesRef, Operstate}.

%% TODO: Add typespecs to procket to avoid:
%% linc_us4_port_procket.erl:7: Function send/2 has no local return
%% linc_us4_port_procket.erl:11: Function close/1 has no local return
%% warnings in dialyzer.

-spec send(integer(), integer(), binary()) -> ok.
send(Socket, Ifindex, Frame) ->
    case os:type() of
        {unix, darwin} ->
            procket:write(Socket, Frame);
        {unix, netbsd} ->
            procket:write(Socket, Frame);
        {unix, linux} ->
            packet:send(Socket, Ifindex, Frame)
    end.

close(#state{socket = undefined, port_ref = PortRef,
             operstate_changes_ref = OperstateRef}) ->
    unsubscribe_for_operstate_changes(OperstateRef),
    tuncer:down(PortRef),
    tuncer:destroy(PortRef);
close(#state{socket = Socket, port_ref = undefined, epcap_pid = EpcapPid,
             operstate_changes_ref = OperstateRef}) ->
    unsubscribe_for_operstate_changes(OperstateRef),
    %% We use catch here to avoid crashes in tests, where EpcapPid is mocked
    %% and it's an atom, not a pid.
    case catch is_process_alive(EpcapPid) of
        true ->
            epcap:stop(EpcapPid);
        _ ->
            ok
    end,
    procket:close(Socket).

operstate_change({netlink, SubscriptionRef, Interface, operstate,
                  _PrevOperstate, NewOperstate}, SubscriptionRef, Interface) ->
    operstate(NewOperstate);
operstate_change({netlink, _, _, operstate, _, _} = Msg, _, Interface) ->
    ?ERROR("Got unexpected operstate change messsage on interface ~s: ~p~n",
           [Interface, Msg]),
    throw({unexpected_operstate_change, Msg}).

%%%-----------------------------------------------------------------------------
%%% Internal functions
%%%-----------------------------------------------------------------------------

%% TODO: Add typespecs to bpf and procket in general to avoid:
%% linc_us4_port.erl:446: Function bpf_raw_socket/1 has no local return
%% warnings in dialyzer.
-spec bpf_raw_socket(string()) -> tuple(integer(), 0).
bpf_raw_socket(Interface) ->
    case bpf:open(Interface) of
        {ok, Socket, _Length} ->
            bpf:ctl(Socket, setif, Interface),
            {Socket, 0};
        {error, Error} ->
            ?ERROR("Cannot open bpf raw socket for"
                        " interface ~p because: ~p", [Interface, Error]),
            {0, 0};
        Any ->
            ?ERROR("Cannot open bpf raw socket for"
                        " interface ~p because: ~p", [Interface, Any]),
            {0, 0}
    end.

%% TODO: Add typespecs to packet and procket in general to avoid:
%% linc_us4_port.erl:462: Function linux_raw_socket/1 has no local return
%% warnings in dialyzer.
-spec linux_raw_socket(string()) -> tuple(integer(), integer()).
linux_raw_socket(Interface) ->
    {ok, Socket} = packet:socket(),
    Ifindex = packet:ifindex(Socket, Interface),
    packet:promiscuous(Socket, Ifindex),
    ok = packet:bind(Socket, Ifindex),
    {Socket, Ifindex}.

-spec get_hw_addr(string()) -> binary().
get_hw_addr(Interface) ->
    {ok, Ifs} = inet:getifaddrs(),
    DefaultMAC = <<0,0,0,0,0,0>>,
    case lists:keyfind(Interface, 1, Ifs) of
        false ->
            DefaultMAC;
        {Interface, Opts} ->
            case lists:keyfind(hwaddr, 1, Opts) of
                false ->
                    DefaultMAC;
                {hwaddr, MAC} ->
                    list_to_binary(MAC)
            end
    end.

-spec get_operstate_and_subscribe_for_changes(IntfName :: string()) ->
                                                     Result when
      Result :: {SubscriptionRef :: reference(),
                 CurrentOperstate :: up | down}.
get_operstate_and_subscribe_for_changes(Intf) ->
    {ok, Ref} = netlink:subscribe(Intf, [operstate]),
    netlink:invalidate(Intf, [operstate]),
    netlink:get_match(link, unspec, [{operstate, native, _AnyState = up}]),
    receive
        {netlink, Ref, Intf, operstate, _PrevOperstate, Operstate} ->
            {Ref, operstate(Operstate)}
    after
        500 ->
            ?ERROR("Cannot get current operation state for interface ~p~n",
                   [Intf]),
            throw(cannot_get_interface_operstate)
    end.

operstate(up) ->
    up;
operstate(_) ->
    down.

unsubscribe_for_operstate_changes(Ref) ->
    ok = netlink:unsubscribe(Ref).

-spec epcap_options(string()) -> list(tuple()).
epcap_options(Interface) ->
    DefaultOptions = [{no_register, true},
                      {promiscuous, true},
                      {interface, Interface},
                      %% to work on ipv4-less interfaces
                      {no_lookupnet, true},
                      %% for ethernet-only (without taps and bridges)
                      {filter_incoming, true},
                      {filter, ""}],
    add_epcap_env_options(DefaultOptions).

-spec add_epcap_env_options(list(tuple())) -> list(tuple()).
add_epcap_env_options(Options) ->
    EpcapEnv = application:get_all_env(epcap),
    add_epcap_env_options(Options, EpcapEnv).

-spec add_epcap_env_options(list(tuple()), list(tuple())) ->
                                                 list(tuple()).
add_epcap_env_options(Options, [{verbose, true} | Rest]) ->
    add_epcap_env_options([{verbose, 2} | Options], Rest);
add_epcap_env_options(Options, [{stats_interval, Value} = Opt | Rest])
  when is_integer(Value) ->
    add_epcap_env_options([Opt | Options], Rest);
add_epcap_env_options(Options, [{buffer_size, Value} = Opt | Rest])
  when is_integer(Value) ->
    add_epcap_env_options([Opt | Options], Rest);
add_epcap_env_options(Options, []) ->
    Options;
add_epcap_env_options(Options, [_UnknownOption | Rest]) ->
    add_epcap_env_options(Options, Rest).
