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
%% @author Krzysztof Rutka <krzysztof.rutka@erlang-solutions.com>
%% @copyright 2012 FlowForwarding.org
%% @doc OF-Config configuration module.
-module(linc_ofconfig).

-behaviour(gen_server).
-behaviour(gen_netconf).

%% Internal API
-export([start_link/0]).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

%% gen_netconf callbacks
-export([handle_get_config/3,
         handle_edit_config/3,
         handle_copy_config/3,
         handle_delete_config/2,
         handle_lock/2,
         handle_unlock/2,
         handle_get/2]).

-include_lib("of_config/include/of_config.hrl").

-record(ofconfig, {
          name = running :: running | startup | candidate,
          config :: #capable_switch{}
         }).

-record(state, {}).

%%------------------------------------------------------------------------------
%% Internal API functions
%%------------------------------------------------------------------------------

%% @private
-spec start_link() -> {ok, pid()} | ignore | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%%------------------------------------------------------------------------------
%% gen_server callbacks
%%------------------------------------------------------------------------------

%% @private
init([]) ->
    mnesia:change_table_copy_type(schema, node(), disc_copies),

    TabDef = [{attributes, record_info(fields, ofconfig)},
              {record_name, ofconfig},
              {disc_copies, [node()]}],
    mnesia:create_table(?MODULE, TabDef),

    mnesia:wait_for_tables([?MODULE], 5000),

    Startup = init_or_update_startup(),
    overwrite_running_and_candidate(Startup),

    {ok, #state{}}.

%% @private
handle_call(_Request, _From, State) ->
    {reply, ok, State}.

%% @private
handle_cast(_Msg, State) ->
    {noreply, State}.

%% @private
handle_info(_Info, State) ->
    {noreply, State}.

%% @private
terminate(_Reason, _State) ->
    ok.

%% @private
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%------------------------------------------------------------------------------
%% gen_netconf callbacks
%%------------------------------------------------------------------------------

%% @private
handle_get_config(_SessionId, _Source, _Filter) ->
    {ok, "<capable-switch/>"}.

%% @private
handle_edit_config(_SessionId, _Target, _Config) ->
    ok.

%% @private
handle_copy_config(_SessionId, _Source, _Target) ->
    ok.

%% @private
handle_delete_config(_SessionId, _Config) ->
    ok.

%% @private
handle_lock(_SessionId, _Config) ->
    ok.

%% @private
handle_unlock(_SessionId, _Config) ->
    ok.

%% @private
handle_get(_SessionId, _Filter) ->
    {ok, "<capable-switch/>"}.

%%------------------------------------------------------------------------------
%% Helper functions
%%------------------------------------------------------------------------------

%% @private
init_or_update_startup() ->
    case mnesia:dirty_read(?MODULE, startup) of
        [] ->
            InitialConfig = #ofconfig{name = startup,
                                      config = init_configuration()},
            mnesia:dirty_write(?MODULE, InitialConfig),
            InitialConfig;
        [Startup] ->
            %% TODO: Update startup configuration with setting from sys.config
            NewStartup = update_startup(Startup),
            mnesia:dirty_write(?MODULE, NewStartup),
            NewStartup
    end.

%% @private
update_startup(#ofconfig{config = Config} = Startup) ->
    Startup#ofconfig{config = Config}.

%% @private
overwrite_running_and_candidate(#ofconfig{config = Startup}) ->
    Running = #ofconfig{name = running,
                        config = Startup},
    mnesia:dirty_write(?MODULE, Running),

    Candidate = #ofconfig{name = candidate,
                          config = Startup},
    mnesia:dirty_write(?MODULE, Candidate).

%% @private
init_configuration() ->
    #capable_switch{id = "CapableSwitch0",
                    configuration_points = [],
                    resources = get_ports() ++ get_queues() ++
                        get_certificates() ++ get_flow_tables(),
                    logical_switches = get_logical_switches()}.

