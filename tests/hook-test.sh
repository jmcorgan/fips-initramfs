#!/bin/sh
#
# Exercise the initramfs hook against a staging directory, with no image
# build, no root and no dropbear installed.
#
# The hook is the part of this package that can be tested cheaply and
# that carries the most decisions: which pair of binaries it uses,
# whether an unconfigured install is left alone, whether a broken one
# fails loudly, and whether the address written into the image is the
# one dropbear is told to bind.
#
# Needs a fipsctl of FIPS 0.5.0 or later, on PATH or named by FIPSCTL.
#
# What this does NOT cover: the boot scripts, the ordering against
# dropbear, and the unlock itself. Those need a booted image, and that
# gap is not discharged by this script.

set -u

REPO=$(cd "$(dirname "$0")/.." && pwd)
HOOK="$REPO/initramfs/hooks/fips-initramfs"
FUNCTIONS="$REPO/lib/functions"
FIPSCTL="${FIPSCTL:-$(command -v fipsctl || true)}"

fails=0
cases=0

if [ -z "$FIPSCTL" ] || [ ! -x "$FIPSCTL" ]; then
    echo "SKIP: no fipsctl found. Set FIPSCTL to one." >&2
    exit 77
fi

# The hook sources this, so without it every case fails at the same
# point and the run reports three dozen unrelated assertion failures.
# Measured in a container with only debhelper and build-essential: 35 of
# 47 failed, all from this one cause, which reads as a broken package.
HOOK_FUNCTIONS=/usr/share/initramfs-tools/hook-functions
if [ ! -f "$HOOK_FUNCTIONS" ]; then
    echo "SKIP: $HOOK_FUNCTIONS is missing. Install initramfs-tools." >&2
    exit 77
fi

WORK=$(mktemp -d) || exit 1
trap 'rm -rf "$WORK"' EXIT

# Two candidate binary directories, standing in for the two layouts the
# package supports. Each holds a distinguishable daemon, so the image
# can be asked which one was used, and a real fipsctl, because the
# address derivation is not stubbed.
for layout in system private; do
    mkdir -p "$WORK/bin.$layout"
    printf '#!/bin/sh\n# %s\nexit 0\n' "$layout" > "$WORK/bin.$layout/fips"
    chmod 0755 "$WORK/bin.$layout/fips"
    cp "$FIPSCTL" "$WORK/bin.$layout/fipsctl"
done
mkdir -p "$WORK/bin.empty"

: > "$WORK/empty.conf"

check() {
    # check <name> <expected-status> <actual-status>
    cases=$((cases + 1))
    if [ "$2" = "$3" ]; then
        echo "ok   $1"
    else
        echo "FAIL $1: expected exit $2, got $3"
        fails=$((fails + 1))
    fi
}

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

# Build a staging directory. $1 is "configured" or "nopeers".
make_confdir() {
    confdir="$WORK/conf.$1"
    rm -rf "$confdir"
    mkdir -p "$confdir"
    "$FIPSCTL" keygen --dir "$confdir" >/dev/null 2>&1 || return 1
    if [ "$1" = configured ]; then
        cat > "$confdir/fips.yaml" <<YAML
node:
  identity:
    persistent: true
peers:
  - npub: "$(cat "$confdir/fips.pub")"
    addresses:
      - transport: udp
        addr: "test-us01.fips.network:2121"
        priority: 10
      - transport: udp
        addr: "217.77.8.91:2121"
        priority: 20
YAML
    else
        cat > "$confdir/fips.yaml" <<YAML
node:
  identity:
    persistent: true
peers: []
YAML
    fi
    echo "$confdir"
}

# run_hook <confdir> <destdir> <system-bindir> <private-bindir> <conf>
#
# initramfs-tools exports "version" (the kernel version) and creates the
# image's directory skeleton before it runs a hook. Both are emulated:
# without the first, manual_add_modules aborts; without the second,
# copy_exec writes a file where a directory belongs.
run_hook() {
    mkdir -p "$2/usr/bin"
    FIPS_CONFDIR="$1" DESTDIR="$2" \
        FIPS_FUNCTIONS="$FUNCTIONS" \
        FIPS_SYSTEM_BINDIR="$3" FIPS_PRIVATE_BINDIR="$4" FIPS_CONF="$5" \
        verbose=n version="$(uname -r)" \
        sh "$HOOK" >"$WORK/out" 2>"$WORK/err"
}

