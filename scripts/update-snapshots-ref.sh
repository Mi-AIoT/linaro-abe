#!/bin/bash

set -e

usage ()
{
    cat <<EOF
Usage: $0 [-r] [-v] [-h] [machine1 machine2 ...]
	This scripts generates and rsync's reference snapshots to machines

	-r: Only rsync snapshots-ref to machines
	-v: Be verbose
	-h: Print help
EOF
}

abe_temp="$(dirname "$0")/.."
generate=true
snapshots_dir=$HOME/snapshots-ref
verbose="set +x"

while getopts "hrv" OPTION; do
    case $OPTION in
	h)
	    usage
	    exit 0
	    ;;
	r)
	    generate=false
	    ;;
	v) verbose="set -x" ;;
    esac
done

$verbose

shift $((OPTIND-1))

# Checkout into $snapshots_dir using ABE
generate_snapshots ()
{
    cd $abe_temp
    git reset --hard
    git clean -fd
    ./configure --with-local-snapshots=${snapshots_dir}-new

    if [ -e $HOME/.aberc ]; then
	echo "WARNING: $HOME/.aberc detected and it might override ABE's behavior"
    fi

    targets=(
	aarch64-linux-gnu
	aarch64-none-elf
	arm-linux-gnueabihf
	arm-none-eabi
	i686-linux-gnu
	x86_64-linux-gnu
    )

    for t in "${targets[@]}"; do
	for c in gcc5 gcc6; do
	    ./abe.sh --target $t --extraconfigdir config/$c --checkout all
	done
    done
}

update_git_repos () {
    for repo in `ls ${snapshots_dir}-new/ | grep "\.git\$"`; do
	(
	    cd ${snapshots_dir}-new/$repo
	    # Update and prune local clone
	    git remote update -p
	    # Cleanup stale branches
	    git branch | grep -v \* | xargs -r git branch -D
	)
    done
}

if $generate; then
    mkdir -p ${snapshots_dir}-new
    update_git_repos
    generate_snapshots

    # Remove checked-out branch directories
    rm -rf ${snapshots_dir}-new/*~*

    # Remove md5sums to force ABE to fetch canonical version via http://.
    rm -f ${snapshots_dir}-new/md5sums
fi

update_git_repos

echo "Snapshots status:"
du -hs $snapshots_dir-new/*

# "if true" is to have same indent as configure-machine.sh hunk from which
# handling of parallel runs was copied.
if true; then
    declare -A pids
    declare -A results

    todo_machines="$@"

    for M in $todo_machines; do
	(
	    rsync -az --delete $snapshots_dir-new/ $M:$snapshots_dir-new/
	    ssh -fn $M "flock -x $snapshots_dir.lock -c \"rsync -a --delete ${snapshots_dir}-new/ $snapshots_dir/\""
	) > /tmp/update-snapshots-ref.$$.$M 2>&1 &
	pids[$M]=$!
    done

    for M in $todo_machines; do
	set +e
	wait ${pids[$M]}
	results[$M]=$?
	set -e

	sed -e "s/^/$M: /" < /tmp/update-snapshots-ref.$$.$M
	rm /tmp/update-snapshots-ref.$$.$M
    done

    all_ok="0"
    for M in $todo_machines; do
	if [ ${results[$M]} = 0 ]; then
	    result="SUCCESS"
	else
	    result="FAIL"
	    all_ok="1"
	fi
	echo "$result: $M"
    done

    exit $all_ok
fi
