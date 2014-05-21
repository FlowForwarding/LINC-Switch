import utils
import ncclient

QUEUE_CONFIG = '''
<nc:config xmlns:nc="urn:ietf:params:xml:ns:netconf:base:1.0">
<capable-switch>
<id>CapableSwitch0</id>
<resources>
<queue operation="replace">
<resource-id>OfflineResource-Queue1</resource-id>
<port>LogicalSwitch0-Port1</port>
</queue>
</resources>
</capable-switch>
</nc:config>
'''


'''
This test check whether it IS impossible to set a port element of queue.
The LINC-Switch should be started with the following sys.config:
[{linc,
[{of_config,enabled},
{capable_switch_ports, [
{port,1,[{interface,"tap0"}, {port_rate, {100, mbps}}]}
]},
{capable_switch_queues, [
{queue, 1, [{min_rate, 20}, {max_rate, 800}]}
]},
{logical_switches,
[{switch,0,
[{backend,linc_us4},
{controllers,[]},
{controllers_listener,disabled},
{queues_status,enabled},
{ports,[{port,1,{queues,[]}}]}]}]}]},
...
].
'''

sess = utils.connect_to_switch('localhost', 1830, 'linc', 'linc')
utils.edit_running_config_by_xml_string(QUEUE_CONFIG, sess)
config = utils.get_config_as_xml(sess)
request = {'resource': 'queue',
            'id': 'OfflineResource-Queue1',
           'value': 'port'}
assert utils.get_config_value_from_resources(request, config) == None
