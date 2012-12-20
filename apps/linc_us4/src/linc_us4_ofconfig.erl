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
%% @doc OF-Config configuration module.
-module(linc_us4_ofconfig).

-behaviour(gen_server).
-behaviour(gen_netconf).

%% Internal API
-export([start/0,
         start_link/0,
         stop/0]).

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

-include_lib("of_protocol/include/of_protocol.hrl").
-include_lib("of_protocol/include/ofp_v4.hrl").
-include_lib("of_config/include/of_config.hrl").
-include_lib("linc/include/linc_logger.hrl").
-include("linc_us4.hrl").

-record(ofconfig, {
          name = running :: running | startup | candidate,
          config :: #capable_switch{}
         }).

-record(state, {}).

%%------------------------------------------------------------------------------
%% Internal API functions
%%------------------------------------------------------------------------------

start() ->
    OFConfig = {linc_us4_ofconfig, {linc_us4_ofconfig, start_link, []},
                transient, 50, worker, [linc_us4_ofconfig]},
    supervisor:start_child(linc_us4_sup, OFConfig).

stop() ->
    ok.

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
handle_call({get_config, _SessionId, Source, _Filter}, _From, State) ->
    [#ofconfig{config = Config}] = mnesia:dirty_read(?MODULE, Source),
    EncodedConfig = of_config:encode(Config),
    {reply, {ok, EncodedConfig}, State};
handle_call({edit_config, _SessionId, running, {xml, Config}}, _From, State) ->
    Decoded = of_config:decode(Config),

    [Switch0] = Decoded#capable_switch.logical_switches,
    Controllers = Switch0#logical_switch.controllers,
    [add_controller(running, Ctrl) || Ctrl <- Controllers],

    {reply, ok, State};
handle_call(_, _, State) ->
    {reply, {error, {operation_failed, application}}, State}.

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
handle_get_config(SessionId, Source, Filter) ->
    gen_server:call(?MODULE,
                    {get_config, SessionId, Source, Filter}, infinity).

%% @private
handle_edit_config(SessionId, Target, Config) ->
    gen_server:call(?MODULE,
                    {edit_config, SessionId, Target, Config}, infinity).

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
    %% [#flow_table{resource_id = "FlowTable" ++ integer_to_list(I),
    %%              max_entries = ?MAX_FLOW_TABLE_ENTRIES,
    %%              next_tables = lists:seq(I + 1, ?OFPTT_MAX),
    %%              instructions = instructions(?SUPPORTED_INSTRUCTIONS),
    %%              matches = fields(?SUPPORTED_MATCH_FIELDS),
    %%              write_actions = actions(?SUPPORTED_WRITE_ACTIONS),
    %%              apply_actions = actions(?SUPPORTED_APPLY_ACTIONS),
    %%              write_setfields = fields(?SUPPORTED_WRITE_SETFIELDS),
    %%              apply_setfields = fields(?SUPPORTED_APPLY_SETFIELDS),
    %%              wildcards = fields(?SUPPORTED_WILDCARDS),
    %%              metadata_match = 16#ffff,
    %%              metadata_write = 16#ffff}
    %%  || I <- lists:seq(0, ?OFPTT_MAX)].
    [].

%% @private
get_logical_switches() ->
    %% FIXME: Hardcoded single logical switch instance.
    Caps = #capabilities{max_buffered_packets = ?MAX_BUFFERED_PACKETS,
                         max_tables = ?MAX_TABLES,
                         max_ports = ?MAX_PORTS,
                         flow_statistics = true,
                         table_statistics = true,
                         port_statistics = true,
                         group_statistics = true,
                         queue_statistics = true,
                         reassemble_ip_fragments = false,
                         block_looping_ports = false,
                         reserved_port_types = ?SUPPORTED_RESERVED_PORTS,
                         group_types =
                             group_types(?SUPPORTED_GROUP_TYPES),
                         group_capabilities =
                             group_caps(?SUPPORTED_GROUP_CAPABILITIES),
                         action_types = actions(?SUPPORTED_WRITE_ACTIONS),
                         instruction_types =
                             instructions(?SUPPORTED_INSTRUCTIONS)},
    %% FlowTables = [{flow_table, "FlowTable" ++ integer_to_list(I)}
    %%               || I <- lists:seq(0, ?OFPTT_MAX)],
    FlowTables = [],
    [#logical_switch{id = "LogicalSwitch0",
                     datapath_id = "00:00:00:00:00:00:00:00",
                     enabled = true,
                     check_controller_certificate = false,
                     lost_connection_behavior = failSecureMode,
                     capabilities = Caps,
                     controllers = [],
                     resources = FlowTables}].

%%------------------------------------------------------------------------------
%% Helper conversion functions
%%------------------------------------------------------------------------------

