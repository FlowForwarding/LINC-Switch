#!/bin/bash

ports=2
tap_count=0
vms[0]=ubuntu1
vms[1]=ubuntu2

start() {
    for br_count in {0..1}
    do
        sudo brctl addbr br$br_count
        sudo tunctl -t tap$tap_count > /dev/null
        sudo ifconfig tap$tap_count promisc 0.0.0.0 up
        sudo brctl addif br$br_count tap$tap_count
        vm_name=${vms[$br_count]}
        echo "Connecting VM $vm_name to TAP$tap_count"
        echo "Start it with ./vm start $vm_name"
        VBoxManage modifyvm $vm_name --nic1 bridged --bridgeadapter1 tap$tap_count \
            --macaddress1 AA00000000A$br_count --cableconnected1 on
        let tap_count++
        sudo tunctl -t tap$tap_count > /dev/null
        sudo ifconfig tap$tap_count promisc 0.0.0.0 up
        sudo brctl addif br$br_count tap$tap_count
        let br_ip=$br_count+1
        echo "Add following switch port configuration line to rel/files/sys.config and rebuild switch:"
        echo "[{ofs_port_no, $br_ip}, {interface, \"tap$tap_count\"}]"
        echo ""
        sudo ifconfig br$br_count promisc 10.0.0.$br_ip up
        let tap_count++
    done
}

stop() {
    for br_count in {0..1}
    do
        sudo ifconfig br$br_count down
        sudo ifconfig tap$tap_count down
        sudo brctl delif br$br_count tap$tap_count
        sudo tunctl -d tap$tap_count > /dev/null
        let tap_count++
        sudo ifconfig tap$tap_count down
        sudo brctl delif br$br_count tap$tap_count
        sudo tunctl -d tap$tap_count > /dev/null
        let tap_count++
        sudo brctl delbr br$br_count
    done
}

case "$1" in
    start)
        start
        ;;
    restart)
        stop
        start
        ;;
    stop)
        stop
        ;;
    *)
        echo "Usage: $0 {start|restart|stop}"
        exit 1
esac

exit 0


MAC: 08002739C876, Attachment: Bridged Interface 'tap0', Cable connected: on, Trace: off (file: none), Type: 82540EM, Reported speed: 0 Mbps, Boot priority: 0, Promisc Policy: deny
