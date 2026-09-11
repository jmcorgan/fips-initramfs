# Porting to another distribution

This document is the contract. It says what a second implementation has
to do to be the same thing as the first one, and it exists because the
interesting half of this package is not the packaging.

The `.deb` in this repository is one implementation of it, for
`initramfs-tools` and `dropbear-initramfs`. Fedora, RHEL and SUSE
assemble the image with dracut, Arch with mkinitcpio, NixOS builds it
from a module and runs systemd in stage 1. Each has its own idea of a
hook, its own ordering mechanism and its own way of getting a file into
the image, and none of that is what makes this work.

What makes it work is below. A port that keeps the daemon and drops the
address comparison has kept the easy half.

## The shape

Three moments, whatever runs them:

1. **Image build.** Put the daemon, its configuration and the node's
   identity key into the image, derive the node's mesh address from
   that identity, and write the address into the image beside the key.
   Bind the SSH server to it.
2. **Early boot, before the passphrase prompt.** Start the node, wait
   for the mesh interface to get an address, and compare that address
   against the one written into the image. Then let the SSH server bind.
3. **Late boot, before the real root takes over.** Stop the node and
   remove the interface, so nothing from the image survives the pivot.

The generator decides how those three are expressed.
`initramfs-tools` gives them as a hook, an `init-premount` script and an
`init-bottom` script. dracut has module setup, a pre-mount hook and a
cleanup hook. A systemd stage 1 has units with an ordering
relationship to `cryptsetup-pre.target`. The names differ; the moments
do not.

## What goes into the image

The daemon reads its identity from the directory holding the
configuration file it was given, so these three names and their shared
directory are not free choices:

| Path in the image | Contents |
| ----------------- | -------- |
| `/etc/fips/fips.yaml` | The node configuration |
| `/etc/fips/fips.key` | The private identity, mode `0600` |
| `/etc/fips/mesh-address` | The address the node must come up at |
| `/etc/fips/mesh-npub` | The name it is reached by, if known |

`mesh-address` and `mesh-npub` are this project's, not the daemon's.
The first is what the boot-time check compares against. The second is
what the boot script prints, because **a connection must use the name**:
resolving `<npub>.fips` through a FIPS DNS responder is what drives the
mesh lookup, and a bare address resolves nothing. A port that prints
only the address invites the one mistake that looks like a broken mesh
and is not.

The daemon binary and whatever it links against also have to be in the
image. `conf/fips.yaml.example` in this repository is the shared
starting point for the configuration and is not Debian-specific.

## The identity

**Persistent, generated once, and not the host's.**

Generated once, because the default is an ephemeral keypair made on
every start. That puts the node at a new address on every boot and makes
it unreachable by construction, and the failure is silent: the daemon
runs perfectly under the new identity. `node.identity.persistent: true`
is therefore not optional.

Not the host's, because the image sits unencrypted on `/boot`, which is
the exposure the encrypted root exists to avoid. A machine that also
runs a FIPS daemon of its own must answer to one npub while it waits for
a passphrase and a different one once it has booted. Treat the initramfs
identity as compromised the moment the disk is physically taken.

`fipsctl keygen --dir <dir>` writes the pair without contacting a
daemon, which is what makes it usable from an install script.
`fipsctl address --key <file>` derives the address, and the public key
is enough — a port never needs to read the private key to learn the
address.

## The address comparison

This is the part that must survive a port.

The check is: the address on the mesh interface after the wait equals
the address written into the image at build time. Not "is the daemon
running", not "does the interface exist".

Two failures leave a healthy daemon and are invisible to any weaker
test:

- **The key file is missing from the image.** The daemon generates a
  fresh identity and runs normally, at an address nobody is connecting
  to. Every liveness check passes.
- **TUN setup failed.** The daemon reports itself degraded and keeps
  going. There is no mesh interface, and the SSH server is bound to an
  address that does not exist.

Both produce a machine that boots to its passphrase prompt and cannot be
reached, which is discovered when it is already remote and locked. The
comparison is how that becomes a line on the console instead.

The wait must be bounded, and its expiry must not stop the boot.

## The SSH server

Bound to the node's mesh address, admitting a key the administrator
supplied, and **restricted to unlocking**.

The `.deb` prepends `command="/usr/bin/cryptroot-unlock"` to each key in
the image's copy of `authorized_keys`. A port should do the equivalent
with whatever its distribution uses to take a passphrase — the point is
that the initramfs shell is a root shell with the mesh already attached,
so an unrestricted session is a foothold on the mesh and not only on
this machine.

Two rules the `.deb` follows and a port should:

- **Rewrite the copy inside the image, never the administrator's file.**
  The file on the running system belongs to the administrator, or to
  another package.
- **Leave a key line that already carries options exactly as written.**
  It expresses an intent of its own that prepending to could defeat.

A way to turn the restriction off belongs in the port's configuration.
A shell in the initramfs is how a failed unlock gets diagnosed, and
bring-up needs one.

