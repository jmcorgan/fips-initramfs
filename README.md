# fips-initramfs

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Status](https://img.shields.io/badge/status-v0.1.0-green.svg)](#status)

Unlock a LUKS encrypted root filesystem over a
[FIPS](https://github.com/jmcorgan/fips) mesh, from anywhere, removing
the need for local console access (but not replacing it).

## What it does

A Linux machine with an encrypted root stops during boot and waits for a
passphrase. Answering that prompt remotely is what `dropbear-initramfs`
is for, but it leaves you needing a route to the machine on the ordinary
IP network: a static address or a DHCP reservation, a port open through
whatever sits in front of it, and a way in that works before the machine
has finished booting.

This package puts a FIPS mesh node inside the initramfs and binds
dropbear to the `fips0` interface it creates. The machine dials out to
its bootstrap peers, so it needs no inbound reachability at all, and it
comes up at the same mesh address on every boot, so you can write that
address down at install time and use it for the life of the machine.

**Console passphrase entry is never disabled.** Every failure in this
path leaves the operator at the ordinary cryptsetup prompt, which is
what makes it safe to install on a machine you can still reach.

**The machine does not need FIPS installed**, and most machines running
this will not have it. The package carries its own `fips` and `fipsctl`,
and the node exists only inside the initramfs, for the length of the
unlock. Nothing is left running once the real root is up.

A machine that does run FIPS is equally fine, and there the two
identities are separate and should stay that way.

## Quick start

**On NixOS**, none of this section applies: there is no `.deb` to
install and the module is the whole of it. Go to
[nixos/README.md](nixos/README.md).

**On the machine to be unlocked.** Download the `.deb` from the
[latest release](https://github.com/jmcorgan/fips-initramfs/releases/latest)
and install it:

```bash
curl -sSfLO https://github.com/jmcorgan/fips-initramfs/releases/download/v0.1.0/fips-initramfs_0.1.0_amd64.deb
sudo apt install ./fips-initramfs_0.1.0_amd64.deb
```

The release also carries `SHA256SUMS`, and
[Building from source](#building-from-source) covers building it yourself
instead.

The `.deb` already carries `fips` and `fipsctl`, taken from a published
FIPS release at build time and checked against the checksums that release
publishes, so the install downloads nothing else and needs no other
package.

The install asks two questions: the SSH public key allowed to unlock the
machine, and a bootstrap peer. Leaving the peer blank keeps the FIPS
public test mesh. What the peer prompt accepts, and what to edit
afterwards for anything it cannot express, is in
[debian/README.Debian](debian/README.Debian).

It then prints the name to connect to. **Record it.** It is the only
thing you need afterwards, and it does not change:

```text
fips-initramfs: unlock this node at npub1....fips
```

**On the machine you unlock from**, you need a running FIPS daemon
connected to the public mesh, or to the mesh which contains the node you
optionally configured to peer with. Then, once the machine under test
has rebooted and is waiting:

```bash
ssh root@npub1....fips
```

That is the whole unlock. The key is forced to run `cryptroot-unlock`
inside the image, so the session takes the passphrase and never opens a
shell.

It is recommended you create a host specific SSH client configuration
file that contains the FIPS `npub.fips` address, the identity you
configured, and the user specified as root:

```text
# ~/.ssh/config.d/unlock-server1
Host unlock-server1
    HostName npub1....fips
    User root
    IdentityFile ~/.ssh/id_ed25519_unlock
    IdentitiesOnly yes
```

A file under `~/.ssh/config.d/` is read only if `~/.ssh/config` begins
with `Include config.d/*`; without that line the file is ignored in
silence. Putting the block straight into `~/.ssh/config` always works.

`IdentitiesOnly` is there because ssh otherwise offers every key your
agent holds before the one named here, and dropbear closes the
connection once it has refused enough of them.

The unlock is then `ssh unlock-server1`.

In any case, always connect to the `<npub>.fips` address, not to the
IPv6 address. This is required for the connecting FIPS node to properly
resolve and establish the mesh connection.

Before putting this on a machine that matters, read
[Security considerations](#security-considerations).

## Building from source

The build produces one `.deb`, and that file is what you install. Its
version comes from `debian/changelog`, so a build of the trunk is a
development version ahead of the last release; a build of a release tag
carries that release's version. Two things it needs either way: a Debian or
Ubuntu system, and network access, because the build downloads `fips`
and `fipsctl` from a published FIPS release and verifies them against
the checksums that release publishes.

### On a Debian or Ubuntu machine

```bash
git clone https://github.com/jmcorgan/fips-initramfs
cd fips-initramfs

# Install exactly what debian/control declares, rather than a list
# copied out of it that can fall behind.
sudo apt install build-essential devscripts equivs
sudo mk-build-deps --install --remove \
    --tool "apt-get -y --no-install-recommends" debian/control

dpkg-buildpackage -us -uc -b
```

The package lands one directory up. Install it with:

```bash
sudo apt install ../fips-initramfs_*_amd64.deb
```

### In a container, leaving the host alone

Same file, in `out/`, with no build tools installed on the machine you
run it from:

```bash
mkdir -p out
docker run --rm -v "$PWD:/src:ro" -v "$PWD/out:/out" debian:13 sh -c '
    set -e
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq build-essential devscripts equivs
    cp -a /src /work && cd /work
    mk-build-deps --install --remove \
        --tool "apt-get -y -qq --no-install-recommends" debian/control
    dpkg-buildpackage -us -uc -b
    cp ../fips-initramfs_*.deb /out/'
```

The source tree is mounted read only and copied inside the container,
because the build writes into it and leaves its artifacts one directory
up. The `.deb` is written to `out/` owned by root.

### Which FIPS release ends up in the package

The latest published one by default, and **0.5.1 is the floor**: the
build refuses anything older, because the daemon in 0.5.0 cannot start
on Debian 12 or Ubuntu 22.04. Two variables change that:

- `FIPS_TAG=v0.5.1` bundles that release rather than the latest.
- `FIPS_DEB=/path/to/fips_x.y.z_amd64.deb` uses a local file and
  downloads nothing, for an offline build or to try a release candidate.

The built package records what it took in
`/usr/share/fips-initramfs/fips-version`, and a release also states it in
the `BUILD-INFO.txt` attached alongside the `.deb`.

### Checking a build against the released file

**A build from a clean checkout of a tag reproduces the file published
for that tag.** Measured for v0.1.0: a fresh clone checked out at
`v0.1.0` and built with the container recipe above produced the same
sha256 as the `.deb` attached to the release. So a package you built
yourself can be checked against the `SHA256SUMS` on the release page:

```bash
sha256sum fips-initramfs_0.1.0_amd64.deb   # compare with SHA256SUMS
```

Build from a modified working tree and it will not match, which is the
point of saying "clean checkout" rather than "the source".

### Running the tests

```bash
sh tests/hook-test.sh      # and functions-test.sh, premount-test.sh
```

They build no image, need no root and need no dropbear, and each skips
with status 77 rather than failing when a prerequisite is absent.

`ci/run-local.sh` runs a fuller check in a container per distribution:
it builds the package, installs it, generates an identity, builds an
image and reads what the hook put in it, then runs those three suites.
It needs docker and takes a few minutes per distribution. Name one to
run just that one, as `ci/run-local.sh debian:13`. **It is a test runner
and not a way to obtain a package**: each container is discarded when it
finishes, and the `.deb` it builds goes with it. Use one of the two
recipes above to get a file you can install.

## How it works

Three pieces, run by `initramfs-tools` at three different moments:

- **A build-time hook** puts the daemon, its configuration and the
  identity key into the generated image, and appends the node's address
  to dropbear's options inside that image. It never fails the image
  build: when something it needs is missing it warns and produces an
  image with no FIPS node, because a hook that exits non-zero leaves
  `initramfs-tools` half-configured and aborts the apt run it belonged
  to.
- **A premount script** starts the node, waits for `fips0` to get an
  address, and **compares that address against the one written into the
  image**. The comparison is the point. A FIPS daemon whose key is
  missing generates a new identity and runs perfectly at the wrong
  address, and a daemon whose TUN setup failed reports itself degraded
  and keeps going. Neither is caught by asking whether the daemon is
  alive.
- **An init-bottom script** stops the node and removes the interface
  before `switch_root`, so nothing from the initramfs survives into the
  booted system.

On a machine that also installs the `fips` package, the hook takes that
package's binaries from `/usr/bin` in preference to the bundled ones, so
the node in the initramfs is the same build as the daemon the booted
system runs.

**The identities stay separate either way.** The install generates a
keypair under `/etc/fips-initramfs/` and leaves the host's
`/etc/fips/fips.key` alone, so the machine answers to one npub while it
waits for a passphrase and a different one once it has booted. That is
deliberate: the initramfs key ships inside an unencrypted image on an
unencrypted `/boot`, which is the exposure the encrypted root exists to
avoid, so it should not also be the key that identifies the running
machine on the mesh.

## Project structure

```text
docs/         Platform-neutral: what any implementation has to do
conf/         Node configuration example, shared, and the package's own conffile
debian/       Source package: control, rules, maintainer scripts, README.Debian
initramfs/    The three scripts: build-time hook, premount, init-bottom
lib/          Shared shell functions, sourced by the hook and by postinst
tests/        Three suites: hook, shared functions, premount
nixos/        The NixOS module, its flake and its operator manual
```

[docs/porting.md](docs/porting.md) is the one part of this tree that is
not about `.deb` at all. It states the design as a contract — what goes
into the image, the address comparison, the failure policy, what is per
host and must be configurable — so that a port to another initramfs
generator has something to be checked against rather than a package to
be read.

**[debian/README.Debian](debian/README.Debian) is the operator manual**,
and it is longer than this file. It covers setting a machine up, the
bootstrap peer prompt and the peer list, what the boot scripts check and
what each warning means, script ordering, what the node adds to the
image, the rebuild trigger, and removing against purging. It is where to
look when a machine does not come back.

## Status

Built, installed and unlocked over the mesh on all five distributions,
against the public FIPS test mesh.

**Two implementations, at different stages.** The `.deb` is the one
with a release, a distribution matrix and CI behind it. The NixOS module
in [nixos/](nixos/) is newer, and its own
[README](nixos/README.md#status) says what has and has not been
exercised. They share [docs/porting.md](docs/porting.md), which is the
contract, and `conf/fips.yaml.example`, and nothing else: a NixOS
machine installs no `.deb` and a Debian machine evaluates no Nix.

| | `.deb` | NixOS |
| --- | --- | --- |
| Targets | Debian 12, 13; Ubuntu 22.04, 24.04, 26.04 | NixOS with systemd stage 1 |
| Image generator | `initramfs-tools` hook | a NixOS module |
| SSH server | `dropbear-initramfs` | OpenSSH, via `boot.initrd.network.ssh` |
| Install | `apt install ./fips-initramfs_*.deb` | a flake input and a module |
| CI | build, install and image, per distribution | evaluation of the example configuration |
| Booted and unlocked | all five distributions | yes, before the module was generalised |

**A port to any other distribution that encrypts its root with LUKS is
welcome**, and what has to be rewritten is the packaging and the
interface to the initramfs generator, not the design. Start from
[docs/porting.md](docs/porting.md) and
[CONTRIBUTING.md](CONTRIBUTING.md).

**Targets Debian 12 and 13 and Ubuntu 22.04, 24.04 and 26.04.** Linux is
not one target even within that family: each distribution assembles the
initramfs with its own tooling and its own busybox, and a fault in this
package is normally specific to one of them.

|                           | Debian 12 | Debian 13 | Ubuntu 22.04 | Ubuntu 24.04 | Ubuntu 26.04 |
|---------------------------|:---------:|:---------:|:------------:|:------------:|:------------:|
| `dropbear-initramfs`      |  2022.83  |  2025.89  |   2020.81    |   2022.83    |   2025.89    |
| Commands the scripts need |    ✅     |    ✅     |      ✅      |      ✅      |      ✅      |
| Builds, installs, images  |    ✅     |    ✅     |      ✅      |      ✅      |      ✅      |
| Installs, boots, unlocks  |    ✅     |    ✅     |      ✅      |      ✅      |      ✅      |

**Installs, boots, unlocks** means the package was installed on a
machine with an encrypted root, the machine came up, was reached over
the mesh, and unlocked with nothing typed on its console, with the
address in the console output matching the one the install reported.
All five were exercised that way on 2026-09-06.

**All five run the bundled daemon**, which is what FIPS 0.5.1 changed.
Its binaries need glibc 2.34, and the oldest distribution here is Ubuntu
22.04 at 2.35. The 0.5.0 daemon needed 2.39 and so could not start on
Debian 12 or Ubuntu 22.04; the package noticed at image-build time and
left an image with no node, so console unlock still worked. That is why
0.5.1 is the floor.

The rows are covered differently, and only the first two are automated.
**Commands the scripts need** and **builds, installs, images** are
checked by `ci/container-test.sh`, which builds the package, installs it
both ways the debconf prompt allows and reads what the hook put in the
image. GitHub Actions runs it on every push, one distribution per job,
and `ci/run-local.sh` drives the same script across five containers on a
development machine. **Installs, boots, unlocks** needs a booted machine
with an encrypted root reaching a live mesh, which no hosted runner can
provide, so it is run outside CI and no check gates it.

Not yet exercised: a kernel upgrade regenerating the image, `dpkg -r`
against `dpkg -P`, and any architecture other than amd64.

**FIPS 0.5.1 or later is required**, and the build refuses anything
below it. Two things put the floor there: `fipsctl address`, which the
install needs and which first shipped in 0.5.0, and the glibc 2.34
requirement above, which arrived in 0.5.1. Nothing mechanically couples
the two projects, and the FIPS configuration schema is not yet stable,
so a much newer FIPS may meet a schema break at boot.

## Security considerations

**The initramfs image is not encrypted, and the node's private key is in
it.** That is the whole point of the design: the node has to come up
before anything is decrypted. `/boot` is readable by anyone with the
disk, so treat the initramfs identity as compromised the moment the
machine is physically taken. It grants what any mesh identity grants,
which is why it must not be the same key that identifies the running
machine (see [How it works](#how-it-works)).

**This does not change what an unencrypted `/boot` already meant.**
Anyone who can write to it could already replace the kernel or the
initramfs on a machine with no verified boot. This package adds a key to
what is exposed there; it does not create the exposure.

**The unlock key is authorised to unlock and to do nothing else.** The
hook prepends `command="/usr/bin/cryptroot-unlock"` to each key in the
image's `authorized_keys`, so a session takes the passphrase and never
reaches a shell. **One exception**: a key line that already carries
options is left exactly as written, because it expresses an intent of
your own that prepending to could defeat. If you write your own options,
you own the restriction.

**The passphrase leaves your machine.** Unlocking remotely means sending
the LUKS passphrase over the network, which typing it at the console
never does. Two layers carry it: the SSH session to dropbear, and FIPS's
own encryption between your node and the target npub. Check dropbear's
host key the first time you connect, so that something else answering at
that name cannot collect the passphrase.

**Anyone who knows the npub can reach the node.** It sits on the mesh
with dropbear listening, and the authorised key is what stands between
that and an unlock. Use a key reserved for this, not a general-purpose
one.

**Console entry always remains.** Physical access to the console unlocks
the machine with the passphrase exactly as it did before, and no failure
in this path can take that away.

## License

MIT, see [LICENSE](LICENSE).
