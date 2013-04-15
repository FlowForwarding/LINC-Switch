# Getting REST Firewall Service working with LINC

## Start LINC in OF 1.2 mode 
Modify $LINC_ROOT/rel/files/sys.config - value for backend must be linc_us3
```bash
$  make compile rel
$  cd $LINC_ROOT; rel/linc/bin/linc console
```

## Start Ryu Controller with REST service
```bash
$  cd $RYU_ROOT; bin/ryu-manager --verbose --use-stderr ryu/app/rest_firewall.py ryu/lib/ofctl_v1_2.py

You will see an output like this on Ryu console
    EVENT dpset->RestFirewallAPI EventDP
    Registering dpid=40808612199530496
    dpid=0090fb3771ee0000 : Join as firewall switch.
```

## Issue REST commands (from another terminal on the same machine)

### Check Firewall Status
```bash
$ curl -i -H "Accept: application/json" -X GET http://localhost:8080/firewall/module/status
HTTP/1.1 200 OK
Content-Type: application/json; charset=UTF-8
Content-Length: 54
Date: Sat, 13 Apr 2013 04:18:22 GMT

{"switch_id: 0090fb3771ee0000": {"status": "disable"}}
```

### Enable Firewall Service
```bash
$ curl -i -H "Accept: application/json" -X PUT -d '{"switch_id": "0"}' http://localhost:8080/firewall/module/enable/all
HTTP/1.1 200 OK
Content-Type: application/json; charset=UTF-8
Content-Length: 86
Date: Sat, 13 Apr 2013 04:23:10 GMT

{"switch_id: 0090fb3771ee0000": {"result": "success", "details": "firewall running."}}
```

### Check Firewall Status
```bash
$ curl -i -H "Accept: application/json" -X GET http://localhost:8080/firewall/module/status
HTTP/1.1 200 OK
Content-Type: application/json; charset=UTF-8
Content-Length: 53
Date: Sat, 13 Apr 2013 04:24:12 GMT

{"switch_id: 0090fb3771ee0000": {"status": "enable"}}
```

### Now add a rule to block connection from MAC address 12:34:56:78:9a:bc
```bash
$ curl -X POST -d '{"dl_src": "12:34:56:78:9a:bc", "actions": "DENY"}' http://localhost:8080/firewall/rules/0090fb3771ee0000
{"switch_id: 0090fb3771ee0000": {"result": "success", "details": "Rule added. : rule_id=1"}}
```

### Now add a rule to block connection to 10.100.5.0/24 subnet
```bash
$ curl -X POST -d '{"dl_type": "IPv4", "nw_dst": "10.100.5.0/24", "actions": "DENY"}' http://localhost:8080/firewall/rules/0090fb3771ee0000

{"switch_id: 0090fb3771ee0000": {"result": "success", "details": "Rule added. : rule_id=2"}}
```

### Block all TCP packets
```bash
# curl -X POST -d '{"dl_type": "IPv4", "nw_proto": "TCP", "actions": "DENY"}' http://localhost:8080/firewall/rules/0090fb3771ee0000

{"switch_id: 0090fb3771ee0000": {"result": "success", "details": "Rule added. : rule_id=3"}
```

### Check Firewall Rules added
```bash
$ curl -i -H "Accept: application/json" -X GET http://localhost:8080/firewall/rules/0090fb3771ee0000
HTTP/1.1 200 OK
Content-Type: application/json; charset=UTF-8
Content-Length: 114
Date: Sat, 13 Apr 2013 04:58:33 GMT

{"switch_id: 0090fb3771ee0000": {"rule_id: 1": {"priority": 0, "dl_src": "12:34:56:78:9a:bc", "actions": "DENY"}}}

**(seems to be a bug as I have 2 rules added and only 1 is returned)**
```

### Delete rules installed on the switch
```bash
Delete Rule given ID number:
$  curl -i -H "Accept: application/json" -X DELETE -d '{"rule_id":"1"}' http://localhost:8080/firewall/rules/0090fb3771ee0000

Delete All Rules:
$  curl -i -H "Accept: application/json" -X DELETE -d '{"rule_id":"all"}' http://localhost:8080/firewall/rules/0090fb3771ee0000

HTTP/1.1 200 OK
Content-Type: application/json; charset=UTF-8
Content-Length: 96
Date: Tue, 16 Apr 2013 07:18:09 GMT

{"switch_id: 0090fb3771ee0000": {"result": "success", "details": "Rule deleted. : ruleID=3,1,"}
```

