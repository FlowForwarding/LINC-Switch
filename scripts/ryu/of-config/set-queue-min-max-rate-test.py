import utils
import ncclient
import random

QUEUE_CONFIG = '''
<nc:config xmlns:nc="urn:ietf:params:xml:ns:netconf:base:1.0">
<capable-switch>
<id>CapableSwitch0</id>
<resources>
<queue operation="replace">
<resource-id>LogicalSwitch0-Port2-Queue1</resource-id>
<properties>
<min-rate>%(min-rate)s</min-rate>
<max-rate>%(max-rate)s</max-rate>
</properties>
</queue>
</resources>
</capable-switch>
</nc:config>
'''

'''
This test should be run with the following sys.config for LINC-Switch:
[{linc,
[{of_config,enabled},
{capable_switch_ports, [
{port,1,[{interface,"tap0"}, {port_rate, {100, mbps}}]},
{port,2,[{interface,"tap1"}, {port_rate, {100, mbps}}]}
]},
{capable_switch_queues, [
{queue, 1, [{min_rate, 20}, {max_rate, 40}]},
{queue, 2, [{min_rate, 300}, {max_rate, 1000}]}
]},
{logical_switches,
[{switch,0,
[{backend,linc_us4},
{controllers,[]},
{controllers_listener,disabled},
{queues_status,enabled},
{ports,[{port,1,{queues,[]}}, {port,2,{queues,[1,2]}}]}
]
}
]
}]},
...].
'''

ASSERT_MSG = 'Queue {0} is {1}. Should be {2}.'
REQUEST = {'resource' : 'queue',
           'id': 'LogicalSwitch0-Port2-Queue1',
           'value' : None}

def assert_min_max_rate_was_set(min_rate, max_rate):
 for tag, expected_value in [('min-rate', min_rate), ('max-rate', max_rate)]:
        REQUEST['value'] = './/' + tag
        config = utils.get_config_as_xml(sess)
        actual_value = utils.get_config_value_from_resources(REQUEST, config)
        assert str(expected_value) == actual_value, ASSERT_MSG.format(
            tag, actual_value, expected_value)

sess = utils.connect_to_switch('localhost', 1830, 'linc', 'linc')
for i in range(1, 10):
    min_rate = random.randint(1,1000)
    max_rate = random.randint(1,1000)
    queue_config = QUEUE_CONFIG % {'min-rate' : min_rate, 'max-rate': max_rate}
    utils.edit_running_config_by_xml_string(queue_config, sess)
    assert_min_max_rate_was_set(min_rate, max_rate)