# Stage what the dropbear hook leaves behind in the image: root's home
# as named by the image's passwd, an authorized_keys inside it, and the
# command a forced line will name. $1 is the destination, $2 the
# authorized_keys content, and $3 "nocryptroot" to leave the command out.
#
# The home directory name is randomised by the real dropbear hook, so a
# fixed name here is enough to prove the path is read and not assumed.
IMAGE_HOME=root-Test123456
stage_dropbear() {
    mkdir -p "$1/etc" "$1/usr/bin" "$1/$IMAGE_HOME/.ssh"
    printf 'root:*:0:0::/%s:/bin/sh\n' "$IMAGE_HOME" > "$1/etc/passwd"
    printf '%s\n' "$2" > "$1/$IMAGE_HOME/.ssh/authorized_keys"
    if [ "${3:-}" != nocryptroot ]; then
        printf '#!/bin/sh\nexit 0\n' > "$1/usr/bin/cryptroot-unlock"
        chmod 0755 "$1/usr/bin/cryptroot-unlock"
    fi
}

image_keys() {
    cat "$1/$IMAGE_HOME/.ssh/authorized_keys"
}

FORCED='command="/usr/bin/cryptroot-unlock"'

# ---------------------------------------------------------------- case 1
# The hook reports its prerequisite, which is how initramfs-tools orders
# it after the dropbear hook.
prereq=$(sh "$HOOK" prereqs 2>/dev/null)
assert "prereqs names dropbear" "got '$prereq'" \
    "$(printf '%s\n' "$prereq" | grep -qw dropbear && echo 0 || echo 1)"
# And the hook that puts cryptroot-unlock in the image. Without it that
# hook runs later and the command is absent when this one looks for it.
assert "prereqs names cryptroot-unlock" "got '$prereq'" \
    "$(printf '%s\n' "$prereq" | grep -qw cryptroot-unlock && echo 0 || echo 1)"

# ---------------------------------------------------------------- case 2
# An emptied peer list leaves the image alone and does not fail. The
# shipped configuration carries working peers, so reaching this means
# someone removed them without adding any.
confdir=$(make_confdir nopeers) || { echo "keygen failed"; exit 1; }
dest="$WORK/dest.nopeers"
run_hook "$confdir" "$dest" "$WORK/bin.system" "$WORK/bin.private" "$WORK/empty.conf"
check "no peers exit 0" 0 "$?"
assert "no peers install nothing" "found $dest/etc/fips" \
    "$([ ! -d "$dest/etc/fips" ] && echo 0 || echo 1)"
assert "no peers warn" "no warning on stderr" \
    "$(grep -q 'no bootstrap peers' "$WORK/err" && echo 0 || echo 1)"

# A configuration naming several addresses for one peer must still be
# read as configured. The shipped defaults have that shape, so a guard
# that only matched a single-address entry would decline every default
# install.
confdir=$(make_confdir configured) || { echo "keygen failed"; exit 1; }
dest="$WORK/dest.multiaddr"
mkdir -p "$dest/etc/dropbear"
run_hook "$confdir" "$dest" "$WORK/bin.system" "$WORK/bin.private" "$WORK/empty.conf"
check "a peer with two addresses counts as configured" 0 "$?"
assert "a peer with two addresses builds the image" "no $dest/etc/fips" \
    "$([ -d "$dest/etc/fips" ] && echo 0 || echo 1)"

# ---------------------------------------------------------------- case 3
# The default layout: the fips package is installed, so the system
# directory is used and the image gets that daemon.
confdir=$(make_confdir configured) || { echo "keygen failed"; exit 1; }
expected=$("$FIPSCTL" address --key "$confdir/fips.pub")

dest="$WORK/dest.system"
mkdir -p "$dest/etc/dropbear"
printf '#DROPBEAR_OPTIONS=""\n' > "$dest/etc/dropbear/dropbear.conf"
run_hook "$confdir" "$dest" "$WORK/bin.system" "$WORK/bin.private" "$WORK/empty.conf"
check "system layout exit 0" 0 "$?"
assert "system layout uses the system daemon" "image daemon is not the system one" \
    "$(grep -q '^# system$' "$dest/usr/bin/fips" 2>/dev/null && echo 0 || echo 1)"

