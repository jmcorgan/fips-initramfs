# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

This is the changelog for the project as a whole. Entries are grouped by area,
and `Debian packaging` covers the `.deb` only: a second packaging target would
get its own heading beside it rather than being folded in. `debian/changelog` is
the Debian-specific view of the same releases and is what an installed machine
carries.

## [Unreleased]

### Fixed

#### Initramfs

- The console passphrase prompt no longer waits for the network. The premount
  script configured the network in the foreground, so a machine booted with no
  network link sat at a blank screen for four to eight minutes while DHCP timed
  out. The network is now brought up in the background by dropbear's own boot
  script, and the prompt appears at once.
- A network link that comes up late in boot still gives remote unlock.
  initramfs-tools stops trying DHCP after four and a half to five minutes, so
  the premount script now keeps retrying in the background until a network comes
  up, and init-bottom stops the retry when the disk is unlocked at the console.

### Changed

#### Initramfs

- With a network present, remote unlock now becomes available about ten to
  fifteen seconds later than before. The node starts before DHCP completes, so
  its first attempt to reach its peers fails and it waits to retry.

## [0.1.0] - 2026-09-06

Initial release. The package puts a FIPS mesh node inside the initramfs and
binds dropbear to the `fips0` interface it creates, so a LUKS encrypted root
filesystem can be unlocked over the mesh rather than over the local IP network.
The machine dials out to its bootstrap peers and needs no inbound reachability.

### Added

#### Initramfs

- A build-time `initramfs-tools` hook that puts the daemon, its configuration
  and the node identity into the generated image, and appends the node's
  address to dropbear's options inside that image.
- The hook never fails the image build. When something it needs is missing it
  warns and produces an image with no FIPS node, because a hook that exits
  non-zero leaves `initramfs-tools` half-configured and aborts the apt run it
  belonged to.
- A premount script, `a_fips`, that starts the node, waits for `fips0` to get
  an address, and compares that address against the one written into the image.
  On success it prints `Success: FIPS node up at <npub>.fips (<address>)`.
- The address comparison catches the two failures that leave a healthy daemon
  running: a missing key file, where the daemon generates a new identity and
  runs normally at an address nobody is connecting to, and a failed TUN setup,
  where there is no `fips0` at all.
- An init-bottom script that stops the node and removes the interface before
  `switch_root`, so nothing from the initramfs survives into the booted system.
- The forced command `cryptroot-unlock` is prepended to each key in the image's
  copy of `authorized_keys`, so an SSH session takes the passphrase and never
  reaches a shell. The file in `/etc/dropbear/initramfs` is never touched. A key
  line that already carries options is left exactly as written, and
  `FIPS_FORCE_UNLOCK_COMMAND=no` turns the whole behaviour off during bring-up.
- Binary resolution searches `/usr/bin` before the bundled copies, so a machine
  that also installs the `fips` package runs the same build in the initramfs as
  on the booted system. `FIPS_BINDIR` replaces the search rather than extending
  it: a directory named there and found wanting is an error.
- Console passphrase entry is never disabled. Every failure in this path falls
  through to the ordinary cryptsetup prompt.

#### Debian packaging

- A native source package built with `dpkg-buildpackage`, hooking
  `initramfs-tools`, `dropbear-initramfs` and `cryptsetup-initramfs`.
- The package carries the `fips` daemon and `fipsctl` in
  `/usr/lib/fips-initramfs/bin`, taken from a published FIPS release at build
  time and verified against the checksums that release publishes. The release
  that was used is recorded at `/usr/share/fips-initramfs/fips-version`.
- `debian/fips-tag` pins the FIPS release a tagged build bundles. It is part of
  the commit that gets tagged; an ordinary build takes the latest release.
- A FIPS version floor of 0.5.0, enforced by `debian/fetch-fips-deb.sh`, which
  is where `fipsctl address` first shipped. `postinst` cannot compute the
  address it writes into `DROPBEAR_OPTIONS` without it.
- `FIPS_DEB` names a local `.deb` instead of downloading one, for an offline
  build or to test a release candidate.
- A debconf prompt for the SSH public key allowed to unlock the machine, written
  to `/etc/dropbear/initramfs/authorized_keys`, which belongs to no package. It
  is asked only when that file names no key and never overwrites one. An answer
  that is not a public key is refused with an explanation rather than written.
- A debconf prompt for a bootstrap peer, in three parts: npub, transport and
  address. A supplied peer replaces the shipped ones; blank keeps the FIPS
  public test mesh. An npub without an address is refused as a partial answer.
- `postinst` generates an identity keypair under `/etc/fips-initramfs/` only
  when there is none, and prints the name the machine unlocks at. The host's
  `/etc/fips/fips.key` is left alone, so the initramfs identity and the running
  machine's identity stay separate.
- A second install asks nothing and keeps the identity. Purging is what resets
  it: `dpkg -r` keeps the identity and rebuilds the image without a node,
  `dpkg -P` removes it.
- `/etc/fips-initramfs/fips.yaml` is created by the install from a shipped
  example rather than being a conffile, so an upgrade never produces a merge
  prompt for it and never overwrites an edited file. The only conffile is
  `fips-initramfs.conf`.

#### Testing and CI

- Three shell test suites: `tests/hook-test.sh`, `tests/functions-test.sh` and
  `tests/premount-test.sh`. They build no image, need no root and need no
  dropbear, and each skips with status 77 rather than failing when a
  prerequisite is absent.
- `tests/premount-test.sh` runs the address parser with a `PATH` that has no
  `head`, which is the shape of the fault that Ubuntu's busybox produced.
- `ci/container-test.sh`, which builds the package, installs it both ways the
  debconf prompt allows, builds an image and reads back what the hook put in it.
- GitHub Actions runs the container level on every push, one distribution per
  job, across Debian 12 and 13 and Ubuntu 22.04, 24.04 and 26.04.
- `ci/run-local.sh` drives the same script across five containers on a
  development machine, one distribution at a time when named.
- `.github/workflows/release.yml`, which builds a tagged release against the
  pinned FIPS version and attaches the `.deb`, its checksum and `BUILD-INFO.txt`
  to a draft GitHub release.
- Boot-level verification, where a machine with an encrypted root is reached
  over a live mesh and unlocked, is performed outside CI. No hosted runner can
  provide it and no check gates it.

#### Project

- `README.md` with a per-distribution compatibility table stating what was
  tested rather than what is claimed.
- `debian/README.Debian`, the operator manual: setting a machine up, the
  bootstrap peer prompt, what each boot warning means, script ordering, what the
  node adds to the image, and removing against purging.
- `SECURITY.md`, `CONTRIBUTING.md` and an MIT `LICENSE`.
- This changelog, following Keep a Changelog format.
