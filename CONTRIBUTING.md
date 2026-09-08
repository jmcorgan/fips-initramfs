# Contributing to fips-initramfs

This is a Debian source package: shell scripts, maintainer scripts and
packaging. There is no compiler and no toolchain to pin, so the barrier
to reading the whole thing is low. Two things about where the code runs
make contributing here different from most shell projects.

**It runs in the initramfs, as root, before the root filesystem is
decrypted.** There is no system to fall back on, no logging beyond the
console, and a mistake strands a machine at a prompt nobody is standing
in front of. The boot scripts print what they did for that reason, and
a change that makes them quieter is a change for the worse.

**The packaging is not the design.** The `.deb` is built and installed
as a Debian package and hooks `initramfs-tools`, `dropbear-initramfs`
and `cryptsetup-initramfs`; the NixOS module under [nixos/](nixos/)
shares none of that machinery and implements the same thing.
[docs/porting.md](docs/porting.md) is what they have in common and is
the thing to read first. Further ports are welcome; see below.

**Linux is not one target.** Even within that family, each distribution
assembles the initramfs
with its own tooling and its own busybox, so a defect here is usually
specific to one of them and invisible from the others. The worked
example is `head`: the premount script used it, Ubuntu's
`busybox-initramfs` has no `head` applet and its image carries no `head`
binary, and the identity check silently failed open on every Ubuntu boot
while Debian was perfectly happy. That shape of bug is the one to expect.

## Quick start

```bash
git clone https://github.com/jmcorgan/fips-initramfs.git
cd fips-initramfs
dpkg-buildpackage -us -uc -b
sh tests/hook-test.sh
sh tests/functions-test.sh
sh tests/premount-test.sh
```

The build needs `debhelper` at compatibility level 13, plus `curl` and
`ca-certificates`, because it downloads the FIPS release it takes `fips`
and `fipsctl` from. `FIPS_DEB` names a local file instead, for an
offline build or to test a FIPS release before it is published.

The three suites need a shell and little else. Each skips with status 77
rather than failing when a prerequisite is missing, so a skip is not a
pass: read what it said.

`ci/run-local.sh` is the wider check, and it is the same script CI runs.
In a container per distribution it builds the package from the declared
`Build-Depends`, installs it both ways the debconf prompt allows,
generates an identity, builds an initramfs and reads what the hook put
in it, then runs the three suites. It needs docker, and a distribution
can be named to run just that one:

```bash
ci/run-local.sh
ci/run-local.sh debian:13
```

Set `FIPS_DEB` to a local `.deb` to build against an unpublished FIPS
release rather than the latest published one.

## Reporting bugs

One issue per bug. Please include:

- **The distribution and release**, and the `dropbear-initramfs`,
  `cryptsetup-initramfs` and `initramfs-tools` versions. This is the
  first thing to establish here and it is usually the answer.
- **The commit or package version** the finding is against.
- **What the console printed**, verbatim, around the FIPS lines.
- **What you expected instead.**

**Boot the machine with `quiet` off** before capturing that console
output. With `quiet` set, `initramfs-tools` suppresses `log_begin_msg`
and `log_success_msg`, and the console then shows nothing at all from
the premount script: neither the success line naming the address nor the
warnings it prints instead. A report taken with `quiet` on cannot
distinguish a broken boot from a silent one. Ubuntu images ship
`quiet splash` in `GRUB_CMDLINE_LINUX_DEFAULT`, so this is a step to
take rather than a default to rely on.

## Submitting pull requests

**One logical change per pull request.** No drive-by reformatting, no
unrelated refactors folded into a fix, and pre-existing warnings in
files you did not touch are not yours to fix here.

### Before opening one

```bash
shellcheck lib/functions tests/*.sh \
    debian/config debian/postinst debian/postrm debian/fetch-fips-deb.sh \
    initramfs/hooks/fips-initramfs \
    initramfs/scripts/init-premount/a_fips \
    initramfs/scripts/init-bottom/fips-initramfs
sh tests/hook-test.sh
sh tests/functions-test.sh
sh tests/premount-test.sh
dpkg-buildpackage -us -uc -b
markdownlint '**/*.md'
```

Or run `ci/run-local.sh`, which does the build and the suites in each
of the five distributions rather than only in yours.

For a change under `nixos/`, none of that applies and this does:

```bash
nix eval ./nixos#nixosConfigurations.example.config.system.build.toplevel.drvPath
markdownlint '**/*.md'
```

**CI covers everything except booting a machine.** GitHub Actions runs
`ci/container-test.sh` on every push, one job per distribution, so a
build or packaging regression on a distribution you did not try will be
caught. What no CI reaches is the unlock itself: it needs a booted
machine with an encrypted root talking to a live mesh, which hosted
runners cannot provide, so those runs happen outside CI and no check
gates them.

