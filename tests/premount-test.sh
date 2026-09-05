#!/bin/sh
#
# Exercise the premount script's address parsing under an initramfs that
# carries only what an initramfs is known to carry.
#
# This exists because of a fault that a Debian machine cannot show. The
# parser ended with "head -n 1"; Ubuntu's busybox-initramfs has no head
# applet and its image no head binary, so the pipeline returned empty on
# every call. Nothing crashed. The wait loop ran to its limit on every
# boot, the script reported that remote unlock was unavailable while it
# was in fact working, and the address comparison the script exists to
# make was never reached: it failed open, silently.
#
# So the test runs the function with a PATH that deliberately has no
# head, which is the shape of the real defect.
#
# Needs nothing but a shell and sed.

set -u

REPO=$(cd "$(dirname "$0")/.." && pwd)
PREMOUNT="$REPO/initramfs/scripts/init-premount/a_fips"

fails=0
cases=0

WORK=$(mktemp -d) || exit 1
trap 'rm -rf "$WORK"' EXIT

assert() {
    cases=$((cases + 1))
    if [ "$3" = "0" ]; then
        echo "ok   $1"
    else
        echo "FAIL $1: $2"
        fails=$((fails + 1))
    fi
}

# The whole PATH the function is allowed. sed is here because the image
# carries it on every distribution checked; head is absent on purpose.
mkdir -p "$WORK/bin"
for tool in sed; do
    ln -s "$(command -v "$tool")" "$WORK/bin/$tool" || exit 1
done

# Stands in for iproute2, printing whatever fixture the case sets.
cat > "$WORK/bin/ip" <<'STUB'
#!/bin/sh
# Printed with shell builtins, so the stub itself needs nothing on the
# restricted PATH the test sets.
while IFS= read -r line || [ -n "$line" ]; do
    printf '%s\n' "$line"
done < "$IP_FIXTURE"
STUB
chmod 0755 "$WORK/bin/ip"

# The function is taken from the script rather than copied here, so the
# test cannot drift away from what boots. An empty extraction means it
# was renamed, and every case below then fails rather than passing on a
# stale copy.
extracted=$(sed -n '/^current_address() {/,/^}/p' "$PREMOUNT")
assert "current_address is still there to test" "not found in $PREMOUNT" \
    "$([ -n "$extracted" ] && echo 0 || echo 1)"
eval "$extracted"

IFACE=fips0
export IFACE

run_case() {
    # run_case <fixture-content>
    printf '%s\n' "$1" > "$WORK/fixture"
    IP_FIXTURE="$WORK/fixture" PATH="$WORK/bin" current_address
}

# ------------------------------------------------------------ one address
got=$(run_case '5: fips0: <POINTOPOINT,MULTICAST,NOARP,UP,LOWER_UP> mtu 1280
    inet6 fd13:7a57:8ed0:b331:7d51:7c23:fd84:b678/64 scope global
       valid_lft forever preferred_lft forever')
assert "the address is read with no head on PATH" "got '$got'" \
    "$([ "$got" = "fd13:7a57:8ed0:b331:7d51:7c23:fd84:b678" ] && echo 0 || echo 1)"

# ----------------------------------------------------------- two addresses
# The first is what the rest of the script compares against the address
# written into the image, so which one is returned is not cosmetic.
got=$(run_case '5: fips0: <POINTOPOINT,MULTICAST,NOARP,UP,LOWER_UP> mtu 1280
    inet6 fd13:7a57:8ed0:b331:7d51:7c23:fd84:b678/64 scope global
       valid_lft forever preferred_lft forever
    inet6 fdac:b631:4689:3ee2:c802:910f:d56:738d/64 scope global
       valid_lft forever preferred_lft forever')
assert "the first of two addresses is returned" "got '$got'" \
    "$([ "$got" = "fd13:7a57:8ed0:b331:7d51:7c23:fd84:b678" ] && echo 0 || echo 1)"

# -------------------------------------------------------------- no address
# A daemon that runs with no interface reaches this, and the script must
# see the empty answer: it is what makes the warning fire.
got=$(run_case '5: fips0: <POINTOPOINT,MULTICAST,NOARP> mtu 1280')
assert "no inet6 line gives an empty answer" "got '$got'" \
    "$([ -z "$got" ] && echo 0 || echo 1)"

# ------------------------------------------------------------ ip not there
got=$(printf '%s\n' "" > "$WORK/fixture"; IP_FIXTURE=/nonexistent PATH="$WORK/bin" current_address 2>/dev/null)
assert "a failing ip gives an empty answer" "got '$got'" \
    "$([ -z "$got" ] && echo 0 || echo 1)"

echo
echo "$cases checks, $fails failed"
[ "$fails" -eq 0 ]
