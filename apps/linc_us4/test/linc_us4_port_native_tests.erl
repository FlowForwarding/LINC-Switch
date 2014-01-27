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
-module(linc_us4_port_native_tests).

-import(linc_us4_test_utils, [mock/1,
                              unmock/1,
                              check_if_called/1,
                              check_output_on_ports/0]).

-include_lib("eunit/include/eunit.hrl").

-define(MOCKED, [epcap, port_native_sockets]).
-define(INTERFACE, "eth0").
-define(CUSTOM_BUFFER_SIZE, 20*1024*1024).
-define(PRINTING_STATS_INTERVAL_IN_SEC, 10).
-define(EPCAP_NORMAL_START_OPTS(Interface), [{no_register, true},
                                             {promiscuous, true},
                                             {interface, Interface},
                                             {no_lookupnet, true},
                                             {filter_incoming, true},
                                             {filter, ""}]).
-define(EPCAP_VERBOSE_START_OPTS(Interface),
        [{verbose, 2} | ?EPCAP_NORMAL_START_OPTS(Interface)]).
-define(EPCAP_STATS_INTERVAL_START_OPTS(Interface, PrintingStatsInterval),
        [{stats_interval, PrintingStatsInterval}
         | ?EPCAP_NORMAL_START_OPTS(Interface)]).
-define(EPCAP_CUSTOM_BUFFER_SIZE_START_OPTS(Interface, BufferSize),
        [{buffer_size, BufferSize} | ?EPCAP_NORMAL_START_OPTS(Interface)]).

%% Generators ------------------------------------------------------------------

epcap_start_test_() ->
    {setup,
     fun epcap_start_setup/0,
     fun epcap_start_teardown/1,
     [{"Test epcap start options", fun epcap_normal_start/0},
      {"Test epcap start options in verbose mode", fun epcap_verbose_start/0},
      {"Test epcap start options for unknown value of verbose option",
       fun epcap_unknown_verbose_value_start/0},
      {"Test epcap start options with custom buffer size",
       fun epcap_custom_buffer_size_start/0},
      {"Test epcap start options for unknown value for buffer size",
       fun epcap_unknown_custom_buffer_value_start/0},
      {"Test epcap start options with printing statistics interval",
       fun epcap_stats_interval_start/0},
     {"Test epcap start options for unknown value for stats interval",
      fun epcap_unknown_stats_interval_start/0}]}.

%% Tests -----------------------------------------------------------------------

epcap_normal_start() ->
    expect_epcap_start_options(?EPCAP_NORMAL_START_OPTS(?INTERFACE)),
    linc_us4_port_native:eth(?INTERFACE),
    ?assert(meck:validate(epcap)).

epcap_verbose_start() ->
    application:set_env(epcap, verbose, true),
    expect_epcap_start_options(?EPCAP_VERBOSE_START_OPTS(?INTERFACE)),
    linc_us4_port_native:eth(?INTERFACE),
    ?assert(meck:validate(epcap)).

epcap_unknown_verbose_value_start() ->
    application:set_env(epcap, verbose, dummy),
    epcap_normal_start().

epcap_stats_interval_start() ->
    application:set_env(epcap, stats_interval, ?PRINTING_STATS_INTERVAL_IN_SEC),
    expect_epcap_start_options(
      ?EPCAP_STATS_INTERVAL_START_OPTS(?INTERFACE,
                                       ?PRINTING_STATS_INTERVAL_IN_SEC)),
    linc_us4_port_native:eth(?INTERFACE),
    ?assert(meck:validate(epcap)).

epcap_unknown_stats_interval_start() ->
    application:set_env(epcap, stast_interval, dummy),
    epcap_normal_start().

epcap_custom_buffer_size_start() ->
    application:set_env(epcap, buffer_size, ?CUSTOM_BUFFER_SIZE),
    expect_epcap_start_options(
      ?EPCAP_CUSTOM_BUFFER_SIZE_START_OPTS(?INTERFACE, ?CUSTOM_BUFFER_SIZE)),
    linc_us4_port_native:eth(?INTERFACE),
    ?assert(meck:validate(epcap)).

epcap_unknown_custom_buffer_value_start() ->
    application:set_env(epcap, buffer_size, dummy),
    epcap_normal_start().

%% Fixtures --------------------------------------------------------------------

epcap_start_setup() ->
    mock(?MOCKED).

epcap_start_teardown(_) ->
    unmock(?MOCKED).

%% Helpers ---------------------------------------------------------------------

expect_epcap_start_options(ExpectedOptions) ->
    meck:expect(epcap, start,
                fun(ActualOpts) ->
                        [?assert(hasOptionSet(ActualOpts, Option))
                         || Option <- ExpectedOptions],
                        {ok, list_to_pid("<0.0.1>")}
                end).

hasOptionSet(OptionsList, Option) ->
    lists:member(Option, OptionsList).