written=$(cat "$dest/etc/fips/mesh-address" 2>/dev/null || true)
assert "mesh-address matches fipsctl" "wrote '$written', wanted '$expected'" \
    "$([ -n "$expected" ] && [ "$written" = "$expected" ] && echo 0 || echo 1)"
# The name the boot script prints and a connection must use. Without it
# the console reports the address alone, which is the one thing a
# connection cannot use: a bare address drives no mesh lookup.
wrote_npub=$(cat "$dest/etc/fips/mesh-npub" 2>/dev/null || true)
want_npub=$(cat "$confdir/fips.pub" 2>/dev/null || true)
assert "mesh-npub matches the public key" "wrote '$wrote_npub', wanted '$want_npub'" \
    "$([ -n "$want_npub" ] && [ "$wrote_npub" = "$want_npub" ] && echo 0 || echo 1)"
assert "config is in the image" "missing $dest/etc/fips/fips.yaml" \
    "$([ -f "$dest/etc/fips/fips.yaml" ] && echo 0 || echo 1)"
assert "key is in the image" "missing $dest/etc/fips/fips.key" \
    "$([ -f "$dest/etc/fips/fips.key" ] && echo 0 || echo 1)"

mode=$(stat -c '%a' "$dest/etc/fips/fips.key" 2>/dev/null || echo "?")
assert "key mode is 600" "mode is $mode" \
    "$([ "$mode" = 600 ] && echo 0 || echo 1)"
assert "dropbear binds the address" "no matching DROPBEAR_OPTIONS line" \
    "$(grep -qF -- "-p [$expected]:22" "$dest/etc/dropbear/dropbear.conf" && echo 0 || echo 1)"

# The appended line must compose with an existing value rather than
# replacing it. Sourcing the file is what dropbear's boot script does.
# Both halves are asserted: checking only for the pre-existing option
# would pass when the hook appended nothing at all.
# shellcheck source=/dev/null
opts=$(DROPBEAR_OPTIONS="-I 300"; . "$dest/etc/dropbear/dropbear.conf"; echo "$DROPBEAR_OPTIONS")
assert "dropbear options compose" "sourced to '$opts'" \
    "$(printf '%s' "$opts" | grep -q -- '-I 300' \
        && printf '%s' "$opts" | grep -qF -- "-p [$expected]:22" \
        && echo 0 || echo 1)"

# ---------------------------------------------------------------- case 4
# No fips package: the node exists only in the initramfs, and the
# binaries come from the private directory.
dest="$WORK/dest.private"
run_hook "$confdir" "$dest" "$WORK/bin.empty" "$WORK/bin.private" "$WORK/empty.conf"
check "private layout exit 0" 0 "$?"
assert "private layout uses the private daemon" "image daemon is not the private one" \
    "$(grep -q '^# private$' "$dest/usr/bin/fips" 2>/dev/null && echo 0 || echo 1)"
assert "private layout still writes the address" "no mesh-address in the image" \
    "$([ "$(cat "$dest/etc/fips/mesh-address" 2>/dev/null)" = "$expected" ] && echo 0 || echo 1)"

# ---------------------------------------------------------------- case 5
# Neither layout is available. The build does NOT fail: a hook that exits
# non-zero leaves initramfs-tools half-configured and aborts the apt run
# it was part of. It leaves the image without a FIPS node and says so.
dest="$WORK/dest.nobin"
mkdir -p "$dest/etc/dropbear"
printf '#DROPBEAR_OPTIONS=""\n' > "$dest/etc/dropbear/dropbear.conf"
run_hook "$confdir" "$dest" "$WORK/bin.empty" "$WORK/bin.empty" "$WORK/empty.conf"
check "no binaries does not fail the build" 0 "$?"
assert "no binaries installs nothing" "found $dest/etc/fips" \
    "$([ ! -d "$dest/etc/fips" ] && echo 0 || echo 1)"
assert "no binaries says how to restore them" "advice missing from stderr" \
    "$(grep -q 'reinstalling it restores them' "$WORK/err" && echo 0 || echo 1)"
assert "no binaries names the directories it searched" "paths missing from stderr" \
    "$(grep -q "$WORK/bin.empty" "$WORK/err" && echo 0 || echo 1)"
assert "no binaries says unlock is console-only" "no console-only warning" \
    "$(grep -q 'console-only' "$WORK/err" && echo 0 || echo 1)"

