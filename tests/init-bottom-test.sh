#!/bin/sh
#
# Exercise the init-bottom script's shutdown of the premount network retry.
#
# The retry is still running at init-bottom only when the disk was unlocked
# at the console before any network came up. It is then a shell looping
# over configure_networking, with a subshell below it and dhcpcd or
# ipconfig below that, and ipconfig ignores TERM. Anything left alive keeps
# running from the discarded initramfs after the real system starts.
#
# The first version killed the tree parents first. Each killed parent's
# children passed to init at once, could no longer be found as its
# children, and survived stopped. So the test builds a tree of that shape,
# with processes that ignore TERM, and checks every one of them is dead.
#
# Needs a shell, sed, sleep, kill and a /proc.

set -u

REPO=$(cd "$(dirname "$0")/.." && pwd)
BOTTOM="$REPO/initramfs/scripts/init-bottom/fips-initramfs"

fails=0
cases=0

WORK=$(mktemp -d) || exit 1
PIDS="$WORK/pids"
: > "$PIDS"

# Whatever the test leaves alive is killed on the way out, including when a
# case has failed, so a red run does not also leave stopped processes behind.
cleanup() {
    while IFS= read -r _cu_pid; do
        kill -KILL "$_cu_pid" 2>/dev/null
    done < "$PIDS"
    [ -z "${root:-}" ] || kill -KILL "$root" 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT

assert() {
    # assert <name> <what-went-wrong> <0 if the condition held>
    cases=$((cases + 1))
    if [ "$3" = "0" ]; then
        echo "ok   $1"
    else
        echo "FAIL $1: $2"
        fails=$((fails + 1))
    fi
}

# The functions are taken from the script rather than copied here, so the
# test cannot drift away from what boots. An empty extraction means one
# was renamed, and the cases below then fail rather than pass on a copy.
extracted=$(sed -n '/^children() {/,/^}/p; /^stop_tree() {/,/^}/p; /^kill_tree() {/,/^}/p' "$BOTTOM")
for fn in children stop_tree kill_tree; do
    case "$extracted" in
        *"$fn() {"*) found=0 ;;
        *) found=1 ;;
    esac
    assert "$fn is still there to test" "not found in $BOTTOM" "$found"
done
eval "$extracted"

# Whether a pid is a process that has not died. A zombie has died; it is
# only waiting for a parent that may never reap it, as in a container.
alive() {
    _al_state=$(sed -n 's/^[0-9]* (.*) \(.\) .*/\1/p' "/proc/$1/stat" 2>/dev/null)
    [ -n "$_al_state" ] && [ "$_al_state" != Z ]
}

# A process that ignores TERM and records its pid, standing in for
# ipconfig. Its record is what the test checks, rather than a search of
# every process on the machine.
recorded_sleeper() {
    sh -c 'trap "" TERM; echo $$ >> "$1"; while :; do sleep 1; done' sleeper "$PIDS"
}

# ------------------------------------------------------- a retry-shaped tree
# Output goes nowhere, so that nothing in the tree holds the caller's pipes
# open if the test fails with survivors.
(
    while :; do
        (
            recorded_sleeper &
            recorded_sleeper
        )
        sleep 1
    done
) </dev/null >/dev/null 2>&1 &
root=$!

i=0
while [ "$(sed -n '$=' "$PIDS")" != 2 ] && [ "$i" -lt 100 ]; do
    sleep 1
    i=$((i + 1))
done
recorded=$(sed -n '$=' "$PIDS")
assert "the tree is built before it is killed" "only '$recorded' processes recorded" \
    "$([ "$recorded" = 2 ] && echo 0 || echo 1)"

kids=$(children "$root")
assert "children finds the loop's subshell" "children of $root: '$kids'" \
    "$([ -n "$kids" ] && echo 0 || echo 1)"

stop_tree "$root"
kill_tree "$root"

survivors=""
i=0
while [ "$i" -lt 10 ]; do
    survivors=""
    while IFS= read -r pid; do
        alive "$pid" && survivors="$survivors $pid"
    done < "$PIDS"
    alive "$root" && survivors="$survivors $root"
    [ -n "$survivors" ] || break
    sleep 1
    i=$((i + 1))
done
assert "nothing in the tree survives" "still alive:$survivors" \
    "$([ -z "$survivors" ] && echo 0 || echo 1)"

# ----------------------------------------------------- a process that is gone
out=$(stop_tree 999999999; kill_tree 999999999; echo returned)
assert "a pid that does not exist is not an error" "got '$out'" \
    "$([ "$out" = returned ] && echo 0 || echo 1)"

echo
echo "$cases checks, $fails failed"
[ "$fails" -eq 0 ]
