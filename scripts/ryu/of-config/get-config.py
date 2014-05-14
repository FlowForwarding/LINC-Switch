import utils

sess = utils.connect_to_switch('localhost', 1830, 'linc', 'linc')
config = utils.get_config_as_xml(sess)
utils.pretty_print_xml_config(config)
