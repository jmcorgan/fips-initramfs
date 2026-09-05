#!/bin/sh
#
# Fetch the FIPS release .deb that this package takes its binaries from.
#
# The package carries fips and fipsctl so that a machine can unlock over
# the mesh with no fips package installed and nothing done by hand. They
# come from a published release rather than from a build here, for two
# reasons: the node in the initramfs is then the same build people run
# as the daemon, and this package needs no Rust toolchain to build.
#
# The download is verified against the release's own checksums file. A
# release older than the floor below is refused, because its fipsctl has
# no offline address command and the image build would then decline to
# include a node at all.
#
# Writes vendor/fips_<version>_<arch>.deb and vendor/fips-version, and
# does nothing when a verified file is already there.
#
# Usage: debian/fetch-fips-deb.sh [architecture]
#   FIPS_DEB    use this file instead of downloading anything
#   FIPS_TAG    fetch this release rather than the latest
#   FIPS_REPO   default jmcorgan/fips
#   GITHUB_TOKEN or GH_TOKEN
#               sent as a bearer token when asking the API which release
#               is latest. Optional, and only affects the rate limit:
#               unauthenticated calls are counted per source address, so
#               a shared address runs out. Observed on a GitHub-hosted
#               runner, where five parallel jobs asking at once got a 403
#               while the same build passed minutes earlier.

set -eu

REPO="${FIPS_REPO:-jmcorgan/fips}"
FLOOR=0.5.0
ARCH="${1:-$(dpkg-architecture -qDEB_HOST_ARCH)}"
TOP=$(cd "$(dirname "$0")/.." && pwd)
VENDOR="$TOP/vendor"

say() {
    echo "fetch-fips-deb:" "$@" >&2
}

die() {
    say "$@"
    exit 1
}

mkdir -p "$VENDOR"

# A file named directly is used as it is. This is how a build runs
# offline, and how a release candidate gets tested before it is
# published.
if [ -n "${FIPS_DEB:-}" ]; then
    [ -f "$FIPS_DEB" ] || die "$FIPS_DEB does not exist."
    version=$(dpkg-deb -f "$FIPS_DEB" Version)
    arch=$(dpkg-deb -f "$FIPS_DEB" Architecture)
    [ "$arch" = "$ARCH" ] || die "$FIPS_DEB is $arch, and this build is $ARCH."
    cp -- "$FIPS_DEB" "$VENDOR/fips_${version}_${ARCH}.deb"
    printf '%s\n' "$version" > "$VENDOR/fips-version"
    say "using $FIPS_DEB, version $version."
    exit 0
fi

tag="${FIPS_TAG:-}"
if [ -z "$tag" ]; then
    api="https://api.github.com/repos/$REPO/releases/latest"
    # No jq on a plain Debian build machine, so the field is read with
    # sed. The tr splits a single-line response into one field per line.
    # An unauthenticated call is rate limited by source address, so pass
    # a token when there is one. Nothing here needs the token's
    # permissions; the repository is public.
    auth=""
    token="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
    [ -n "$token" ] && auth="Authorization: Bearer $token"
    tag=$(curl -sSfL ${auth:+-H "$auth"} "$api" | tr ',' '\n' \
        | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
        | head -1)
    [ -n "$tag" ] || die "could not read the latest release tag from $api."
fi
version="${tag#v}"

dpkg --compare-versions "$version" ge "$FLOOR" \
    || die "release $tag is older than $FLOOR, whose fipsctl first had the offline address command."

deb="fips_${version}_${ARCH}.deb"
target="$VENDOR/$deb"
sums="$VENDOR/checksums-linux-${version}.txt"
base="https://github.com/$REPO/releases/download/$tag"

[ -f "$sums" ] || curl -sSfL -o "$sums" "$base/checksums-linux.txt" \
    || die "could not download the checksums for $tag."

verify() {
    # sha256sum -c reads the name from the file, so it runs in the
    # directory holding the download and checks only the one line.
    grep -F " $deb" "$sums" > "$VENDOR/.sum" 2>/dev/null || return 1
    ( cd "$VENDOR" && sha256sum -c .sum ) >/dev/null 2>&1
}

if [ -f "$target" ] && verify; then
    say "$deb is already here and its checksum matches."
else
    say "downloading $deb from $tag."
    curl -sSfL -o "$target" "$base/$deb" \
        || die "could not download $deb from $tag. Does that release build $ARCH?"
    verify || die "the checksum of $deb does not match the one $tag publishes."
fi

rm -f "$VENDOR/.sum"
printf '%s\n' "$version" > "$VENDOR/fips-version"
say "using FIPS $version for $ARCH."
