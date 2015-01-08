# LINC-OE: LINC-Switch for optical emulation #

LINC-Switch provides a backend that emulates optical multiplexer -
so called [ROADM (Reconfigurable optical add-drop multiplexer)][ROADM].
This backend is available for OpenFlow v. 1.3.2. Each such multiplexer
is run as logical switch within LINC-Switch container. When
LINC-Switch is configured with this backend it is called LINC-OE,
for "LINC Switch for optical emulation".

This document shows how to use LINC-Switch to simulate simple optical
network like on the diagram below:

```
           |       (1)       |      |      (2)       |      |       (3)       |
[tap0]-----|[1]  <PO-SW>  [2]|~~~~~~|[1]  <O-SW>  [2]|~~~~~~|[1]  <PO-SW>  [2]|-----[tap1]
 (OS)      |     (LINC)      |      |     (LINC)     |      |      (LINC)     |      (OS)

```

> * (X) - is the logical switch number
> * PO-SW - indicates packet-optical logical switch (i.e. a switch that
> has Ethernet ports as well as optical ones)
> * O-SW - indicates optical switch (i.e. a switch that has only internally
> emulated optical ports and links between them)
> * [tapX] - is the operating system tap interface number X
> * ---- line is the packet link
> * ~~~~ line is the optical link

## Operating system configuration ##

To run the simulation two tap interfaces are required. Following commands
show how to configure them in Linux:
```shell
sudo tunctl -t tap0
sudo tunctl -t tap1
sudo ip link set dev tap0 up
sudo ip link set dev tap1 up
```

## LINC-OE configuration ##

`rel/files/sys.config` file for the network shown above should looks
as following:
```erlang
[{linc,
  [{of_config,disabled},
   {capable_switch_ports,
    [{port,1,[{interface,"tap0"}]},
     {port,2,[{interface,"dummy"}, {type, optical}]},
     {port,3,[{interface,"dummy"}, {type, optical}]},
     {port,4,[{interface,"dummy"}, {type, optical}]},
     {port,5,[{interface,"dummy"}, {type, optical}]},
     {port,6,[{interface,"tap1"}]}
    ]},
   {capable_switch_queues, []},
   {optical_links, [{{1,2}, {2,1}}, {{2,2},{3,1}}]},
   {logical_switches,
    [{switch,1,
      [{backend,linc_us4_oe},
       {controllers,[{"Switch0-Controller","localhost",6653,tcp}]},
       {controllers_listener,disabled},
       {queues_status,disabled},
       {datapath_id, "00:00:00:00:00:01:00:01"},
       {ports,[{port,1,[{queues,[]}, {port_no, 1}]},
               {port,2,[{queues,[]}, {port_no, 2}]}
              ]}]},
     {switch,2,
      [{backend,linc_us4_oe},
       {controllers,[{"Switch0-Controller","localhost",6653,tcp}]},
       {controllers_listener,disabled},
       {queues_status,disabled},
       {datapath_id, "00:00:00:00:00:01:00:02"},
       {ports,[{port,3,[{queues,[]}, {port_no, 1}]},
               {port,4,[{queues,[]}, {port_no, 2}]}
              ]}]},
     {switch,3,
      [{backend,linc_us4_oe},
       {controllers,[{"Switch0-Controller","localhost",6653,tcp}]},
       {controllers_listener,disabled},
       {queues_status,disabled},
       {datapath_id, "00:00:00:00:00:01:00:03"},
       {ports,[{port,5,[{queues,[]}, {port_no, 1}]},
               {port,6,[{queues,[]}, {port_no, 2}]}
              ]}]}
    ]}]},
 {of_protocol, [{no_multipart, false}]},
 {enetconf,
  [{capabilities,[{base,{1,1}},{startup,{1,0}},{'writable-running',{1,0}}]},
   {callback_module,linc_ofconfig},
   {sshd_ip,any},
   {sshd_port,1830},
   {sshd_user_passwords,[{"linc","linc"}]}]},
 {epcap,
  [{verbose, false},
   {stats_interval, 10},
   {buffer_size, 73400320}]},
 {lager,
  [{handlers,
    [{lager_console_backend,debug},
     {lager_file_backend,
      [{"log/error.log",error,10485760,"$D0",5},
       {"log/debug.log",debug,10485760,"$D0",5},
       {"log/console.log",info,10485760,"$D0",5}]}]}]},
 {sasl,
  [{sasl_error_logger,{file,"log/sasl-error.log"}},
   {errlog_type,error},
   {error_logger_mf_dir,"log/sasl"},
   {error_logger_mf_maxbytes,1048576000000},
   {error_logger_mf_maxfiles,5}]},
 {sync,
  [{excluded_modules, [procket]}]}].
```

* The tuple `capable_switch_ports` lists all the ports that are
present in the LINC-Container and the ones that are to emulate optical
ports are marked appropriately.

