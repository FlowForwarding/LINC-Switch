from ryu.lib.of_config.capable_switch import OFCapableSwitch
import ryu.lib.of_config.classes as ofc

sess = OFCapableSwitch(
    host='localhost',
    port=1830,
    username='linc',
    password='linc',
    unknown_host_cb=lambda host, fingeprint: True)

csw = sess.get_config('running')

for p in csw.resources.port:
    print p
