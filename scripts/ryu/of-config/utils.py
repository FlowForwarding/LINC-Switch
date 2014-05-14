from ryu.lib.of_config.capable_switch import OFCapableSwitch
from lxml import etree
import re

CONFIG_ELEMENTS = {'capable_switch_id': 'id',
                   'logical_switch_id': './/logical-switches/switch/id',
                   'controller_id': './/logical-switches/switch/controllers/controller/id',
                   'controller_ip': './/logical-switches/switch/controllers/controller/ip-address',
                   'controller_port': './/logical-switches/switch/controllers/controller/port',
                   'controller_protocol': './/logical-switches/switch/controllers/controller/protocol',
                   'controller_role': './/logical-switches/switch/controllers/controller/role'}

def _get_running_xml_config_without_namcespaces(session):
    raw_config = session.raw_get_config('running')
    return etree.fromstring(re.sub('ns0:', '', raw_config))

def get_config_as_xml(session):
    return _get_running_xml_config_without_namcespaces(session)

def pretty_print_xml_config(config):
    print etree.tostring(config, pretty_print=True)

def get_config_value_from_xml(id, config):
    return config.find(CONFIG_ELEMENTS[id]).text

def edit_running_config_by_xml_string(config, session):
    session.raw_edit_config('running', config)

def connect_to_switch(host, port, username, password):
    return OFCapableSwitch(host = host,
                           port = port,
                           username = username,
                           password = password,
                           unknown_host_cb=lambda host, fingeprint: True)

def get_controller_roles():
    return ['equal', 'slave', 'master']
