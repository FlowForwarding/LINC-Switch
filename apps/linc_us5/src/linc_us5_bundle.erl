%%------------------------------------------------------------------------------
%% Copyright 2014 FlowForwarding.org
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
%% @copyright 2014 FlowForwarding.org
%% @doc Bundle Messages
-module(linc_us5_bundle).

-export([initialize/1,
         open/3,
         add/4,
         close/3,
         commit/4]).

-include_lib("of_protocol/include/of_protocol.hrl").
-include_lib("of_protocol/include/ofp_v5.hrl").

-type full_bundle_id() :: {integer(), pid()}.

-record(linc_bundle, {id :: full_bundle_id(),
                      state = open :: [open | closed],
                      flags :: [ofp_bundle_flag()],
                      messages = [] :: [ofp_flow_mod() | ofp_port_mod()]}).

%% @doc Module startup
initialize(SwitchId) ->
    BundleTable = ets:new(bundle_table, [public,
                                         {keypos, #linc_bundle.id},
                                         {read_concurrency, true},
                                         {write_concurrency, true}]),
    linc:register(SwitchId, bundle_table, BundleTable),
    ok.

-spec open(integer(), full_bundle_id(), [ofp_bundle_flag()]) -> ofp_message_body().
open(SwitchId, FullBundleId, Flags) ->
    case lists:member(atomic, Flags) of
        true ->
            %% Packet-atomic mode is not supported.
            #ofp_error_msg{type = bundle_failed,
                           code = bad_flags};
        false ->
            Table = linc:lookup(SwitchId, bundle_table),
            SortedFlags = lists:usort(Flags),
            Entry = #linc_bundle{id = FullBundleId, flags = SortedFlags, messages = []},
            case ets:insert_new(Table, Entry) of
                false ->
                    %% If the bundle_id already refers to an existing
                    %% bundle attached to the same connection, the
                    %% switch must refuse to open the new bundle and
                    %% send an ofp_error_msg with OFPET_BUNDLE_FAILED
                    %% type and OFPBFC_BAD_ID code. The existing
                    %% bundle identified by bundle_id must be
                    %% discarded.
                    ets:delete(Table, FullBundleId),
                    #ofp_error_msg{type = bundle_failed,
                                   code = bad_id};
                true ->
                    #ofp_bundle_ctrl_msg{
                       bundle_id = element(1, FullBundleId),
                       type = open_reply}
            end
    end.

add(SwitchId, FullBundleId, Message, Flags) ->
    %% If the bundle doesn't exist, create it without returning
    %% open_reply.
    Table = linc:lookup(SwitchId, bundle_table),
    SortedFlags = lists:usort(Flags),
    case ets:lookup(Table, FullBundleId) of
        [] ->
            case open(SwitchId, FullBundleId, Flags) of
                #ofp_bundle_ctrl_msg{type = open_reply} ->
                    add(SwitchId, FullBundleId, Message, Flags);
                #ofp_error_msg{} = Error ->
                    Error
            end;
        [#linc_bundle{messages = Messages, state = open, flags = SortedFlags} = Bundle] ->
            case prevalidate_message(SwitchId, Message) of
                ok ->
                    NewMessages = [Message | Messages],
                    NewBundle = Bundle#linc_bundle{messages = NewMessages},
                    ets:insert(Table, NewBundle),
                    noreply;
                %% XXX: what about XIDs?
                #ofp_error_msg{} = Error ->
                    Error
            end;
        [#linc_bundle{state = closed}] ->
            #ofp_error_msg{type = bundle_failed,
                           code = bundle_closed};
        [#linc_bundle{flags = BundleFlags}] when BundleFlags =/= SortedFlags ->
            #ofp_error_msg{type = bundle_failed,
                           code = bad_flags}
    end.

close(SwitchId, FullBundleId, Flags) ->
    Table = linc:lookup(SwitchId, bundle_table),
    SortedFlags = lists:usort(Flags),
    case ets:lookup(Table, FullBundleId) of
        [] ->
            #ofp_error_msg{type = bundle_failed,
                           code = bad_id};
        [#linc_bundle{state = closed}] ->
            #ofp_error_msg{type = bundle_failed,
                           code = bundle_closed};
        [#linc_bundle{flags = BundleFlags}] when BundleFlags =/= SortedFlags ->
            #ofp_error_msg{type = bundle_failed,
                           code = bad_flags};
        [#linc_bundle{} = Bundle] ->
            NewBundle = Bundle#linc_bundle{state = closed},
            ets:insert(Table, NewBundle),
            #ofp_bundle_ctrl_msg{
               bundle_id = element(1, FullBundleId),
               type = close_reply}
    end.

commit(SwitchId, FullBundleId, Flags, MonitorData) ->
    Table = linc:lookup(SwitchId, bundle_table),
    SortedFlags = lists:usort(Flags),
    case ets:lookup(Table, FullBundleId) of
        [] ->
            #ofp_error_msg{type = bundle_failed,
                           code = bad_id};
        [#linc_bundle{flags = BundleFlags}] when BundleFlags =/= SortedFlags ->
            #ofp_error_msg{type = bundle_failed,
                           code = bad_flags};
        [#linc_bundle{messages = Messages}] ->
            %% After a commit operation, the bundle is discarded,
            %% whether the commit was successful or not.
            ets:delete(Table, FullBundleId),
            FlowMods = lists:filter(
                         fun(#ofp_message{body = Body}) ->
                                 is_record(Body, ofp_flow_mod) end,
                         Messages),
            PortMods = lists:filter(
                         fun(#ofp_message{body = Body}) ->
                                 is_record(Body, ofp_port_mod) end,
                         Messages),
            PortModValidationErrors =
                lists:zf(
                  fun(Msg = #ofp_message{body = #ofp_port_mod{} = PortMod}) ->
                          case linc_us5_port:validate(SwitchId, PortMod) of
                              ok ->
                                  false;
                              {error, {Type, Code}} ->
                                  {true, Msg#ofp_message{
                                           body = #ofp_error_msg{type = Type, code = Code}}}
                          end
                  end, PortMods),
            %% The port mods are guaranteed to succeed if they
            %% validate, so to execute this atomically we just need to
            %% be careful about the flow mods:
            case PortModValidationErrors of
                [] ->
                    case linc_us5_flow:bundle(SwitchId, FlowMods, MonitorData) of
                        ok ->
                            lists:foreach(
                              fun(#ofp_message{body = #ofp_port_mod{} = PortMod}) ->
                                      ok = linc_us5_port:modify(SwitchId, PortMod)
                              end, PortMods),
                            #ofp_bundle_ctrl_msg{
                               bundle_id = element(1, FullBundleId),
                               type = commit_reply};
                        {error, Errors} when is_list(Errors) ->
                            Errors ++ [#ofp_error_msg{type = bundle_failed,
                                                      code = msg_failed}]
                    end;
                [_|_] ->
                    PortModValidationErrors ++ [#ofp_error_msg{type = bundle_failed,
                                                               code = msg_failed}]
            end
    end.
            
prevalidate_message(_SwitchId, #ofp_message{body = #ofp_flow_mod{}}) ->
    ok;
prevalidate_message(SwitchId, #ofp_message{body = #ofp_port_mod{} = PortMod}) ->
    case linc_us5_port:validate(SwitchId, PortMod) of
        ok ->
            ok;
        {error, {Type, Code}} ->
            #ofp_error_msg{type = Type, code = Code}
    end;
prevalidate_message(_SwitchId, _Unsupported) ->
    #ofp_error_msg{type = bundle_failed,
                   code = msg_unsup}.
