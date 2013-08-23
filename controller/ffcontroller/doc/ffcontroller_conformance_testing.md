# FFController Conformance testing

Matches
IN_PORT
REST API command

curl -d '{"switch":"00:90:FB:37:71:96:00:00", "name":"fm-02", "priority":"32", "ingress-port":"123","active":"true", "actions":"output=1"}' http://localhost:8080/ff/of/controller/restapi

Switch output (LINC)

xx:xx:xx.xxx [debug] Received message from the controller: {ofp_message,4,flow_mod,0,{ofp_flow_mod,<<0,0,0,0,0,0,0,0>>,<<0,0,0,0,0,0,0,0>>,0,add,0,0,32,no_buffer,0,0,[],{ofp_match,[{ofp_field,openflow_basic,in_port,false,<<0,0,0,123>>,undefined}]},[{ofp_instruction_write_actions,4,[{ofp_action_output,16,1,65535}]}]}}

Flow installed (LINC)

(linc@localhost)1> linc_us4_flow:get_flow_table(0,0).

[{flow_entry,{32,#Ref<0.0.0.1339>},

           32,

           {ofp_match,[{ofp_field,openflow_basic,in_port,false,

                                  <<0,0,0,123>>,

                                  undefined}]},

           <<0,0,0,0,0,0,0,0>>,

           [],

           {1369,501100,297695},

           {infinity,0,0},

           {infinity,0,0},

           [{ofp_instruction_write_actions,4,

                                           [{ofp_action_output,16,1,65535}]}]}]

Passed

Yes
IN_PHY_PORT
REST API command

curl -d '{"switch":"00:0C:29:85:78:80:00:00", "name":"fm-02", "priority":"32", "in-phy-port":"1", "actions":"output=2"}' http://localhost:8080/ff/of/controller/restapi

ETH_SRC
REST API command

curl -d '{"switch":"00:0C:29:85:78:80:00:00", "name":"fm-02", "priority":"32", "src-mac":"11:22:33:44:55:66", "actions":"output=1"}' http://localhost:8080/ff/of/controller/restapi

Switch output (LINC)

[debug] Received message from the controller: {ofp_message,4,flow_mod,0,{ofp_flow_mod,<<0,0,0,0,0,0,0,0>>,<<0,0,0,0,0,0,0,0>>,0,add,0,0,32,no_buffer,0,0,[],{ofp_match,[{ofp_field,openflow_basic,eth_src,false,<<17,34,51,68,85,102>>,undefined}]},[{ofp_instruction_write_actions,4,[{ofp_action_output,16,1,65535}]}]}}

Flow installed (LINC)

(linc@localhost)3> ets:tab2list(linc:lookup(0, flow_table_0)).

[{flow_entry,{32,#Ref<0.0.0.1482>},

            32,

            {ofp_match,[{ofp_field,openflow_basic,eth_src,false,

                                   <<17,34,51,68,85,102>>,

                                   undefined}]},

            <<0,0,0,0,0,0,0,0>>,

            [],

            {1373,300531,32295},

            {infinity,0,0},

            {infinity,0,0},

            [{ofp_instruction_write_actions,4,

                                            [{ofp_action_output,16,1,65535}]}]}]

Passed

Yes
ETH_DST
REST API command

curl -d '{"switch":"00:0C:29:85:78:80:00:00", "name":"fm-02", "priority":"32", "dst-mac":"66:55:44:33:22:11", "actions":"output=1"}' http://localhost:8080/ff/of/controller/restapi

Switch output (LINC)

[debug] Received message from the controller: {ofp_message,4,flow_mod,0,{ofp_flow_mod,<<0,0,0,0,0,0,0,0>>,<<0,0,0,0,0,0,0,0>>,0,add,0,0,32,no_buffer,0,0,[],{ofp_match,[{ofp_field,openflow_basic,eth_dst,false,<<102,85,68,51,34,17>>,undefined}]},[{ofp_instruction_write_actions,4,[{ofp_action_output,16,1,65535}]}]}}

(linc@localhost)4> ets:tab2list(linc:lookup(0, flow_table_0)).

Flow installed (LINC)

ets:tab2list(linc:lookup(0, flow_table_0)).

{flow_entry,{32,#Ref<0.0.0.5652>},

            32,

            {ofp_match,[{ofp_field,openflow_basic,eth_dst,false,

                                   <<102,85,68,51,34,17>>,

                                   undefined}]},

            <<0,0,0,0,0,0,0,0>>,

            [],

            {1373,303537,379641},

            {infinity,0,0},

            {infinity,0,0},

            [{ofp_instruction_write_actions,4,

                                            [{ofp_action_output,16,1,65535}]}]}]

Passed

Yes
ETH_TYPE
REST API command

curl -d '{"switch":"00:0C:29:85:78:80:00:00", "name":"fm-02", "priority":"32", "ether-type":"0x800", "actions":"output=1"}' http://localhost:8080/ff/of/controller/restapi

Switch output (LINC):

[debug] Received message from the controller: {ofp_message,4,flow_mod,0,{ofp_flow_mod,<<0,0,0,0,0,0,0,0>>,<<0,0,0,0,0,0,0,0>>,0,add,0,0,32,no_buffer,0,0,[],{ofp_match,[{ofp_field,openflow_basic,eth_type,false,<<8,0>>,undefined}]},[{ofp_instruction_write_actions,4,[{ofp_action_output,16,1,65535}]}]}}

Flow installed (LINC):

(linc@localhost)1> ets:tab2list(linc:lookup(0, flow_table_0)).

[{flow_entry,{32,#Ref<0.0.0.414>},

            32,

            {ofp_match,[{ofp_field,openflow_basic,eth_type,false,

                                   <<8,0>>,

                                   undefined}]},

            <<0,0,0,0,0,0,0,0>>,

            [],

            {1373,303974,880280},

            {infinity,0,0},

            {infinity,0,0},

            [{ofp_instruction_write_actions,4,

                                            [{ofp_action_output,16,1,65535}]}]}]

Passed

Yes
VLAN_VID
REST API command

curl -d '{"switch":"00:0C:29:85:78:80:00:00", "name":"fm-02", "priority":"32","vlan-vid":"127", "actions":"output=1"}' http://localhost:8080/ff/of/controller/restapi
Switch output (LINC):

[debug] Received message from the controller: {ofp_message,4,flow_mod,0,{ofp_flow_mod,<<0,0,0,0,0,0,0,0>>,<<0,0,0,0,0,0,0,0>>,0,add,0,0,32,no_buffer,0,0,[],{ofp_match,[{ofp_field,openflow_basic,vlan_vid,false,<<0,127>>,undefined}]},[{ofp_instruction_write_actions,4,[{ofp_action_output,16,1,65535}]}]}}
Flow installed (LINC):

ets:tab2list(linc:lookup(0, flow_table_0)).

[{flow_entry,{32,#Ref<0.0.0.444>},

            32,

            {ofp_match,[{ofp_field,openflow_basic,vlan_vid,false,

                                   <<0,127>>,

                                   undefined}]},

            <<0,0,0,0,0,0,0,0>>,

            [],

            {1373,372866,589946},

            {infinity,0,0},

            {infinity,0,0},

            [{ofp_instruction_write_actions,4,

                                            [{ofp_action_output,16,1,65535}]}]}]

VLAN_PCP
REST API command

curl -d '{"switch":"00:0C:29:85:78:80:00:00", "name":"fm-02", "priority":"32", "vlan-vid":"127", "vlan-priority":"1", "actions":"output=1"}' http://localhost:8080/ff/of/controller/restapi
Switch output (LINC):

[debug] Received message from the controller: {ofp_message,4,flow_mod,0,{ofp_flow_mod,<<0,0,0,0,0,0,0,0>>,<<0,0,0,0,0,0,0,0>>,0,add,0,0,32,no_buffer,0,0,[],{ofp_match,[{ofp_field,openflow_basic,vlan_pcp,false,<<1>>,undefined},{ofp_field,openflow_basic,vlan_vid,false,<<0,127>>,undefined}]},[{ofp_instruction_write_actions,4,[{ofp_action_output,16,1,65535}]}]}}
Flow installed (LINC):

ets:tab2list(linc:lookup(0, flow_table_0)).

[]

Not passed

BAD_MATCH, BAD_PREREQ,

VLAN_VID must be the first.
IP_PROTO
REST API command

curl -d '{"switch":"00:0C:29:85:78:80:00:00", "name":"fm-02", "priority":"32", "protocol":"3", "ether-type":"0x86dd", "actions":"output=1"}' http://localhost:8080/ff/of/controller/restapi
Switch output (LINC):

[debug] Received message from the controller: {ofp_message,4,flow_mod,0,{ofp_flow_mod,<<0,0,0,0,0,0,0,0>>,<<0,0,0,0,0,0,0,0>>,0,add,0,0,32,no_buffer,0,0,[],{ofp_match,[{ofp_field,openflow_basic,eth_type,false,<<134,221>>,undefined},{ofp_field,openflow_basic,ip_proto,false,<<3>>,undefined}]},[{ofp_instruction_write_actions,4,[{ofp_action_output,16,1,65535}]}]}}

Flow installed (LINC):

linc_us4_flow:get_flow_table(0,0).

[{flow_entry,{32,#Ref<0.0.0.4972>},

            32,

            {ofp_match,[{ofp_field,openflow_basic,eth_type,false,

                                   <<134,221>>,

                                   undefined},

                        {ofp_field,openflow_basic,ip_proto,false,<<3>>,undefined}]},

            <<0,0,0,0,0,0,0,0>>,

            [],

            {1373,993212,248167},

            {infinity,0,0},

            {infinity,0,0},

            [{ofp_instruction_write_actions,4,

                                            [{ofp_action_output,16,1,65535}]}]}
Passed

Yes
IPV4_SRC
REST API command

curl -d '{"switch":"00:0C:29:85:78:80:00:00", "name":"fm-02", "priority":"32", "src-ip":"127.0.0.0", "ether-type":"0x800", "actions":"output=1"}' http://localhost:8080/ff/of/controller/restapi
Switch output (LINC):

[debug] Received message from the controller: {ofp_message,4,flow_mod,0,{ofp_flow_mod,<<0,0,0,0,0,0,0,0>>,<<0,0,0,0,0,0,0,0>>,0,add,0,0,32,no_buffer,0,0,[],{ofp_match,[{ofp_field,openflow_basic,eth_type,false,<<8,0>>,undefined},{ofp_field,openflow_basic,ipv4_src,false,<<127,0,0,0>>,undefined}]},[{ofp_instruction_write_actions,4,[{ofp_action_output,16,1,65535}]}]}}
Flow installed (LINC):

ets:tab2list(linc:lookup(0, flow_table_0)).

[{flow_entry,{32,#Ref<0.0.0.6130>},

            32,

            {ofp_match,[{ofp_field,openflow_basic,eth_type,false,

                                   <<8,0>>,

                                   undefined},

                        {ofp_field,openflow_basic,ipv4_src,false,

                                   <<127,0,0,0>>,

                                   undefined}]},

            <<0,0,0,0,0,0,0,0>>,

            [],

            {1373,386407,577174},

            {infinity,0,0},

            {infinity,0,0},

            [{ofp_instruction_write_actions,4,

                                            [{ofp_action_output,16,1,65535}]}]}]
Passed

Yes

IPV4_DST
REST API command

curl -d '{"switch":"00:0C:29:85:78:80:00:00", "name":"fm-02", "priority":"32", "dst-ip":"127.0.0.0", "ether-type":"0x800", "actions":"output=1"}' http://localhost:8080/ff/of/controller/restapi
Switch output (LINC):

[debug] Received message from the controller: {ofp_message,4,flow_mod,0,{ofp_flow_mod,<<0,0,0,0,0,0,0,0>>,<<0,0,0,0,0,0,0,0>>,0,add,0,0,32,no_buffer,0,0,[],{ofp_match,[{ofp_field,openflow_basic,eth_type,false,<<8,0>>,undefined},{ofp_field,openflow_basic,ipv4_dst,false,<<127,0,0,0>>,undefined}]},[{ofp_instruction_write_actions,4,[{ofp_action_output,16,1,65535}]}]}}
Flow installed (LINC):

ets:tab2list(linc:lookup(0, flow_table_0)).

[{flow_entry,{32,#Ref<0.0.0.6130>},

            32,

            {ofp_match,[{ofp_field,openflow_basic,eth_type,false,

                                   <<8,0>>,

                                   undefined},

                        {ofp_field,openflow_basic,ipv4_dst,false,

                                   <<127,0,0,0>>,

                                   undefined}]},

            <<0,0,0,0,0,0,0,0>>,

            [],

            {1373,386407,577174},

            {infinity,0,0},

            {infinity,0,0},

            [{ofp_instruction_write_actions,4,

                                            [{ofp_action_output,16,1,65535}]}]}]
Passed

Yes

TCP_SRC
REST API command

curl -d '{"switch":"00:0C:29:85:78:80:00:00", "name":"fm-02", "priority":"32", "src-port":"21", "protocol":"6", "ether-type":"0x86dd", "actions":"output=1"}' http://localhost:8080/ff/of/controller/restapi
Switch output (LINC):

[debug] Received message from the controller: {ofp_message,4,flow_mod,0,{ofp_flow_mod,<<0,0,0,0,0,0,0,0>>,<<0,0,0,0,0,0,0,0>>,0,add,0,0,32,no_buffer,0,0,[],{ofp_match,[{ofp_field,openflow_basic,eth_type,false,<<134,221>>,undefined},{ofp_field,openflow_basic,ip_proto,false,<<6>>,undefined},{ofp_field,openflow_basic,tcp_src,false,<<0,21>>,undefined}]},[{ofp_instruction_write_actions,4,[{ofp_action_output,16,1,65535}]}]}}

Flow installed (LINC):

linc_us4_flow:get_flow_table(0,0).

[{flow_entry,{32,#Ref<0.0.0.8912>},

            32,

            {ofp_match,[{ofp_field,openflow_basic,eth_type,false,

                                   <<134,221>>,

                                   undefined},

                        {ofp_field,openflow_basic,ip_proto,false,<<6>>,undefined},

                        {ofp_field,openflow_basic,tcp_src,false,

                                   <<0,21>>,

                                   undefined}]},

            <<0,0,0,0,0,0,0,0>>,

            [],

            {1373,996108,804906},

            {infinity,0,0},

            {infinity,0,0},

            [{ofp_instruction_write_actions,4,

                                            [{ofp_action_output,16,1,65535}]}]}
Passed

Yes

TCP_DST
REST API command

curl -d '{"switch":"00:0C:29:85:78:80:00:00", "name":"fm-02", "priority":"32", "dst-port":"22", "protocol":"6", "ether-type":"0x86dd", "actions":"output=1"}' http://localhost:8080/ff/of/controller/restapi
Switch output (LINC):

[debug] Received message from the controller: {ofp_message,4,flow_mod,0,{ofp_flow_mod,<<0,0,0,0,0,0,0,0>>,<<0,0,0,0,0,0,0,0>>,0,add,0,0,32,no_buffer,0,0,[],{ofp_match,[{ofp_field,openflow_basic,eth_type,false,<<134,221>>,undefined},{ofp_field,openflow_basic,ip_proto,false,<<6>>,undefined},{ofp_field,openflow_basic,tcp_dst,false,<<0,22>>,undefined}]},[{ofp_instruction_write_actions,4,[{ofp_action_output,16,1,65535}]}]}}
Flow installed (LINC):

linc_us4_flow:get_flow_table(0,0).

[{flow_entry,{32,#Ref<0.0.0.9189>},

            32,

            {ofp_match,[{ofp_field,openflow_basic,eth_type,false,

                                   <<134,221>>,

                                   undefined},

                        {ofp_field,openflow_basic,ip_proto,false,<<6>>,undefined},

                        {ofp_field,openflow_basic,tcp_dst,false,

                                   <<0,22>>,

                                   undefined}]},

            <<0,0,0,0,0,0,0,0>>,

            [],

            {1373,996332,169186},

            {infinity,0,0},

            {infinity,0,0},

            [{ofp_instruction_write_actions,4,

                                            [{ofp_action_output,16,1,65535}]}]}
Passed

Yes
IPV6_SRC
REST API command

curl -d '{"switch":"00:0C:29:85:78:80:00:00", "name":"fm-02", "priority":"32", "ipv6-src":"0011:1122:2233:3344:4455:5566:6677:7788", "ether-type":"0x86dd", "actions":"output=1"}' http://localhost:8080/ff/of/controller/restapi
Switch output (LINC):

[debug] Received message from the controller: {ofp_message,4,flow_mod,0,{ofp_flow_mod,<<0,0,0,0,0,0,0,0>>,<<0,0,0,0,0,0,0,0>>,0,add,0,0,32,no_buffer,0,0,[],{ofp_match,[{ofp_field,openflow_basic,eth_type,false,<<134,221>>,undefined},{ofp_field,openflow_basic,ipv6_src,false,<<17,0,34,17,51,34,68,51,85,68,102,85,119,102,136,119>>,undefined}]},[{ofp_instruction_write_actions,4,[{ofp_action_output,16,1,65535}]}]}}
Flow installed (LINC):

linc_us4_flow:get_flow_table(0,0).

[{flow_entry,{32,#Ref<0.0.0.552>},

            32,

            {ofp_match,[{ofp_field,openflow_basic,eth_type,false,

                                   <<134,221>>,

                                   undefined},

                        {ofp_field,openflow_basic,ipv6_src,false,

                                   <<17,0,34,17,51,34,68,51,85,68,102,85,119,102,136,...>>,

                                   undefined}]},

            <<0,0,0,0,0,0,0,0>>,

            [],

            {1373,989833,272545},

            {infinity,0,0},

            {infinity,0,0},

            [{ofp_instruction_write_actions,4,

                                            [{ofp_action_output,16,1,65535}]}]}]

Passed

Yes

IPV6_DST
REST API command

curl -d '{"switch":"00:0C:29:85:78:80:00:00", "name":"fm-02", "priority":"32", "ipv6-dst":"0011:1122:2233:3344:4455:5566:6677:7788", "ether-type":"0x86dd", "actions":"output=1"}' http://localhost:8080/ff/of/controller/restapi
Switch output (LINC):

[debug] Received message from the controller: {ofp_message,4,flow_mod,0,{ofp_flow_mod,<<0,0,0,0,0,0,0,0>>,<<0,0,0,0,0,0,0,0>>,0,add,0,0,32,no_buffer,0,0,[],{ofp_match,[{ofp_field,openflow_basic,eth_type,false,<<134,221>>,undefined},{ofp_field,openflow_basic,ipv6_dst,false,<<17,0,34,17,51,34,68,51,85,68,102,85,119,102,136,119>>,undefined}]},[{ofp_instruction_write_actions,4,[{ofp_action_output,16,1,65535}]}]}}
Flow installed (LINC):

linc_us4_flow:get_flow_table(0,0).

[{flow_entry,{32,#Ref<0.0.0.552>},

            32,

            {ofp_match,[{ofp_field,openflow_basic,eth_type,false,

                                   <<134,221>>,

                                   undefined},

                        {ofp_field,openflow_basic,ipv6_dst,false,

                                   <<17,0,34,17,51,34,68,51,85,68,102,85,119,102,136,...>>,

                                   undefined}]},

            <<0,0,0,0,0,0,0,0>>,

            [],

            {1373,989833,272545},

            {infinity,0,0},

            {infinity,0,0},

            [{ofp_instruction_write_actions,4,

                                            [{ofp_action_output,16,1,65535}]}]}]

Passed
Yes
