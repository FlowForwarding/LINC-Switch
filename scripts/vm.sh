#!/bin/bash

start() {
    VBoxManage startvm $1 --type gui
}

stop() {
    VBoxManage controlvm $1 poweroff
}

case "$1" in
    start)
        echo $2
        start $2
        ;;
    restart)
        stop $2
        start $2
        ;;
    stop)
        stop $2
        ;;
    *)
        echo "Usage: $0 {start|restart|stop}"
        exit 1
esac

exit 0
