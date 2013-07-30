# FFController User Guide
_(work in progress)_

The steps needed to use this controller with Linc switch are below.

1. Make and run LINC as user root by doing the following:
```bash
$ make rel
$ $LINC_ROOT/rel/linc/bin/linc console
```
2. To find out switch Dpid, in linc switch console, type
```erlang
>1 linc_logic:get_datapath_id(SwitchId).
```
The output will be like:
```erlang
"00:0C:29:C9:8E:AE:00:00"
```

To check flow_table:
```erlang
>1 linc_us4_flow:get_flow_table(SwitchId,0).
```

3. Run the controller:
```bash
$ java -jar of_controller.jar
```

4. Use rest API to setup flow-entry. Below some instances:

```bash
$ curl -d '{"switch":"00:0C:29:C9:8E:AE:00:00", "name":"flow-mod-1", "priority":"32768", "ingress-port":"1", "active":"true", "actions":"output=1"}' http://localhost:8080/ff/of/controller/restapi

$ curl -d '{"switch":"00:0C:29:C9:8E:AE:00:00", "name":"flow-mod-1", "priority":"32768", "ingress-port":"2","active":"true"}' http://localhost:8080/ff/of/controller/restapi

$ curl -d '{"switch":"00:0C:29:AC:93:43:00:00", "name":"flow-mod-1", "priority":"32768", "ether-type":"0x0800", "active":"true"}' http://localhost:8080/ff/of/controller/restapi

$ curl -d '{"switch":"00:0C:29:AC:93:43:00:00", "name":"flow-mod-1", "priority":"32768", "ether-type":"0x0800", "dst-ip":"10.10.10.10","active":"true"}' http://localhost:8080/ff/of/controller/restapi

$ curl -d '{"switch":"00:90:FB:37:71:6E:00:00", "name":"flow-mod-1", "priority":"10", "ingress-port":"5","active":"true", "actions":"output=6"}' http://localhost:8080/ff/of/controller/restapi

$ curl -d '{"switch":"00:90:FB:37:71:6E:00:00", "name":"flow-mod-1", "priority":"10", "ingress-port":"6","active":"true", "actions":"output=5"}' http://localhost:8080/ff/of/controller/restapi
```

##Actions


##Match Criterias
    Name     |Description  | Prerequisites
    -------- | ----------- | --------
    ingress-port| Ingress port. This may be a physical or switch-dened logical port | 
    in-phy-port | |
    metadata ||
    src-mac |Ethernet source address|
    dst-mac|Ethernet destination address|
    ether-type|Ethernet type of the OpenFlow packet payload|
    vlan-vid||
    vlan-priority||
    ip-dscp||
    ip-ecn||
    protocol|IPv4 or IPv6 protocol number|
    src-ip|IPv4 source address|
    dst-ip|IPv4 destination address|
    src-port|TCP source port|
    dst-port|TCP destination port|
    udp-src|UDP source port|
    udp-dst|UDP destination port|
    sctp-src||
    sctp-dst||
    icmpv4-type||
    icmpv4-code||
    arp-op||
    arp-spa||
    arp-tpa||
    arp-sha||
    arp-tha||
    ipv6-src|IPv6 source address|
    ipv6-dst|IPv6 destination address|
    ipv6-flabel||
    icmpv6-type||
    icmpv6-code||
    ipv6-nd-sll||
    ipv6-nd-tll||
    mpls-label||
    mpls-tc||
    mpls-bos||
    pbb-isid||
    tunnel-id||
    ipv6-exthdr||