* `optical_links` is a list describing  how optical ports will be connected
to each other. Each element of this list has
the following format:
```{LOGICAL_SWITCH_A, PORT_A}, {LOGICAL_SWITCH_B, PORT_B}```

* `linc_us4_oe` backend has to be set to enable the optical extension.

* Each logical switch has different `datapath_id` set to be distinguished
by a controller.

* Ports 1 and 6 are attached to operating system tap ports.

* The `no_multipart` flag allows to disable splitting OF messages.

* The config can be also generated using [LINC Configuration generator][config_generator].

## Starting LINC-OE ##

Build LINC-Switch and run it:  
```$ make rel && sudo rel/linc/bin/linc console```

## Flows Configuration ##

To configure flows on the switch we will use [icontrol][icontrol] application
that is part of [LOOM][loom] controller. Our aim is to setup flows
that will forward traffic from switch 1, through 2, to switch 3. Links
between switch 1 and 2 as well as between 2 and 3 are optical. The
optical signal will be placed on channel no 20
(see [Wavelength-division multiplexing][wdm]).

1. Clone LOOM controller from github and start icontrol application  

    `$ git clone https://github.com/FlowForwarding/loom.git && cd loom/icontrol`  
    `$ make rel && rel/icontrol/bin/icontrol console`
    
2. Make sure 3 logical switches connected to icontrol
   ```erlang
   (icontrol@127.0.0.1)2> iof:switches().
   ```
`Switch-Key` column presents switches numbers in the `icontrol` and
`DatapathId` identifies them in the LINC-Switch. Note that the `Switch­Key`
number may not correspond to the logical switch number.
3. Install a flow on switch 1 that will forward packets from port 1
to the optical link connected to port 2 using wavelength 20
    ```erlang
    (icontrol@127.0.0.1)2> iof:oe_flow_tw(_SwitchKey1 = 2,
                                          _FlowPriority1 = 100,
                                          _InPort1 = 1,
                                          _OutPort1 = 2 ,
                                          _OutWaveLength1 = 20).
    ```
 > In optical networks packet ports are marked as T while optical ones as
 > W. Thus we have a function called `oe_flow_tw` where tw means "from
 > port T to port W".
 
4. Install a flow on switch 2 that will take optical data from channel
20 on port 1 and put it on port 2 into the same channel
    ```erlang
    (icontrol@127.0.0.1)2> iof:oe_flow_ww(_SwitchKey2 = 1,
                                          _FlowPriority2 = 100,
                                          _InPort2 = 1,
                                          _InWavelength2 = 20,
                                          _OutPort2 = 2 ,
                                          _OutWaveLength2 = 20).
    ```
    
5. Install a flow on switch 3 that will take optical data from channel
20 on port 1 and convert it back to packet data and send it through
port 2
    ```erlang
    (icontrol@127.0.0.1)2> iof:oe_flow_wt(_SwitchKey3 = 3,
                                          _FlowPriority3 = 100,
                                          _InPort3 = 1,
                                          _InWavelength3 = 20,
                                          _OutPort3 = 2).
    ```

## Observing the traffic ##

1. Examine the counters of the flow installed on switch no 2
    ```erlang
    (icontrol@127.0.0.1)12> iof:flows(SwitchKey).
    ```  
In the response from controller the two numbers between a flow cookie
and `ofp_match` indicate packet count and byte count appropriately:
    ```erlang
    {ofp_flow_stats_reply,[],
        [{ofp_flow_stats,0,57,498711000,100,0,0,[],
             <<0,0,0,0,0,0,0,10>>,
             0,0,  % <--------- packet and byte counters of the flow entry
             {ofp_match,
                 [{ofp_field,openflow_basic,in_port,false,<<0,0,0,1>>,undefined},
                  {ofp_field,infoblox,och_sigtype,false,<<"\n">>,undefined},
                  {ofp_field,infoblox,och_sigid,false, <<0,0,0,23,0,0>>, undefined}]},
             [{ofp_instruction_apply_actions,2,
                  [{ofp_action_output,16,2,no_buffer}]}]}]}

    ```
2. Start Wireshark/tcpdump on port tap1
3. Send ping through tap0  

    `$ sudo tcpreplay -i tap0 LINC-Switch/pcap.data/ping.pcap`

4. In the Wireshark verify that the packet got to the other end and
check the flows stats once again.

[ROADM]: http://en.wikipedia.org/wiki/Reconfigurable_optical_add-drop_multiplexer
[icontrol]: https://github.com/FlowForwarding/loom/tree/master/icontrol
[loom]: https://github.com/FlowForwarding/loom
[wdm]: http://en.wikipedia.org/wiki/Wavelength-division_multiplexing
[config_generator]: https://github.com/FlowForwarding/LINC-config-generator
