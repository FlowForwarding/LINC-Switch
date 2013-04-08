The gen_switch behaviour
======================

The `gen_switch` is a behaviour that defines set of callbacks that one has to
provide in order to implement the switch. Currently there are
two implementations of `gen_switch` behaviour: 

  * `linc_us3` which is a purely userspace, Erlang implementation of an OFP 1.2 switch
  * `linc_us4` which is a purely userspace, Erlang implementation of an OFP 1.3 switch

One can think of various other backends to implement, like:

 * hardware based switch,
 * userspace implementation in other programming language (like C),
 * interfacing with openvswitch.ko Linux kernel module.

Callbacks
---------

`gen_switch` consists of the following callbacks:

 * `start/2`
 * `stop/1`
 * `handle_message/2`

Specs for the callbacks are in the [gen\_switch.erl](../apps/linc/src/gen_switch.erl) file.

The `start` function takes a single argument of backend-specific type and
returns `{ok, State}` tuple. The `stop` function takes State as an argument,
it's return value is ignored.

The `handle_message` callback is called when a packet is received. It takes two
arguments – state and packet and, on success, return either `{ok, NewState}` or
`{ok, Reply, NewState}` depending on if the packet is one that requires response or not.
In case of failure the callback can either return `{error, OfpError, NewState}` tuple,
or throw `#ofp_error{}` record. In the latter case the state stays unchanged. In both cases
the error is delivered to the sender.
