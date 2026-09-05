#!/bin/sh
#
# Run ci/container-test.sh in a container per supported distribution.
#
# The same script the GitHub workflow runs, driven locally so a change
# can be checked on all five before it is pushed. Nothing here is needed
# in CI: there the workflow supplies the container and runs the inner
# script directly.
#
# Usage: ci/run-local.sh [distribution ...]
#        ci/run-local.sh debian:12          # just one

set -eu

SRC=$(cd "$(dirname "$0")/.." && pwd)
DISTROS=${*:-"debian:12 debian:13 ubuntu:22.04 ubuntu:24.04 ubuntu:26.04"}

command -v docker >/dev/null || { echo "docker is needed to run this" >&2; exit 2; }

logdir=$(mktemp -d)
echo "logs in $logdir"
rc=0

for image in $DISTROS; do
    name=$(printf '%s' "$image" | tr ':.' '--')
    log="$logdir/$name.log"
    printf '%-16s ' "$image"
    # The tree is copied rather than bind-mounted, because the build
    # writes into it and its artifacts land one directory up. A container
    # writing into the working tree would leave the host's copy dirty.
    if docker run --rm -v "$SRC:/src:ro" "$image" \
            sh -c 'cp -a /src /work && cd /work && ci/container-test.sh' \
            > "$log" 2>&1; then
        echo "PASS"
    else
        echo "FAIL  $log"
        rc=1
    fi
done

echo
for image in $DISTROS; do
    name=$(printf '%s' "$image" | tr ':.' '--')
    printf '%-16s %s\n' "$image" "$(grep -E '^[a-zA-Z].*: [0-9]+ passed, [0-9]+ failed$' "$logdir/$name.log" 2>/dev/null | tail -1)"
done

exit "$rc"