%% @private
get_ports() ->
    %% TODO: Get current port configuration.
    %% Configuration = #port_configuration{admin_state = up,
    %%                                     no_receive = false,
    %%                                     no_forward = false,
    %%                                     no_packet_in = false},
    %% State = #port_state{oper_state = up,
    %%                     blocked = false,
    %%                     live = false},
    %% Feature = #features{rate = '10Mb-FD',
    %%                     auto_negotiate = enabled,
    %%                     medium = copper,
    %%                     pause = symmetric},
    %% Features = #port_features{current = Feature,
    %%                           advertised = Feature,
    %%                           supported = Feature,
    %%                           advertised_peer = Feature},
    %% #port{resource_id = "Port214748364",
    %%       number = 214748364,
    %%       name = "name0",
    %%       current_rate = 10000,
    %%       max_rate = 10000,
    %%       configuration = Configuration,
    %%       state = State,
    %%       features = Features,
    %%       tunnel = undefined},
    [].

%% @private
get_queues() ->
    %% TODO: Get current queue configuration.
    %% Properties = #queue_properties{min_rate = 10,
    %%                                max_rate = 500,
    %%                                experimenters = [123498,708]},
    %% #queue{resource_id = "Queue2",
    %%        id = 2,
    %%        port = 4,
    %%        properties = Properties},
    [].

%% @private
get_certificates() ->
    %% TODO: Get certificate configuration.
    %% PrivateKey = #private_key_rsa{
    %%   modulus = "AEF134F56EDB667DFA4320AEF134F56EDB667DFA4320",
    %%   exponent = "DFA4320AEF134F56EDB6SSS"},
    %% #certificate{resource_id = "ownedCertificate3",
    %%              type = owned,
    %%              certificate =
    %%                  "AEF134F56EDB667DFA4320AEF134F56EDB667DFA4320",
    %%              private_key = PrivateKey},
    %% #certificate{resource_id = "externalCertificate2",
    %%              type = external,
    %%              certificate =
    %%                  "AEF134F56EDB667DFA4320AEF134F56EDB667DFA4320",
    %%              private_key = undefined},
    [].

%% @private
get_flow_tables() ->
    %% TODO: Generate supported flow table list.
    %% #flow_table{resource_id = "flowtable1",
    %%             max_entries = 255,
    %%             next_tables = [2, 3, 4, 5],
    %%             instructions = ['apply-actions'],
    %%             matches = ['input-port'],
    %%             write_actions = [output],
    %%             apply_actions = [output],
    %%             write_setfields = ['ethernet-dest'],
    %%             apply_setfields = ['ethernet-dest'],
    %%             wildcards = ['udp-dest'],
    %%             metadata_match = 30,
    %%             metadata_write = 30},
    [].

%% @private
get_logical_switches() ->
    %% TODO: Get logical switch configuration.
    %% Capabilities = #capabilities{max_buffered_packets = 0,
    %%                              max_tables = 1024,
    %%                              max_ports = 2048,
    %%                              flow_statistics = true,
    %%                              table_statistics = true,
    %%                              port_statistics = true,
    %%                              group_statistics = true,
    %%                              queue_statistics = true,
    %%                              reassemble_ip_fragments = false,
    %%                              block_looping_ports = false,
    %%                              reserved_port_types = [all],
    %%                              group_types = [all, indirect],
    %%                              group_capabilities = ['select-weight'],
    %%                              action_types = [output],
    %%                              instruction_types = ['write-actions']},
    %% [#logical_switch{id = "LogicalSwitch0",
    %%                  datapath_id = "datapath-id0",
    %%                  enabled = true,
    %%                  check_controller_certificate = false,
    %%                  lost_connection_behavior = failSecureMode,
    %%                  capabilities = Capabilities,
    %%                  controllers = [],
    %%                  resources = [{port,"port2"},
    %%                               {port,"port3"},
    %%                               {queue,"queue0"},
    %%                               {queue,"queue1"},
    %%                               {certificate,"ownedCertificate4"},
    %%                               {flow_table,1},
    %%                               {flow_table,2}]}],
    [].
