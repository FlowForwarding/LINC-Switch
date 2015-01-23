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
-module(linc_us4_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("of_protocol/include/ofp_v4.hrl").

%% Tests -----------------------------------------------------------------------

-define(TIMEOUT, 300).
-define(MOCKED, [sup, group, flow, port]).

switch_setup_test_() ->
    {setup,
     fun setup/0,
     fun teardown/1,
     [
      {"Start/stop LINC v4 switch backend w/o OF-Config subsystem",
       fun no_ofconfig/0},
      {"Start/stop LINC v4 switch backend with OF-Config subsystem",
       fun with_ofconfig/0},
      {"Start/stop LINC v4 switch backend with controllers listener enabled",
       fun with_controllers_listener/0}
     ]}.

switch_config_request_reply_test_() ->
    {setup,
     fun config_request_reply_setup/0,
     fun config_request_reply_teardown/1,
     [
      {foreach,
       fun mocked_us4_backend_setup/0,
       fun(_) -> ok end,
       [
        fun default_switch_config/1,
        fun custom_switch_config/1
       ]}
     ]}.

no_ofconfig() ->
    load_linc_with_default_env(),
    [begin
         ?assertEqual(ok, application:start(linc)),
         timer:sleep(?TIMEOUT),
         ?assertEqual(ok, application:stop(linc))
     end || _ <- [lists:seq(1,10)]].

with_ofconfig() ->
    %% Default sshd port is 830 and requires root or cap_net_admin capability
    %% on the beam to open the port, thus we change it to value above 1024.
    application:load(linc),
    application:set_env(enetconf, sshd_port, 1830),
    application:set_env(linc, of_config, enabled),
    application:set_env(linc, backend, linc_us4),

    [begin
         case application:start(linc) of
             ok ->
                 ok;
             {error, Error} ->
                 ?debugFmt("Cannot start linc: ~p~n", [Error]),
                 erlang:error({start_error, Error})
         end,
         timer:sleep(?TIMEOUT),
         ?assertEqual(ok, application:stop(linc))
     end || _ <- [lists:seq(1,10)]].

with_controllers_listener() ->
    load_linc_with_default_env(),
    {ok, [{switch, 0, Config}]} = application:get_env(linc, logical_switches),
    NewConfig =
        lists:keyreplace(controllers_listener, 1, Config,
                         {controllers_listener, {"127.0.0.1", 6653, tcp}}),
    application:set_env(linc, logical_switches, [{switch, 0, NewConfig}]),
    [begin
         ?assertEqual(ok, application:start(linc)),
         timer:sleep(?TIMEOUT),
         ?assertEqual(ok, application:stop(linc))
     end || _ <- [lists:seq(1,10)]].

default_switch_config(State) ->
    {"Test if the switch initial config is set correctly",
     fun() ->
             [begin
                  {_, ConfigReply, _} = linc_us4:ofp_get_config_request(
                                          State, #ofp_get_config_request{}),
                  ?assertMatch(#ofp_get_config_reply{flags = [],
                                                     miss_send_len = no_buffer},
                               ConfigReply)
              end || _ <- lists:seq(1, 10)]
     end}.

custom_switch_config(State) ->
    {"Test if the switch config is set correctly",
     fun() ->
             [begin
                  Flags = case random:uniform(1000) rem 5 of
                              0 -> [];
                              1 -> [frag_normal];
                              2 -> [frag_drop];
                              3 -> [frag_reasm];
                              4 -> [frag_drop, frag_reasm]
                          end,
                  MissSendLen = 16#FFFF - (I * 100),
                  {_, NewState} = linc_us4:ofp_set_config(
                                    State,
                                    #ofp_set_config{flags = Flags,
                                                    miss_send_len =
                                                        MissSendLen}),
                  {_, ConfigReply, _} = linc_us4:ofp_get_config_request(
                                          NewState, #ofp_get_config_request{}),
                  ?assertMatch(#ofp_get_config_reply{flags = Flags,
                                                     miss_send_len =
                                                         MissSendLen},
                               ConfigReply)
              end || I <- lists:seq(1, 10)]
     end}.


%% Fixtures --------------------------------------------------------------------

setup() ->
    meck:new(inet, [unstick, passthrough]),
    meck:expect(inet, getifaddrs, 0,
                {ok, [{"fake0",
                       [{flags,[up,broadcast,running,multicast]},
                        {hwaddr,[2,0,0,0,0,1]},
                        {addr,{192,168,1,1}},
                        {netmask,{255,255,255,0}},
                        {broadaddr,{192,168,1,255}}]}]}),
    linc_us4_test_utils:add_logic_path(),
    error_logger:tty(false),
    ok = application:start(xmerl),
    ok = application:start(mnesia),
    ok = application:start(syntax_tools),
    ok = application:start(compiler),
    ok = application:start(netlink),
    ok = application:start(goldrush),
    ok = application:start(lager),
    ok = lager:set_loglevel(lager_console_backend, error).

teardown(_) ->
    meck:unload(inet),
    ok = application:stop(compiler),
    ok = application:stop(syntax_tools),
    ok = application:stop(mnesia),
    ok = application:stop(xmerl),
    ok = application:stop(netlink),
    ok = application:stop(lager),
    ok = application:stop(goldrush).

config_request_reply_setup() ->
    mocked = linc_us4_test_utils:mock(?MOCKED),

    meck:new(linc_buffer),
    meck:expect(linc_buffer, initialize,
                fun(_) ->
                        ok
                end).

config_request_reply_teardown(_) ->
    unmocked = linc_us4_test_utils:unmock(?MOCKED),
    meck:unload(linc_buffer).

mocked_us4_backend_setup() ->
    DummyBackendOpts = [ {Opt, dummy} || Opt <- [switch_id,
                                                 datapath_mac,
                                                 config] ],
    {ok, 4, State} = linc_us4:start(DummyBackendOpts),
    State.

%% Helper functions  -----------------------------------------------------------

load_linc_with_default_env() ->
    application:load(linc),
    application:set_env(linc, of_config, disabled),
    Config = [{switch, 0,
               [{backend, linc_us4},
                {controllers, []},
                {controllers_listener, disabled},
                {ports, []},
                {queues_status, disabled},
                {queues, []}]}],
    application:set_env(linc, logical_switches, Config),
    application:set_env(linc, capable_switch_ports, []),
    application:set_env(linc, capable_switch_queues, []).
