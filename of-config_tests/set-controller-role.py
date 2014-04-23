from ryu.lib.of_config.capable_switch import OFCapableSwitch
from xml.etree import ElementTree as et
import re

sess = OFCapableSwitch(
    host='localhost',
    port=1830,
    username='linc',
    password='linc',
    unknown_host_cb=lambda host, fingeprint: True)

ROLES = ['equal', 'slave', 'master']

SWITCH_CONTROLLER = '''
<nc:config xmlns:nc="urn:ietf:params:xml:ns:netconf:base:1.0">
<capable-switch xmlns="urn:onf:of111:config:yang">
<id>%(capable_switch)s</id>
<logical-switches>
<switch>
<id>%(logical_switch)s</id>
<controllers>
<controller operation="replace">
<id>%(controller_id)s</id>
<role>%(role)s</role>
<ip-address>%(controller_ip)s</ip-address>
<port>%(controller_port)s</port>
<protocol>%(controller_protocol)s</protocol>
</controller>
</controllers>
</switch>
</logical-switches>
</capable-switch>
</nc:config>
'''

def get_xml_config_without_namcespaces():
    raw_config = sess.raw_get_config('running')
    return et.fromstring(re.sub('ns0:', '', raw_config))

def get_controller_role_from_xml(xml):
    return xml.find('.//logical-switches/switch/controllers/controller/role').text


xml_config = get_xml_config_without_namcespaces()

capable_switch_id = xml_config.find('id').text
logical_switch_id = xml_config.find('.//logical-switches/switch/id').text
controller_id =  xml_config.find('.//logical-switches/switch/controllers/controller/id').text
controller_ip = xml_config.find('.//logical-switches/switch/controllers/controller/ip-address').text
controller_port = xml_config.find('.//logical-switches/switch/controllers/controller/port').text
controller_protocol = xml_config.find('.//logical-switches/switch/controllers/controller/protocol').text
print controller_ip, controller_port, controller_protocol
controller_role = get_controller_role_from_xml(xml_config)

for role in ROLES:
    if controller_role != role:
        new_role = role
        break

print("Current role is: {0}".format(controller_role))
print("New role is: {0}".format(new_role))
sess.raw_edit_config('running', SWITCH_CONTROLLER % {'capable_switch' : capable_switch_id,
                                                     'logical_switch' : logical_switch_id,
                                                     'controller_id' : controller_id,
                                                     'controller_ip' : controller_ip,
                                                     'controller_port' : controller_port,
                                                     'controller_protocol' : controller_protocol,
                                                     'role' : new_role})

xml_config = get_xml_config_without_namcespaces()
controller_role = get_controller_role_from_xml(xml_config)
assert controller_role == new_role,  "Controller's role is not %s" % new_role