That is the part where the burden sits with you. Say in the pull request
which distributions you exercised and how far you got: building the
package, building an image, or booting and unlocking a real machine.
"Not tested on Ubuntu" is a useful thing to write. A confident silence
is not.

### Changing the boot scripts

The hook and the two `initramfs/scripts/` files are the part where the
distribution matrix bites.

- **Every external command they call must exist in the image on all
  five supported distributions.** Check the built image rather than
  `busybox --list`: on Ubuntu, `modprobe` is absent from the applet list
  and present in the image anyway as a `kmod` symlink, so the list
  answers a different question than the one you are asking.
- **A test must assert what the scripts printed, not merely that the
  machine came up.** A test that checks only for a successful unlock
  passes while the identity comparison fails open, which is exactly what
  happened.
- **The hook must never exit non-zero.** It warns and produces an image
  with no FIPS node. A hook that fails leaves `initramfs-tools`
  half-configured and aborts the apt run it belonged to, which is worse
  than the fault it was reporting.

### Changing the NixOS module

[nixos/](nixos/) is a second implementation, not a second packaging of
the first, and the same rules apply to it in NixOS terms.

- **Check it evaluates**, which is what CI does and is the whole of what
  CI can do here:

  ```bash
  nix eval ./nixos#nixosConfigurations.example.config.system.build.toplevel.drvPath
  nix fmt   # nixfmt, if you have it
  ```

- **Nothing in stage 1 may fail the boot.** The build-time checks are
  assertions, because refusing the switch stops the fault at the machine
  you are standing at. Boot-time checks warn and continue, exactly as the
  `.deb`'s do, because that path ends at the console passphrase prompt.
- **An option with no safe default gets no default**, and an assertion
  saying what goes wrong when it is unset. The names in
  `ethernetInterfaces` and `wifi.interface` fail silently when wrong,
  which is the failure mode worth spending an assertion on.
- **The address comparison is not optional.** See
  [docs/porting.md](docs/porting.md); a port that keeps the daemon and
  drops the comparison has kept the easy half.

Evaluation is not a boot. Say in the pull request whether you booted a
machine and unlocked it, and on which NixOS release.

### Bug-fix pull requests

Add a regression test where one is tractable, and say so in the
description when it is not. `tests/premount-test.sh` shows the shape for
this project: it runs the parser with a `PATH` that deliberately has no
`head`, which is the shape of the real fault rather than a proxy for it,
and it lifts the function out of the boot script rather than copying it,
so the test cannot drift from what actually boots.

## Ports to other distributions

**A port to any distribution that encrypts its root with LUKS is
welcome.** Nothing about the idea needs `.deb`: a mesh node started
early enough for an SSH server to bind to it, and torn down before the
real root takes over, is a shape any initramfs can hold.

**[docs/porting.md](docs/porting.md) is the contract.** It states the
design independently of `initramfs-tools` and of dpkg: what goes into
the image and under which names, why the identity has to be persistent
and separate from the host's, the address comparison and the two
failures it exists to catch, the failure policy that keeps console entry
alive, and what is per host and therefore has to be configurable. Read
it before the packaging, and check a port against it rather than against
this tree.

What would have to be rewritten is the packaging and the interface to
the initramfs generator. Fedora, RHEL and SUSE use dracut; Arch uses
mkinitcpio; NixOS builds the image from a module and runs systemd in
stage 1. Each has its own idea of a hook, its own ordering mechanism and
its own way of shipping a file into the image.

What should carry over largely intact is the part worth having: start
the node, wait for its address, **compare that address against the one
written into the image**, and leave console entry alone as the fallback.
A port that keeps the daemon and drops the comparison has kept the easy
half.

Open an issue before writing much of it. The question worth settling
first is whether a port lives here as a second packaging tree or as its
own repository, and that is easier to answer with someone who has
actually looked at the target's generator.

## AI coding assistant policy

Use of AI coding assistants in preparing a contribution is welcome, and
this project uses them itself. What is required is that you do a
thorough manual review of the output before submitting: that the code
does what it claims rather than merely running, that any test added
tests something, that documentation matches behaviour, and that nothing
unrelated came along for the ride. Be ready to discuss every line as if
you wrote it, because for the purposes of accountability you did.

Submissions that show signs of being unreviewed agent output will be
answered in kind, without human review.

## Where the conversation happens

Bugs and design discussion go in the issue tracker. Discussion specific
to a change in flight belongs on the pull request. FIPS itself is at
<https://github.com/jmcorgan/fips>; findings in the daemon or in
`fipsctl` belong there rather than here.

For a suspected vulnerability, see [SECURITY.md](SECURITY.md) and email
rather than opening an issue.
