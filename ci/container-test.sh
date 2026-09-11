#!/bin/sh
#
# Build, install and inspect the package on whatever distribution this is
# running on. Everything a container can hold: the build, the debconf
# answers, the identity generation, the image the hook produces, and the
# three test suites.
#
# Run it inside a Debian or Ubuntu container as root, from the top of the
# source tree. ci/run-local.sh drives it across all five distributions;
# the GitHub workflow runs it one distribution per job.
#
# It cannot boot anything, so it cannot catch what only a booted machine
# shows. What it does catch is a per-distribution difference in what the
# image ends up containing, which is where this package's defects have
# actually been.

set -eu

[ "$(id -u)" = 0 ] || { echo "must run as root; it installs packages" >&2; exit 2; }
command -v apt-get >/dev/null || { echo "not a Debian or Ubuntu system" >&2; exit 2; }
[ -f debian/control ] || { echo "run from the top of the source tree" >&2; exit 2; }

export DEBIAN_FRONTEND=noninteractive
KV=6.0.0-fake
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
ok()   { pass=$((pass + 1)); echo "ok   $1"; }
bad()  { fail=$((fail + 1)); echo "FAIL $1"; }
# Takes the description first and then the command to run, rather than a
# $? from the line above: that form is fragile, and any command between
# the condition and the check silently changes the answer.
check() { _desc=$1; shift; if "$@"; then ok "$_desc"; else bad "$_desc"; fi; }
section() { echo; echo "== $1"; }

# shellcheck source=/dev/null
distro=$(. /etc/os-release && echo "$PRETTY_NAME")
echo "== $distro"

section "prerequisites"
apt-get update -qq
# What the build itself needs comes from debian/control, installed with
# mk-build-deps, so the declared Build-Depends are the thing under test.
# Installing a list written here instead would mean an incomplete
# declaration still built, and the package would fail on a machine that
# happened not to have the missing library. That is not hypothetical:
# libdbus-1-3 was missing from Build-Depends and Debian 12 could not
# build the package, while Debian 13 could, purely because something
# else had pulled the library in.
apt-get install -y -qq \
    build-essential dpkg-dev fakeroot devscripts equivs lintian \
    initramfs-tools dropbear-initramfs cryptsetup-initramfs cpio \
    openssh-client >/dev/null
apt-get install -y -qq busybox-initramfs >/dev/null 2>&1 \
    || apt-get install -y -qq busybox >/dev/null

if mk-build-deps --install --remove \
        --tool "apt-get -y -qq -o Debug::pkgProblemResolver=yes --no-install-recommends" \
        debian/control > "$WORK/builddeps.log" 2>&1; then
    ok "the declared Build-Depends install"
else
    bad "the declared Build-Depends install"
    tail -20 "$WORK/builddeps.log"
    exit 1
fi

# dpkg-checkbuilddeps proves the declared Build-Depends are installed. It
# does NOT prove the declaration is sufficient, and the two are easy to
# confuse: with libdbus-1-3 missing from the field this check passed and
# the build then failed in dh_shlibdeps. The build itself is what tests
# sufficiency, which is why build deps are installed from debian/control
# rather than from a list written here.
dpkg-checkbuilddeps 2>"$WORK/checkbuilddeps.log"
if [ -s "$WORK/checkbuilddeps.log" ]; then
    bad "the declared Build-Depends are satisfied"
    cat "$WORK/checkbuilddeps.log"
else
    ok "the declared Build-Depends are satisfied"
fi

# A container has no kernel. mkinitramfs needs a modules directory to
# exist and a kernel config to grep for a compressor; without the second,
# Debian 12 refuses to build an image at all while the other four fall
# back to gzip with a warning.
section "faking a kernel"
mkdir -p "/lib/modules/$KV"
for f in modules.dep modules.order modules.builtin; do : > "/lib/modules/$KV/$f"; done
depmod "$KV" 2>/dev/null || true
mkdir -p /boot
printf 'CONFIG_RD_GZIP=y\nCONFIG_RD_ZSTD=y\n' > "/boot/config-$KV"
echo "kernel $KV"

section "build"
if dpkg-buildpackage -us -uc -b > "$WORK/build.log" 2>&1; then
    ok "the package builds"
else
    bad "the package builds"
    tail -30 "$WORK/build.log"
    exit 1
fi
deb=""
for candidate in ../fips-initramfs_*.deb; do
    [ -f "$candidate" ] || continue
    deb="$candidate"
    break
done
if [ -n "$deb" ]; then
    ok "a .deb was produced: $(basename "$deb")"
else
    bad "a .deb was produced"
    exit 1
fi

