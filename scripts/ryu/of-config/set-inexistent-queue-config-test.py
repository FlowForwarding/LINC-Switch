import utils
import ncclient

QUEUE_CONFIG = '''
<nc:config xmlns:nc="urn:ietf:params:xml:ns:netconf:base:1.0">
<capable-switch>
<id>CapableSwitch0</id>
<resources>
<queue operation="replace">
<resource-id>Queue2</resource-id>
<id>2</id>
<port>LogicalSwitch0-Port7</port>
<properties>
<min-rate>10</min-rate>
<max-rate>500</max-rate>
<experimenter>123498</experimenter>
</properties>
</queue>
</resources>
</capable-switch>
</nc:config>
'''
sess = utils.connect_to_switch('localhost', 1830, 'linc', 'linc')
try:
    utils.edit_running_config_by_xml_string(QUEUE_CONFIG, sess)
except ncclient.operations.rpc.RPCError as e:
    assert e.tag == 'data-missing'
