#!/bin/sh

SCRIPT=$(readlink -f "$0")
SCRIPT_PATH=$(dirname "$SCRIPT")
REL_DIR=$SCRIPT_PATH/../rel
DEFAULT_REL="linc"

help() {
    echo "\nThis script creates a relese based on the default release called"\
         "$DEFAULT_REL. It does not copy lib directory, ERTS and Mnesia"\
         "files. The ERTS and lib/ are linked to the original ones. The script"\
         "also changes the sname for the release in the vm.args For example,"\
         "if -c s1 arguments are provided, release rel/linc_s1 will be"\
         "created and the sname parameter will be set to linc_s1."\
         "\nUsage: \n$1 {-c|-d} <RELEASE_SUFFIX>\n"\
         "-c\t copy base release to <RELEASE_SUFFIX>\n"\
         "-d\t delete release <RELEASE_SUFFIX>\n"\
         "-D\t delete all releases with a suffix"
}

parse_opts_and_run() {
    if [ $# -lt 1 ]; then
        echo "Missing arguments"
        help $0
        exit 1
    fi
    while getopts ":c:d:D" OPT
    do
        case $OPT in
            c)
                copy_release $OPTARG
                ;;
            d)
                delete_release $OPTARG
                ;;
            D)
                delete_all_releases
                ;;
            \?)
                echo "Invalid option: -$OPTARG"
                help $0
                exit 1
                ;;
            :)
                echo "Option -$OPTARG requires release suffix"
                help $0
                exit 1
                ;;
        esac
    done
}

copy_release() {
    NEW_REL_SUFFIX=$1
    NEW_REL=$DEFAULT_REL"_"$NEW_REL_SUFFIX
    if [ -d $REL_DIR/$NEW_REL ]; then
        echo "Release $NEW_REL_DIR already exists"
        exit 2
    fi
    copy_release_dir $NEW_REL
    create_erts_lib_links $NEW_REL
    change_node_sname $NEW_REL_SUFFIX $NEW_REL
}

copy_release_dir() {
    NEW_REL=$1
    mkdir $REL_DIR/$NEW_REL && cd $REL_DIR/$DEFAULT_REL
    cp -r `ls -A | grep -v 'lib\|erts-.*\|Mnesia.*'` ../$NEW_REL
}

create_erts_lib_links() {
    NEW_REL=$1
    ERTS_DIR=$(ls -A | grep 'erts-.*')
    ln -s `pwd`/lib ../$NEW_REL/lib
    ln -s `pwd`/$ERTS_DIR ../$NEW_REL/$ERTS_DIR
}

change_node_sname() {
    NEW_SNAME=$DEFAULT_REL"_"$1
    sed -i "/sname/ s/.*/-sname $NEW_SNAME/" ../$2/releases/*/vm.args
}

delete_release() {
    REL_TO_DELETE=$DEFAULT_REL"_"$1
    if [ -d $REL_DIR/$REL_TO_DELETE ]; then
        rm -rf $REL_DIR/$REL_TO_DELETE
    else
        echo "Relese $REL_TO_DELETE does not exist"
        exit 2
    fi
}

delete_all_releases() {
    RELEASES=`find $REL_DIR -maxdepth 1 -type d -regex "$REL_DIR"/"$DEFAULT_REL"_.*`
    if [ -z "$RELEASES" ]; then
        echo "There are no releases to delete"
    else
        rm -rf $RELEASES
    fi
}

parse_opts_and_run $@