# Whether the daemon this release bundles can actually run here. A FIPS
# release built against a newer C library installs cleanly, generates an
# identity and builds an image, and then fails to start at boot with
# nothing pointing at the cause. Debian 12 ships glibc 2.36 and Ubuntu
# 22.04 ships 2.35, against a daemon built for 2.39.
bundled_daemon=debian/fips-initramfs/usr/lib/fips-initramfs/bin/fips
daemon_runs=no
if [ ! -x "$bundled_daemon" ]; then
    bad "the bundled FIPS daemon is in the built tree"
elif "$bundled_daemon" --version >/dev/null 2>&1; then
    daemon_runs=yes
    ok "the bundled FIPS daemon runs on this distribution"
else
    # Not a failure of this package. The release was built elsewhere and
    # needs a newer C library than this distribution ships. What IS this
    # package's business is behaving correctly about it, which is what
    # the image checks below assert instead.
    ok "the bundled FIPS daemon does not run here, so degradation is what is tested"
    "$bundled_daemon" --version 2>&1 | sed -n '1,2p' | sed 's/^/     /'
fi

fipsver=$(cat usr/share/fips-initramfs/fips-version 2>/dev/null \
    || cat debian/fips-initramfs/usr/share/fips-initramfs/fips-version 2>/dev/null || echo unknown)
echo "     bundled FIPS version: $fipsver"

# dh_installinitramfs adds an "activate-noawait update-initramfs" trigger
# because the package ships files under /usr/share/initramfs-tools. A
# container has no image for it to act on, so assert it is declared
# rather than watching it fire.
if dpkg-deb --ctrl-tarfile "$deb" | tar -xO ./triggers 2>/dev/null \
        | grep -q 'update-initramfs'; then
    ok "the package declares an update-initramfs trigger"
else
    bad "the package declares an update-initramfs trigger"
fi

ssh-keygen -q -t ed25519 -N '' -C ci@container -f "$WORK/id" </dev/null
pubkey=$(cat "$WORK/id.pub")

# Extract the generated image and answer questions about it. Called after
# each install, so it takes the label to report under.
inspect_image() {
    label="$1"
    rm -rf "$WORK/x"; mkdir -p "$WORK/x"
    img=/boot/initrd.img-$KV
    # The package's trigger runs "update-initramfs -u", which updates the
    # images that exist and does nothing when none do. A container starts
    # with none, so the image has to be created here. That the package
    # declares the trigger at all is checked separately, above.
    rm -f "$img"
    if ! update-initramfs -c -k "$KV" > "$WORK/mkinitramfs-$label.log" 2>&1; then
        bad "$label: an image was generated"
        tail -15 "$WORK/mkinitramfs-$label.log"
        return 0
    fi
    [ -f "$img" ] || { bad "$label: an image was generated"; return 0; }
    ok "$label: an image was generated"
    ( cd "$WORK/x" && (unmkinitramfs "$img" . 2>/dev/null \
        || zcat "$img" | cpio -idm --quiet) )

    find_in_image() { find "$WORK/x" -path "*/$1" \( -type f -o -type l \) 2>/dev/null | head -1; }

    # The boot scripts ship either way; the node does not.
    for want in scripts/init-premount/a_fips scripts/init-bottom/fips-initramfs; do
        check "$label: image carries $want" [ -n "$(find_in_image "$want")" ]
    done

    if [ "$daemon_runs" = no ]; then
        # The designed behaviour where the daemon cannot run: the hook
        # warns, leaves the node out, and lets the build finish, so the
        # machine boots to its console prompt rather than to a node that
        # cannot start. Assert that rather than the node being present.
        check "$label: no daemon in the image, which is correct here" \
            [ -z "$(find_in_image usr/bin/fips)" ]
        check "$label: no identity key left in the image" \
            [ -z "$(find_in_image etc/fips/fips.key)" ]
        return 0
    fi

    for want in usr/bin/fips etc/fips/fips.yaml etc/fips/fips.key etc/fips/mesh-address; do
        check "$label: image carries $want" [ -n "$(find_in_image "$want")" ]
    done

    key=$(find_in_image etc/fips/fips.key)
    if [ -n "$key" ]; then
        check "$label: the identity key in the image is 0600" [ "$(stat -c%a "$key")" = 600 ]
    fi

    # The address the hook wrote must be the address the installed
    # identity actually has. This is the property the boot scripts check
    # at runtime, checked here at build time.
    addr_file=$(find_in_image etc/fips/mesh-address)
    if [ -n "$addr_file" ]; then
        fipsctl=$(command -v fipsctl || echo /usr/lib/fips-initramfs/bin/fipsctl)
        expected=$("$fipsctl" address --key /etc/fips-initramfs/fips.pub 2>/dev/null || echo "")
        if [ -n "$expected" ]; then
            check "$label: the address in the image matches the installed identity" [ "$(cat "$addr_file")" = "$expected" ]
        else
            bad "$label: fipsctl could not derive the address to compare against"
        fi
    fi

    conf=$(find_in_image etc/dropbear/dropbear.conf)
    if [ -n "$conf" ]; then
        check "$label: dropbear is bound to the node's address" grep -q 'DROPBEAR_OPTIONS.*-p \[' "$conf"
    else
        bad "$label: image carries etc/dropbear/dropbear.conf"
    fi

    # Not /root/.ssh: dropbear-initramfs randomises root's home inside the
    # image, so the path is /root-<random>/.ssh. The hook reads root's home
    # out of the image's own passwd for this reason, and a test that
    # hardcodes /root asserts something the package deliberately does not
    # assume. Observed on Debian 13: home was /root-CK50YWeowv.
    keys=$(find "$WORK/x" -path '*/.ssh/authorized_keys' 2>/dev/null | head -1)
    if [ -n "$keys" ]; then
        check "$label: the unlock key is forced to cryptroot-unlock" grep -q '^command="[^"]*cryptroot-unlock"' "$keys"
    else
        bad "$label: image carries root's authorized_keys"
    fi

    # Every external command the two boot scripts call. This is the check
    # the head defect of 2026-09-01 would have failed on Ubuntu, and it
    # reads the image rather than busybox --list, because on Ubuntu
    # modprobe is absent from the applet list and present here anyway.
    missing=""
    for cmd in ip sed cat sleep kill rm readlink modprobe; do
        [ -n "$(find_in_image "bin/$cmd")" ] || [ -n "$(find_in_image "sbin/$cmd")" ] \
            || missing="$missing $cmd"
    done
    check "$label: every command the boot scripts call is in the image${missing:+ (missing:$missing)}" [ -z "$missing" ]
}