# Dropbear must not be told to bind an address that will not exist. A
# skipped build that still appended the option would produce an image
# where dropbear fails to start and there is no console fallback message
# to explain it.
assert "a skipped build leaves dropbear alone" "dropbear.conf was appended to" \
    "$(grep -q 'fips-initramfs' "$dest/etc/dropbear/dropbear.conf" && echo 1 || echo 0)"

# ---------------------------------------------------------------- case 6
# An explicit FIPS_BINDIR replaces the search rather than extending it.
# A wrong setting installs nothing, rather than quietly using a different
# daemon than the one the administrator named.
printf 'FIPS_BINDIR=%s\n' "$WORK/bin.empty" > "$WORK/bad.conf"
dest="$WORK/dest.badconf"
run_hook "$confdir" "$dest" "$WORK/bin.system" "$WORK/bin.private" "$WORK/bad.conf"
check "a wrong FIPS_BINDIR does not fail the build" 0 "$?"
assert "a wrong FIPS_BINDIR installs nothing" "found $dest/etc/fips" \
    "$([ ! -d "$dest/etc/fips" ] && echo 0 || echo 1)"

printf 'FIPS_BINDIR=%s\n' "$WORK/bin.private" > "$WORK/good.conf"
dest="$WORK/dest.goodconf"
run_hook "$confdir" "$dest" "$WORK/bin.system" "$WORK/bin.private" "$WORK/good.conf"
check "an explicit FIPS_BINDIR is used" 0 "$?"
assert "FIPS_BINDIR overrides the system directory" "image daemon is not the configured one" \
    "$(grep -q '^# private$' "$dest/usr/bin/fips" 2>/dev/null && echo 0 || echo 1)"

# ---------------------------------------------------------------- case 7
# A configured install with no key installs nothing, rather than an image
# that boots to a node under an identity nobody is connecting to.
confdir=$(make_confdir configured) || { echo "keygen failed"; exit 1; }
rm -f "$confdir/fips.key" "$confdir/fips.pub"
dest="$WORK/dest.nokey"
run_hook "$confdir" "$dest" "$WORK/bin.system" "$WORK/bin.private" "$WORK/empty.conf"
check "a missing key does not fail the build" 0 "$?"
assert "a missing key installs nothing" "found $dest/etc/fips" \
    "$([ ! -d "$dest/etc/fips" ] && echo 0 || echo 1)"
assert "a missing key names the file" "no mention of fips.key" \
    "$(grep -q 'fips.key is missing' "$WORK/err" && echo 0 || echo 1)"

# ---------------------------------------------------------------- case 8
# A missing configuration file is the same shape and must not be an
# error either: the package can be removed but not purged, leaving the
# hook installed with its conffile gone.
dest="$WORK/dest.noconf"
run_hook "$WORK/absent-confdir" "$dest" "$WORK/bin.system" "$WORK/bin.private" "$WORK/empty.conf"
check "a missing config does not fail the build" 0 "$?"
assert "a missing config installs nothing" "found $dest/etc/fips" \
    "$([ ! -d "$dest/etc/fips" ] && echo 0 || echo 1)"

# ------------------------------------------------- forced unlock command
# Every bare key in the image copy is rewritten to run cryptroot-unlock,
# and nothing else in the file is disturbed.
confdir=$(make_confdir configured) || { echo "keygen failed"; exit 1; }
dest="$WORK/dest.forced"
rm -rf "$dest"
stage_dropbear "$dest" "# an operator comment

ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFirstKeyForTheTest first@example
ssh-rsa AAAAB3NzaC1yc2EAAAADAQABsecond second@example"
run_hook "$confdir" "$dest" "$WORK/bin.system" "$WORK/bin.private" "$WORK/empty.conf"
check "a forced command does not fail the build" 0 "$?"

got=$(image_keys "$dest")
assert "the ed25519 key is forced to cryptroot-unlock" "got: $got" \
    "$(printf '%s\n' "$got" | grep -qx "$FORCED ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFirstKeyForTheTest first@example" && echo 0 || echo 1)"
assert "the rsa key is forced too" "got: $got" \
    "$(printf '%s\n' "$got" | grep -qx "$FORCED ssh-rsa AAAAB3NzaC1yc2EAAAADAQABsecond second@example" && echo 0 || echo 1)"
assert "the comment survives" "got: $got" \
    "$(printf '%s\n' "$got" | grep -qx '# an operator comment' && echo 0 || echo 1)"
