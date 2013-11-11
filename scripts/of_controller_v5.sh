#!/bin/sh

help() {
    echo "\nUSAGE:\n$1 [-d] [-s <scenario>] [-p <port_number>]\n
-d\n   enable debug mode\n
-s <scenario>\n   run the scenario after starting the controller\n
-p <port_number>\n   listen on the specified port number\n
-r \"<ip_address:port_number>\"\n   connect to the given host\n
Sample usage: $1 -d -s table_miss -r \"127.0.0.1:6653\""
}


parse_opts() {
    while getopts ":ds:p:r:" OPT
    do
        case $OPT in
            d)
                DEBUG=true
                ;;
            s)
                SCENARIO=${OPTARG}
                ;;
            p)
                if ! [ -z ${PORT_OR_REMOTE_PEER} ]; then
                    echo "Option -${OPT} cannot be used with -r"
                    help $0
                    exit 1
                fi
                PORT_OR_REMOTE_PEER=${OPTARG}
                if ! [  "$PORT_OR_REMOTE_PEER" -eq "$PORT_OR_REMOTE_PEER" ] 2>/dev/null; then
                    echo "The argument for -${OPT} has to be an integer"
                    help $0
                    exit 1
                fi
                ;;
            r)
                if ! [ -z $PORT_OR_REMOTE_PEER ]; then
                    echo "Option -${OPT} cannot be used with -p"
                    help $0
                    exit 1
                fi
                PORT_OR_REMOTE_PEER=${OPTARG}
                ;;
            \?)
                echo "Invalid option: -${OPTARG}"
                help $0
                exit 1
                ;;
            :)
                echo "Option -${OPTARG} requires an argument"
                help $0
                exit 1
                ;;
        esac
    done
}

run_controller() {
    erlc of_controller_v5.erl -pa ../deps/*/ebin -pa ../apps/*/ebin

    if [ -z ${SCENARIO} ]; then
        if [ -z ${PORT_OR_REMOTE_PEER} ]; then
            ERL_EVAL=ERL_EVAL="of_controller_v5:start()"
        else
            ERL_EVAL="of_controller_v5:start(\"${PORT_OR_REMOTE_PEER}\")"
        fi
    else
        if [ -z ${PORT_OR_REMOTE_PEER} ]; then
            START_ARGS="${SCENARIO}"
        else
            START_ARGS="\"${PORT_OR_REMOTE_PEER}\", ${SCENARIO}"
        fi
        ERL_EVAL="of_controller_v5:start_scenario(${START_ARGS})"
    fi

    if  [ -z ${DEBUG} ]; then
        ERL_EVAL=${ERL_EVAL}"."
    else
        ERL_EVAL=${ERL_EVAL}", lager:set_loglevel(lager_console_backend, debug)."
    fi

    erl -pa ../deps/*/ebin -eval "`echo ${ERL_EVAL}`"
}

parse_opts $@
run_controller
