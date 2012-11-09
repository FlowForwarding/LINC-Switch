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
%% @doc Utility module for nicer tests.
-module(linc_test_utils).

-export([mock/1,
         unmock/1,
         check_output_on_ports/0,
         check_output_to_groups/0,
         check_if_called/1,
         check_if_called/2]).

mock([]) ->
    mocked;
mock([port | Rest]) ->
    ok = meck:new(linc_us3_port),
    ok = meck:expect(linc_us3_port, send,
                     fun(_, _) ->
                             ok
                     end),
    ok = meck:expect(linc_us3_port, send,
                     fun(_, _, _) ->
                             ok
                     end),
    mock(Rest);
mock([group | Rest]) ->
    mock(Rest);
mock([instructions | Rest]) ->
    ok = meck:new(linc_us3_instructions),
    ok = meck:expect(linc_us3_instructions, apply,
                     fun(Pkt, _) ->
                             {stop, Pkt}
                     end),
    mock(Rest);
mock([actions | Rest]) ->
    ok = meck:new(linc_us3_actions),
    ok = meck:expect(linc_us3_actions, apply_set,
                     fun(_, _) ->
                             ok
                     end),
    ok = meck:expect(linc_us3_actions, apply_list,
                     fun(Pkt, _) ->
                             Pkt
                     end),
    mock(Rest).

unmock([]) ->
    unmocked;
unmock([port | Rest]) ->
    ok = meck:unload(linc_us3_port),
    unmock(Rest);
unmock([group | Rest]) ->
    ok = meck:unload(linc_us3_group),
    unmock(Rest);
unmock([instructions | Rest]) ->
    ok = meck:unload(linc_us3_instructions),
    unmock(Rest);
unmock([actions | Rest]) ->
    ok = meck:unload(linc_us3_actions),
    unmock(Rest).

check_output_on_ports() ->
    [{Pkt, PortNo}
     || {_, {_, send, [Pkt, PortNo]}, ok} <- meck:history(linc_us3_port)].

check_output_to_groups() ->
    [{Pkt, GroupId}
     || {_, {_, apply, [Pkt, GroupId]}, ok} <- meck:history(linc_us3_group)].

check_if_called({Module, Fun, Arity}) ->
    check_if_called({Module, Fun, Arity}, {1, times}).

check_if_called({Module, Fun, Arity}, {Times, times}) ->
    History = meck:history(Module),
    case Arity of
        0 ->
            [x || {_, {_, F, []}, _} <- History, F == Fun];
        1 ->
            [x || {_, {_, F, [_]}, _} <- History, F == Fun];
        2 ->
            [x || {_, {_, F, [_, _]}, _} <- History, F == Fun];
        3 ->
            [x || {_, {_, F, [_, _, _]}, _} <- History, F == Fun];
        4 ->
            [x || {_, {_, F, [_, _, _, _]}, _} <- History, F == Fun]
    end == [x || _ <- lists:seq(1, Times)].
