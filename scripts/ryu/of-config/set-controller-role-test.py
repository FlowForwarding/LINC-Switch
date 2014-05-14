import re
import utils
import random

SWITCH_CONTROLLER = '''
<nc:config xmlns:nc="urn:ietf:params:xml:ns:netconf:base:1.0">
<capable-switch xmlns="urn:onf:of111:config:yang">
<id>%(capable_switch_id)s</id>
<logical-switches>
<switch>
<id>%(logical_switch_id)s</id>
<controllers>
<controller operation="replace">
<id>%(controller_id)s</id>
<role>%(controller_role)s</role>
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

CONFIG_KEYS = ['capable_switch_id',
               'logical_switch_id',
               'controller_id', 'controller_ip',
               'controller_port',
               'controller_protocol',
               'controller_role']

def set_new_controller_role(session):
    xml_config = utils.get_config_as_xml(session)
    config_map = {key: utils.get_config_value_from_xml(key, xml_config)
                  for key in CONFIG_KEYS}
    current_role = new_role = config_map['controller_role']
    while current_role == new_role:
        new_role = random.choice(utils.get_controller_roles())
    config_map['controller_role'] = new_role
    utils.edit_running_config_by_xml_string(SWITCH_CONTROLLER % config_map, session)
    return new_role

def assert_role_changed(expected_role, session):
    xml_config = utils.get_config_as_xml(session)
    role = utils.get_config_value_from_xml('controller_role', xml_config)
    assert role == expected_role,  "Controller's role is not %s" % expected_role

sess = utils.connect_to_switch('localhost', 1830, 'linc', 'linc')
for i in range(10):
    new_role = set_new_controller_role(sess)
    assert_role_changed(new_role, sess)