%% @private
instructions(Instructions) ->
    instructions(Instructions, []).

%% @private
instructions([], Instructions) ->
    lists:reverse(Instructions);
instructions([meter | Rest], Instructions) ->
    instructions(Rest, ['meter' | Instructions]);
instructions([apply_actions | Rest], Instructions) ->
    instructions(Rest, ['apply-actions' | Instructions]);
instructions([clear_actions | Rest], Instructions) ->
    instructions(Rest, ['clear-actions' | Instructions]);
instructions([write_actions | Rest], Instructions) ->
    instructions(Rest, ['write-actions' | Instructions]);
instructions([write_metadata | Rest], Instructions) ->
    instructions(Rest, ['write-metadata' | Instructions]);
instructions([goto_table | Rest], Instructions) ->
    instructions(Rest, ['goto-table' | Instructions]).

%% @private
%% fields(Fields) ->
%%     fields(Fields, []).

%% @private
%% fields([], Fields) ->
%%     lists:reverse(Fields);
%% fields([in_port | Rest], Fields) ->
%%     fields(Rest, ['input-port' | Fields]);
%% fields([in_phy_port | Rest], Fields) ->
%%     fields(Rest, ['physical-input-port' | Fields]);
%% fields([metadata | Rest], Fields) ->
%%     fields(Rest, ['metadata' | Fields]);
%% fields([eth_dst | Rest], Fields) ->
%%     fields(Rest, ['ethernet-dest' | Fields]);
%% fields([eth_src | Rest], Fields) ->
%%     fields(Rest, ['ethernet-src' | Fields]);
%% fields([eth_type | Rest], Fields) ->
%%     fields(Rest, ['ethernet-frame-type' | Fields]);
%% fields([vlan_vid | Rest], Fields) ->
%%     fields(Rest, ['vlan-id' | Fields]);
%% fields([vlan_pcp | Rest], Fields) ->
%%     fields(Rest, ['vlan-priority' | Fields]);
%% fields([ip_dscp | Rest], Fields) ->
%%     fields(Rest, ['ip-dscp' | Fields]);
%% fields([ip_ecn | Rest], Fields) ->
%%     fields(Rest, ['ip-ecn' | Fields]);
%% fields([ip_proto | Rest], Fields) ->
%%     fields(Rest, ['ip-protocol' | Fields]);
%% fields([ipv4_src | Rest], Fields) ->
%%     fields(Rest, ['ipv4-src' | Fields]);
%% fields([ipv4_dst | Rest], Fields) ->
%%     fields(Rest, ['ipv4-dest' | Fields]);
%% fields([tcp_src | Rest], Fields) ->
%%     fields(Rest, ['tcp-src' | Fields]);
%% fields([tcp_dst | Rest], Fields) ->
%%     fields(Rest, ['tcp-dest' | Fields]);
%% fields([udp_src | Rest], Fields) ->
%%     fields(Rest, ['udp-src' | Fields]);
%% fields([udp_dst | Rest], Fields) ->
%%     fields(Rest, ['udp-dest' | Fields]);
%% fields([sctp_src | Rest], Fields) ->
%%     fields(Rest, ['sctp-src' | Fields]);
%% fields([sctp_dst | Rest], Fields) ->
%%     fields(Rest, ['sctp-dest' | Fields]);
%% fields([icmpv4_type | Rest], Fields) ->
%%     fields(Rest, ['icmpv4-type' | Fields]);
%% fields([icmpv4_code | Rest], Fields) ->
%%     fields(Rest, ['icmpv4-code' | Fields]);
%% fields([arp_op | Rest], Fields) ->
%%     fields(Rest, ['arp-op' | Fields]);
%% fields([arp_spa | Rest], Fields) ->
%%     fields(Rest, ['arp-src-ip-address' | Fields]);
%% fields([arp_tpa | Rest], Fields) ->
%%     fields(Rest, ['arp-target-ip-address' | Fields]);
%% fields([arp_sha | Rest], Fields) ->
%%     fields(Rest, ['arp-src-hardware-address' | Fields]);
%% fields([arp_tha | Rest], Fields) ->
%%     fields(Rest, ['arp-target-hardware-address' | Fields]);
%% fields([ipv6_src | Rest], Fields) ->
%%     fields(Rest, ['ipv6-src' | Fields]);
%% fields([ipv6_dst | Rest], Fields) ->
%%     fields(Rest, ['ipv6-dest' | Fields]);
%% fields([ipv6_flabel | Rest], Fields) ->
%%     fields(Rest, ['ipv6-flow-label' | Fields]);
%% fields([icmpv6_type | Rest], Fields) ->
%%     fields(Rest, ['icmpv6-type' | Fields]);
%% fields([icmpv6_code | Rest], Fields) ->
%%     fields(Rest, ['icmpv6-code' | Fields]);
%% fields([ipv6_nd_target | Rest], Fields) ->
%%     fields(Rest, ['ipv6-nd-target' | Fields]);
%% fields([ipv6_nd_sll | Rest], Fields) ->
%%     fields(Rest, ['ipv6-nd-source-link-layer' | Fields]);
%% fields([ipv6_nd_tll | Rest], Fields) ->
%%     fields(Rest, ['ipv6-nd-target-link-layer' | Fields]);
%% fields([mpls_label | Rest], Fields) ->
%%     fields(Rest, ['mpls-label' | Fields]);
%% fields([mpls_tc | Rest], Fields) ->
%%     fields(Rest, ['mpls-tc' | Fields]).