section "install with no peer given: the shipped defaults are kept"
printf 'fips-initramfs fips-initramfs/peer-npub string\n' | debconf-set-selections
printf 'fips-initramfs fips-initramfs/ssh-key string %s\n' "$pubkey" | debconf-set-selections
mkdir -p /etc/dropbear/initramfs
if apt-get install -y -qq "$deb" > "$WORK/install1.log" 2>&1; then
    ok "default install succeeds"
else
    bad "default install succeeds"; tail -20 "$WORK/install1.log"
fi
check "default install created the configuration" [ -f /etc/fips-initramfs/fips.yaml ]
check "default install generated an identity" [ -f /etc/fips-initramfs/fips.key ]
check "default install kept the shipped peers" grep -q 'npub1' /etc/fips-initramfs/fips.yaml
check "default install authorised the given key" grep -q "$(printf '%s' "$pubkey" | awk '{print $2}')" /etc/dropbear/initramfs/authorized_keys
inspect_image "default"

section "install with a peer given: the answer replaces the defaults"
apt-get purge -y -qq fips-initramfs > "$WORK/purge.log" 2>&1
check "purge removed the configuration" [ ! -e /etc/fips-initramfs/fips.yaml ]
peer_npub=npub1qmc3cvfz0yu2hx96nq3gp55zdan2qclealn7xshgr448d3nh6lks7zel98
{
  printf 'fips-initramfs fips-initramfs/peer-npub string %s\n' "$peer_npub"
  printf 'fips-initramfs fips-initramfs/peer-transport string udp\n'
  printf 'fips-initramfs fips-initramfs/peer-address string 198.51.100.7:2121\n'
} | debconf-set-selections
if apt-get install -y -qq "$deb" > "$WORK/install2.log" 2>&1; then
    ok "install with a peer succeeds"
else
    bad "install with a peer succeeds"; tail -20 "$WORK/install2.log"
fi
check "the given peer address is in the configuration" grep -q '198.51.100.7:2121' /etc/fips-initramfs/fips.yaml
check "the given peer replaced the shipped ones rather than joining them" [ "$(grep -c 'npub:' /etc/fips-initramfs/fips.yaml)" = 1 ]
inspect_image "peer"

section "test suites"
# hook-test.sh skips with 77 when it cannot find a fipsctl, and a skip is
# not a pass. The installed package carries one, so point the suite at it
# rather than letting it opt out.
FIPSCTL=$(command -v fipsctl || echo /usr/lib/fips-initramfs/bin/fipsctl)
export FIPSCTL
check "a fipsctl is available to the suites: $FIPSCTL" [ -x "$FIPSCTL" ]
for t in hook-test functions-test premount-test init-bottom-test; do
    if sh "tests/$t.sh" > "$WORK/$t.log" 2>&1; then
        ok "tests/$t.sh"
    elif [ $? = 77 ]; then
        bad "tests/$t.sh skipped, which is not a pass"
        tail -5 "$WORK/$t.log"
    else
        bad "tests/$t.sh"
        tail -20 "$WORK/$t.log"
    fi
done

section "result"
echo "$distro: $pass passed, $fail failed"
[ "$fail" = 0 ] || exit 1