assert "no key is left unforced" "got: $got" \
    "$(printf '%s\n' "$got" | grep -qE '^ssh-' && echo 1 || echo 0)"

# ---------------------------------------------------------------------
# A key that already carries options is the administrator's decision.
# Prepending to it could duplicate a command= or defeat a restriction,
# so it is left exactly as it is and update-initramfs says so.
existing='no-pty,command="/bin/true" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAdminSetThis admin@example'
dest="$WORK/dest.hasopts"
rm -rf "$dest"
stage_dropbear "$dest" "$existing"
run_hook "$confdir" "$dest" "$WORK/bin.system" "$WORK/bin.private" "$WORK/empty.conf"
check "an options-carrying key does not fail the build" 0 "$?"
assert "an options-carrying key is left byte for byte" "got: $(image_keys "$dest")" \
    "$([ "$(image_keys "$dest")" = "$existing" ] && echo 0 || echo 1)"
assert "leaving it is reported" "no warning in stderr" \
    "$(grep -q 'already carries options' "$WORK/err" && echo 0 || echo 1)"

# ---------------------------------------------------------------------
# The setting turns it off, for bring-up, when a shell in the initramfs
# is the only way to find out why an unlock failed.
printf 'FIPS_FORCE_UNLOCK_COMMAND=no\n' > "$WORK/nounlock.conf"
plain='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIUnforcedKey bringup@example'
dest="$WORK/dest.off"
rm -rf "$dest"
stage_dropbear "$dest" "$plain"
run_hook "$confdir" "$dest" "$WORK/bin.system" "$WORK/bin.private" "$WORK/nounlock.conf"
check "the setting off does not fail the build" 0 "$?"
assert "the setting off leaves the key alone" "got: $(image_keys "$dest")" \
    "$([ "$(image_keys "$dest")" = "$plain" ] && echo 0 || echo 1)"

# ---------------------------------------------------------------------
# cryptsetup-initramfs is recommended, not depended on. Forcing a command
# that is not in the image would close every session at once and leave
# the console as the only way in, without saying why.
dest="$WORK/dest.nocryptroot"
rm -rf "$dest"
stage_dropbear "$dest" "$plain" nocryptroot
run_hook "$confdir" "$dest" "$WORK/bin.system" "$WORK/bin.private" "$WORK/empty.conf"
check "a missing cryptroot-unlock does not fail the build" 0 "$?"
assert "a missing cryptroot-unlock forces nothing" "got: $(image_keys "$dest")" \
    "$([ "$(image_keys "$dest")" = "$plain" ] && echo 0 || echo 1)"
assert "a missing cryptroot-unlock is reported" "no warning in stderr" \
    "$(grep -q 'cryptroot-unlock is not in the image' "$WORK/err" && echo 0 || echo 1)"

# ---------------------------------------------------------------------
# An image with no authorized_keys at all cannot be unlocked remotely.
# The hook says so rather than passing over it, because dropbear's own
# warning names a different cause.
dest="$WORK/dest.nokeys"
rm -rf "$dest"
mkdir -p "$dest/etc"
run_hook "$confdir" "$dest" "$WORK/bin.system" "$WORK/bin.private" "$WORK/empty.conf"
check "no authorized_keys does not fail the build" 0 "$?"
assert "no authorized_keys is reported" "no warning in stderr" \
    "$(grep -q 'carries no authorized_keys' "$WORK/err" && echo 0 || echo 1)"

# ---------------------------------------------------------------------
# An identity generated before fips.pub existed has only the private key.
# The address is derived from that instead, and the image carries no
# name; the boot script then reports the address on its own rather than
# the build failing.
confdir=$(make_confdir configured) || { echo "keygen failed"; exit 1; }
rm -f "$confdir/fips.pub"
dest="$WORK/dest.nopub"
rm -rf "$dest"
run_hook "$confdir" "$dest" "$WORK/bin.system" "$WORK/bin.private" "$WORK/empty.conf"
check "no public key does not fail the build" 0 "$?"
assert "no public key still writes the address" "missing $dest/etc/fips/mesh-address" \
    "$([ -s "$dest/etc/fips/mesh-address" ] && echo 0 || echo 1)"
assert "no public key writes no name" "found $dest/etc/fips/mesh-npub" \
    "$([ ! -e "$dest/etc/fips/mesh-npub" ] && echo 0 || echo 1)"

echo
echo "$cases checks, $fails failed"
[ "$fails" -eq 0 ]
