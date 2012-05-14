The gen\_switch behaviour
======================

The `gen_switch` is a behaviour that defines set of callbacks that one has to
provide in order to implement the switch. Currently there is only one
implementation of `gen_switch` behaviour – `ofs_userspace` which is a purely
userspace, Erlang implementation of switch. One can think of various other
backends to implement, like:

 * hardware based switch,
 * userspace implementation in other programming language (like C),
 * interfacing with openvswitch.ko Linux kernel module.

Callbacks
---------

`gen_switch` consists of the following callbacks:

   * `start/1`
   * `stop/1`
   * `ofp_flow_mod/2`
   * `ofp_table_mod/2`
   * `ofp_port_mod/2`
   * `ofp_group_mod/2`
   * `ofp_packet_out/2`
   * `ofp_echo_request/2`
   * `ofp_barrier_request/2`
   * `ofp_desc_stats_request/2`
   * `ofp_flow_stats_request/2`
   * `ofp_aggregate_stats_request/2`
   * `ofp_table_stats_request/2`
   * `ofp_port_stats_request/2`
   * `ofp_queue_stats_request/2`
   * `ofp_group_stats_request/2`
   * `ofp_group_desc_stats_request/2`
   * `ofp_group_features_stats_request/2`

Specs for the callbacks are in the [gen\_switch.erl](../apps/of_switch/src/gen_switch.erl) file.

The `start` function takes a single argument of backend-specific type and
returns `{ok, State}` tuple. The `stop` function takes State as an argument,
it's return value is ignored.

All the callbacks whose names start with `ofp_` are called when approperiate packet
is received. Thay all have similar API: they take two arguments – state and packet
and, on success, return either `{ok, NewState}` or `{ok, Reply, NewState}` function,
depending on if the packet is one that requires response or not. In case of failure
those callbacks can either return `{error, OfpError, NewState}` tuple, or throw
`#ofp_error{}` record. In the latter case the state stays unchanged. In both cases
the error is delivered to the sender.

Notes
-----

One thing to note is that implementation of `ofp_flow_mod` should only modify
flow. If it contains packet to be sent, upper layers will call backend's
`ofp_packet_out` callback.

There is no support for experimenter messages yet.
