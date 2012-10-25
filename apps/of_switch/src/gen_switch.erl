%%%-----------------------------------------------------------------------------
%%% Use is subject to License terms.
%%% @copyright (C) 2012 FlowForwarding.org
%%% @doc OpenFlow Switch behaviour.
%%% Specifies set of callback functions that must be implemented by the switch
%%% backend:
%%%
%%% start/1 - Start the switch.<br/>
%%% stop/1 - Stop the switch.<br/>
%%% ofp_flow_mod/2 - Modify flow entry in the flow table.<br/>
%%% ofp_table_mod/2 - Modify flow table configuration.<br/>
%%% ofp_port_mod/2 - Modify port configuration.<br/>
%%% ofp_group_mod/2 - Modify group entry in the group table.<br/>
%%% ofp_packet_out/2 - Send packet to controller<br/>
%%% ofp_echo_request/2 - Reply to echo request.<br/>
%%% ofp_barrier_request/2 - Reply to barrier request.<br/>
%%% ofp_desc_stats_request/2 - Get switch description statistics.<br/>
%%% ofp_flow_stats_request/2 - Get flow entry statistics.<br/>
%%% ofp_aggregate_stats_request/2 - Get aggregated flow statistics.<br/>
%%% ofp_table_stats_request/2 - Get flow table statistics.<br/>
%%% ofp_port_stats_request - Get port statistics.<br/>
%%% ofp_queue_stats_request/2 - Get queue statistics.<br/>
%%% ofp_group_stats_request/2 -  Get group statistics.<br/>
%%% ofp_group_desc_stats_request/2 - Get group description statistics.<br/>
%%% ofp_group_features_stats_request/2 -  Get group features statistics.<br/>
%%% @end
%%%-----------------------------------------------------------------------------
-module(gen_switch).
-author("Erlang Solutions Ltd. <openflow@erlang-solutions.com>").

-include_lib("of_protocol/include/of_protocol.hrl").

%% Start the switch.
-callback start(Args :: term()) ->
    {ok, State :: term()}.

%% Stop the switch.
-callback stop(State :: term()) ->
    term().

%% Handle all message types supported by the given OFP version.
-callback handle_message(State :: term(), ofp_message()) ->
    {ok, NewState :: term()} |
    {error, term(), NewState :: term()}.