%% @private
actions(Actions) ->
    actions(Actions, []).

%% @private
actions([], Actions) ->
    lists:reverse(Actions);
actions([output | Rest], Actions) ->
    actions(Rest, [output | Actions]);
actions([copy_ttl_out | Rest], Actions) ->
    actions(Rest, ['copy-ttl-out' | Actions]);
actions([copy_ttl_in | Rest], Actions) ->
    actions(Rest, ['copy-ttl-in' | Actions]);
actions([set_mpls_ttl | Rest], Actions) ->
    actions(Rest, ['set-mpls-ttl' | Actions]);
actions([dec_mpls_ttl | Rest], Actions) ->
    actions(Rest, ['dec-mpls-ttl' | Actions]);
actions([push_vlan | Rest], Actions) ->
    actions(Rest, ['push-vlan' | Actions]);
actions([pop_vlan | Rest], Actions) ->
    actions(Rest, ['pop-vlan' | Actions]);
actions([push_mpls | Rest], Actions) ->
    actions(Rest, ['push-mpls' | Actions]);
actions([pop_mpls | Rest], Actions) ->
    actions(Rest, ['pop-mpls' | Actions]);
actions([push_pbb | Rest], Actions) ->
    actions(Rest, ['push-pbb' | Actions]);
actions([pop_pbb | Rest], Actions) ->
    actions(Rest, ['pop-pbb' | Actions]);
actions([set_queue | Rest], Actions) ->
    actions(Rest, ['set-queue' | Actions]);
actions([group | Rest], Actions) ->
    actions(Rest, [group | Actions]);
actions([set_nw_ttl | Rest], Actions) ->
    actions(Rest, ['set-nw-ttl' | Actions]);
actions([dec_nw_ttl | Rest], Actions) ->
    actions(Rest, ['dec-nw-ttl' | Actions]);
actions([set_field | Rest], Actions) ->
    actions(Rest, ['set-field' | Actions]).

%% @private
group_types(Types) ->
    group_types(Types, []).

%% @private
group_types([], Types) ->
    lists:reverse(Types);
group_types([all | Rest], Types) ->
    group_types(Rest, [all | Types]);
group_types([select | Rest], Types) ->
    group_types(Rest, [select | Types]);
group_types([indirect | Rest], Types) ->
    group_types(Rest, [indirect | Types]);
group_types([ff | Rest], Types) ->
    group_types(Rest, ['fast-failover' | Types]).

%% @private
group_caps(Capabilities) ->
    group_caps(Capabilities, []).

%% @private
group_caps([], Capabilities) ->
    lists:reverse(Capabilities);
group_caps([select_weight | Rest], Capabilities) ->
    group_caps(Rest, ['select-weight' | Capabilities]);
group_caps([select_liveness | Rest], Capabilities) ->
    group_caps(Rest, ['select_liveness' | Capabilities]);
group_caps([chaining | Rest], Capabilities) ->
    group_caps(Rest, [chaining | Capabilities]);
group_caps([chaining_check | Rest], Capabilities) ->
    group_caps(Rest, ['chaining-check' | Capabilities]).

%% @private
add_controller(Target, Controller) ->
    [#ofconfig{config = Config}] = mnesia:dirty_read(?MODULE, Target),

    State = #controller_state{connection_state = up,
                              current_version = undefined,
                              supported_versions = []},
    NewCtrl = Controller#controller{role = equal,
                                    local_ip_address = undefined,
                                    local_port = undefined,
                                    state = State},

    IP = Controller#controller.ip_address,
    Port = Controller#controller.port,
    linc_receiver_sup:open(IP, Port),

    [Switch0] = Config#capable_switch.logical_switches,
    Controllers = Switch0#logical_switch.controllers,
    NewControllers = [NewCtrl | Controllers],
    NewSwitch = Switch0#logical_switch{controllers = NewControllers},

    NewConfig = Config#capable_switch{logical_switches = [NewSwitch]},

    mnesia:dirty_write(?MODULE, #ofconfig{name = Target,
                                          config = NewConfig}).
