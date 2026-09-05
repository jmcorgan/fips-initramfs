#!/bin/sh
#
# Exercise the shared functions that decide whether an SSH key is one
# dropbear will accept, and whether the machine already has one.
#
# These decide what the install writes into another package's directory,
# and a wrong answer is not visible until a remote boot: a machine with
# no usable key admits nobody, and the console is then the only way in.
#
# Needs nothing but a shell.

set -u

REPO=$(cd "$(dirname "$0")/.." && pwd)

fails=0
cases=0

WORK=$(mktemp -d) || exit 1
trap 'rm -rf "$WORK"' EXIT

FIPS_CONF=/nonexistent
export FIPS_CONF
# shellcheck source=lib/functions
. "$REPO/lib/functions"

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

ED25519='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleKeyForTheTest you@host'
RSA='ssh-rsa AAAAB3NzaC1yc2EAAAADAQABexample you@host'
WITHOPTS='command="/usr/bin/cryptroot-unlock",no-pty ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleKeyForTheTest you@host'

# ---------------------------------------------------------- what is a key
assert "an ed25519 key is accepted" "rejected" \
    "$(fips_valid_ssh_key "$ED25519" && echo 0 || echo 1)"
assert "an rsa key is accepted" "rejected" \
    "$(fips_valid_ssh_key "$RSA" && echo 0 || echo 1)"
assert "a key carrying options is accepted" "rejected" \
    "$(fips_valid_ssh_key "$WITHOPTS" && echo 0 || echo 1)"

# The negative cases are the point. Writing any of these into
# authorized_keys produces a machine that looks configured and admits
# nobody, and dropbear's own hook would warn about the file it built.
assert "a comment is not a key" "accepted" \
    "$(fips_valid_ssh_key "# ssh-ed25519 AAAA... you@host" && echo 1 || echo 0)"
assert "an empty line is not a key" "accepted" \
    "$(fips_valid_ssh_key "" && echo 1 || echo 0)"
assert "a private key header is not a key" "accepted" \
    "$(fips_valid_ssh_key "-----BEGIN OPENSSH PRIVATE KEY-----" && echo 1 || echo 0)"
assert "a bare key type with no material is not a key" "accepted" \
    "$(fips_valid_ssh_key "ssh-ed25519" && echo 1 || echo 0)"
assert "an npub is not a key" "accepted" \
    "$(fips_valid_ssh_key "npub1qmc3cvfz0yu2hx96nq3gp55zdan2qclealn7xshgr448d3nh6lks7zel98" && echo 1 || echo 0)"

# ------------------------------------------------- what counts as having one
FIPS_DROPBEAR_KEYS="$WORK/absent"
assert "a missing file names no key" "said it had one" \
    "$(fips_have_ssh_key && echo 1 || echo 0)"

FIPS_DROPBEAR_KEYS="$WORK/empty"
: > "$FIPS_DROPBEAR_KEYS"
assert "an empty file names no key" "said it had one" \
    "$(fips_have_ssh_key && echo 1 || echo 0)"

# A file of comments admits nobody, so the question of which key may
# unlock this machine is still open and the install should still ask.
FIPS_DROPBEAR_KEYS="$WORK/comments"
printf '# put your key here\n\n' > "$FIPS_DROPBEAR_KEYS"
assert "a file of comments names no key" "said it had one" \
    "$(fips_have_ssh_key && echo 1 || echo 0)"

FIPS_DROPBEAR_KEYS="$WORK/onekey"
printf '# a comment\n%s\n' "$ED25519" > "$FIPS_DROPBEAR_KEYS"
assert "a file with a key names one" "said it had none" \
    "$(fips_have_ssh_key && echo 0 || echo 1)"

# A last line with no newline is what an editor or a printf without \n
# leaves behind, and it is still a key.
FIPS_DROPBEAR_KEYS="$WORK/nonewline"
printf '%s' "$ED25519" > "$FIPS_DROPBEAR_KEYS"
assert "a key on an unterminated last line is found" "said it had none" \
    "$(fips_have_ssh_key && echo 0 || echo 1)"

echo
echo "$cases checks, $fails failed"
[ "$fails" -eq 0 ]