The SSH implementation itself is not part of the contract. dropbear is
what `initramfs-tools` offers; a generator that puts OpenSSH in the
image instead is equally fine.

## Failure policy

**Console passphrase entry is never disabled, and no failure in this
path may take it away.** That is what makes the thing safe to install on
a machine you can still reach, and it is the property to check a port
against first.

It has two consequences that are easy to get wrong:

- **A build-time failure produces an image with no FIPS node, loudly —
  it does not fail the build.** An image with no node stops at the
  console prompt, which is visible on the first boot. An image built
  around a missing key looks identical to a working one until the
  machine is remote and locked. In the `.deb` there is a packaging
  reason on top: a hook that exits non-zero leaves `initramfs-tools`
  half-configured and aborts the apt run it belonged to. A generator
  without that hazard should still prefer the loud no-op, for the
  boot-time reason.
- **A boot-time failure prints why and continues.** The daemon's own
  first lines are worth printing rather than pointing at a log the
  operator cannot reach: on the path where this matters there is no
  shell on that console and, usually, no operator in front of it.

## Teardown

Stop the daemon, wait for it to exit, then remove the interface.

Waiting matters: the daemon drains its peers before it exits, and
deleting the interface underneath that races a live data path. Anything
still running at the pivot holds a reference to the initramfs across it,
and on a machine that runs its own FIPS daemon the one starting
afterwards may hold a different identity.

## What is per host, and must therefore be configurable

None of these have a safe default, and several fail silently when wrong,
which is the worst combination. A port has to let the administrator set
them and should say what happens when they are not set.

| Setting | Why it cannot be defaulted |
| ------- | -------------------------- |
| Bootstrap peers | A node whose peers have all moved converges with nobody, and the recovery is physical access to the console. |
| Authorised SSH key | Without one there is no remote unlock at all. |
| LUKS device | Whatever the distribution already uses to name it. |
| Network interface names | Per machine. A name that does not exist is not an error anyone sees: nothing binds, the node never appears on the mesh, and the console prompt is the only way in. |
| NIC and TUN kernel modules | Generator-dependent. `initramfs-tools` with `MODULES=most` covers it; a generator that includes only what is asked for needs the driver named, and `tun` in every case. |

Interface names are the one worth dwelling on, because the FIPS ethernet
transport is worth having in an initramfs and it is the piece a port is
most likely to leave out. It speaks L2 directly, so it needs no DHCP
lease, no route and no resolver — all things early boot is bad at. It
does need the interface named. `conf/fips.yaml.example` carries the
shape as a comment; a port that generates the configuration should turn
it into a list the administrator sets, and one entry per wired port.

## What the configuration deliberately turns off

`conf/fips.yaml.example` is the shared reference and its comments give
the reasoning. In summary: Nostr-mediated rendezvous needs DNS, a
plausible wall clock and relay reachability, none of which hold that
early in a boot, so peers are static. The DNS responder is dead weight
in an image where nothing resolves `.fips` names. The control socket
needs an explicit path, because the default resolves to somewhere that
does not exist in an initramfs and a node whose control socket fails to
bind still routes — you simply cannot query it.

## Versions

**FIPS 0.5.1 or later.** `fipsctl address` first shipped in 0.5.0 and
an install needs it; the 0.5.1 binaries need glibc 2.34 where 0.5.0
needed 2.39, which is what makes them run on the older distributions
here.

Nothing mechanically couples the two projects and the FIPS
configuration schema is not yet stable, so a much newer FIPS may meet a
schema break at boot. A port should record which FIPS it was built
against, the way this one writes it to
`/usr/share/fips-initramfs/fips-version`.

## Testing a port

The thing that has to be exercised outside CI is the unlock: a booted
machine with an encrypted root reaching a live mesh, which no hosted
runner provides. Everything up to that — building, installing,
generating an identity, building an image and reading what went into it
— a container can do, and `ci/container-test.sh` is the worked example.

Two habits from this tree carry over:

- **Assert what the boot scripts printed, not merely that the machine
  came up.** A test that checks only for a successful unlock passes
  while the identity comparison fails open, which is exactly what
  happened here.
- **Check the built image for every external command the boot scripts
  call.** Ubuntu's `busybox-initramfs` has no `head` applet and its
  image carries no `head` binary; Debian's does. The premount script
  used `head`, and the identity check silently failed open on every
  Ubuntu boot while Debian was perfectly happy. Distribution-specific
  faults of that shape are the ones to expect.

## Where a port lives

Either a second tree in this repository beside `debian/`, or its own
repository. **Open an issue before writing much of it**, so that gets
settled with someone who has looked at the target's generator.

A second tree here should keep the shared parts shared — this document
and `conf/fips.yaml.example` are the shared parts today — and put
everything else under a directory of its own. `CHANGELOG.md` is already
grouped by area for the same reason: a second packaging target gets its
own heading beside `Debian packaging` rather than being folded into it.
