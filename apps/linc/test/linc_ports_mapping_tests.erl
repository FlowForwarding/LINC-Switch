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
-module(linc_ports_mapping_tests).

-include_lib("eunit/include/eunit.hrl").

-define(SPAWN(Tests), [{spawn, T} || T <- Tests]).

-define(LOGICAL_SW_CFG,
        [{switch, 1, [{ports, [{port, 1, {queues, []}},
                               {port, 2, [{queues, []}, {port_no, 20}]}
                              ]}]}]).

-define(INCORRECT_LOGICAL_SW_CFGS,
        [
         {{bad_port_config, duplicated_capable_port_no},
          [{switch, 1, [{ports, [{port, 1, {queues, []}},
                                 {port, 1, [{queues, []}, {port_no, 20}]}
                                ]}]}]},
         {{bad_port_config, duplicated_logical_port_no},
          [{switch, 1, [{ports, [{port, 1, [{queues, []},{port_no, 20}]},
                                 {port, 2, [{queues, []}, {port_no, 20}]}
                                ]}]}]
         }]).

%% Generators ------------------------------------------------------------------

port_mapping_initialization_test_() ->
    ?SPAWN(
       [{"Correct initialization",
         fun port_mapping_should_intialize_correctly/0},
        {"Failed initialization",
         fun port_mapping_initialization_should_crash/0}]).

port_mapping_test_() ->
    {setup,
     fun port_mapping_setup/0,
     fun port_mapping_teardown/1,
     ?SPAWN([{"Correct capable switch ports mappings",
              fun capable_port_should_be_mapped_correctly/0},
             {"Correct logical switch ports mappings",
              fun logical_port_should_be_mapped_correctly/0}])}.

%% Tests -----------------------------------------------------------------------

port_mapping_should_intialize_correctly() ->
    ?assertEqual(ok, linc_ports_mapping:initialize(?LOGICAL_SW_CFG)).

port_mapping_initialization_should_crash() ->
    [?assertThrow(ExpectedException,
                  linc_ports_mapping:initialize(Ports))
     || {ExpectedException, Ports} <- ?INCORRECT_LOGICAL_SW_CFGS].

capable_port_should_be_mapped_correctly() ->
    ?assertEqual(2, linc_ports_mapping:get_capable_switch_port(1,20)),
    ?assertEqual(not_found, linc_ports_mapping:get_capable_switch_port(1,22)),
    ?assertEqual(not_found, linc_ports_mapping:get_capable_switch_port(2,20)).

logical_port_should_be_mapped_correctly() ->
    ?assertEqual({1, 20}, linc_ports_mapping:get_logical_switch_port(2)),
    ?assertEqual(not_found, linc_ports_mapping:get_logical_switch_port(3)).

%% Fixtures --------------------------------------------------------------------

port_mapping_setup() ->
    linc_ports_mapping:initialize(?LOGICAL_SW_CFG).

port_mapping_teardown(_) ->
    linc_ports_mapping:terminate().


