# fips-initramfs v0.1.0

**Released**: 2026-09-06

v0.1.0 is the first release of `fips-initramfs`. It unlocks a LUKS encrypted
root filesystem over a [FIPS](https://github.com/jmcorgan/fips) mesh, so a
machine that stops at the passphrase prompt during boot can be answered from
anywhere rather than from the local IP network or the console.

**Nothing here is an upgrade.** There is no previous version, no migration and
no compatibility to preserve. What follows is what the package does, what it was
tested against, and what it does not yet cover.

## What it does

A machine with an encrypted root stops during boot and waits for a passphrase.
Answering that prompt remotely is what `dropbear-initramfs` is for, but it needs
a route to the machine on the ordinary IP network: a static address or a DHCP
reservation, a port open through whatever sits in front of it, and a way in that
works before the machine has finished booting.

This package puts a FIPS mesh node inside the initramfs and binds dropbear to
the `fips0` interface it creates. The machine dials out to its bootstrap peers,
so it needs no inbound reachability at all, and it comes up at the same mesh
address on every boot, so the address can be recorded at install time and used
for the life of the machine.

The unlock is one command from a machine with a FIPS daemon on the same mesh:

```bash
ssh root@npub1....fips
```

The key is forced to run `cryptroot-unlock` inside the image, so the session
takes the passphrase and never opens a shell.

**Console passphrase entry is never disabled.** Every failure in this path
leaves the operator at the ordinary cryptsetup prompt, which is what makes the
package safe to install on a machine that can still be reached physically.

## What it bundles

The package carries the `fips` daemon and `fipsctl`, so a machine needs nothing
else installed and nothing done by hand. They are taken from a published FIPS
release at build time and verified against the checksums that release publishes.

This release bundles **FIPS v0.5.1**, and v0.5.1 is the minimum this package
supports. The release a given `.deb` was built against is recorded at
`/usr/share/fips-initramfs/fips-version` and in the `BUILD-INFO.txt` attached
here.

Earlier FIPS releases are refused by the build. v0.5.0 could not run its daemon
on Debian 12 or Ubuntu 22.04, whose glibc is older than the 2.39 that release
required; v0.5.1 needs only 2.34 and clears all five.

A machine that also installs the `fips` package uses that package's binaries
from `/usr/bin` instead, so the node in the initramfs is the same build as the
daemon the booted system runs. The two identities stay separate either way.

The floor is enforced by the build rather than by a package relationship, so a
release below it fails the build instead of installing something inert.

## Tested on

|                           | Debian 12 | Debian 13 | Ubuntu 22.04 | Ubuntu 24.04 | Ubuntu 26.04 |
|---------------------------|:---------:|:---------:|:------------:|:------------:|:------------:|
| Commands the scripts need |    ✅     |    ✅     |      ✅      |      ✅      |      ✅      |
| Builds, installs, images  |    ✅     |    ✅     |      ✅      |      ✅      |      ✅      |
| Installs, boots, unlocks  |    ✅     |    ✅     |      ✅      |      ✅      |      ✅      |

**Installs, boots, unlocks** means the package was installed on a machine with
an encrypted root, the machine came up, was reached over the mesh, and unlocked
with nothing typed on its console, with the address in the console output
matching the one the install reported. That last clause is the point: a test
that checks only for a successful unlock passes while the identity check fails
open.

The first two rows are automated, one distribution per job in GitHub Actions.
The third needs a booted machine with an encrypted root reaching a live mesh,
which no hosted runner can provide, so it is run by hand and no check gates it.

**The `fips` daemon needs glibc 2.34 or later.** Debian 12 ships 2.36 and
Ubuntu 22.04 ships 2.35, so both are clear. A FIPS build needing more than that
installs on those two and cannot start; the package notices at image-build time
and says so, leaving an image with no node so console unlock still works.

## Installing

```bash
sudo apt install ./fips-initramfs_0.1.0_amd64.deb
```

The install asks two questions: the SSH public key allowed to unlock the
machine, and a bootstrap peer. Leaving the peer blank keeps the FIPS public test
mesh, which is fine for trying the package out and should be replaced for a
machine you rely on.

It then prints the name to connect to. **Record it.** It is the only thing
needed afterwards, it does not change, and once the machine is locked there is
no way to read it off:

```text
fips-initramfs: unlock this node at npub1....fips
```

Always connect to the `<npub>.fips` name, never to the bare IPv6 address. A mesh
address has to be resolved to tree coordinates before anything can reach it, and
resolving the name is what drives that resolution.

`debian/README.Debian` is the operator manual and is longer than the README. It
is where to look when a machine does not come back.

## What is not covered

Stated plainly, because a package whose value is that a machine comes back
should be honest about where it has not been exercised:

- **A kernel upgrade regenerating the image.** Never tested.
- **`dpkg -r` against `dpkg -P`.** The behaviour is documented and never tested.
- **Any architecture but amd64.**
- **A real bridged network.** The boot testing runs over QEMU user-mode
  networking.
- **A FIPS schema break.** Nothing mechanically couples the two projects and the
  FIPS configuration schema is not stable, so a much newer FIPS may meet a
  schema break at boot. The bundled release is the one this package was last
  tested against.

## Security

Read `SECURITY.md` and the security section of the README before putting this on
a machine that matters. Three things are worth stating here:

**The initramfs image is not encrypted and the node's private key is in it.**
That is inherent to the design: the node has to come up before anything is
decrypted. Treat the initramfs identity as compromised the moment the machine is
physically taken, and never make it the same key that identifies the running
machine on the mesh. The package keeps them separate by default.

**The passphrase leaves your machine.** Unlocking remotely means sending the LUKS
passphrase over the network, which typing it at the console never does. Two
layers carry it: the SSH session to dropbear, and FIPS's own encryption between
your node and the target npub. Check dropbear's host key the first time you
connect.

**Anyone who knows the npub can reach the node**, and the authorised key is what
stands between that and an unlock. Use a key reserved for this.

## License

MIT.
