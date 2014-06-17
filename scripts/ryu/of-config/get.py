import utils

sess = utils.connect_to_switch('localhost', 1830, 'linc', 'linc')
xml_config = utils.get(sess)
utils.pretty_print_xml_config(xml_config)
