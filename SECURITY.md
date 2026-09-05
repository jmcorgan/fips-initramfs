# Security Policy

This package runs before the root filesystem is decrypted, as root, and
it puts a network listener there. Anything that lets a party who should
not be able to unlock the disk do so, or that quietly weakens a check
this package advertises, is what we most want to hear about, and we
would rather hear about it privately first.

## Reporting a vulnerability

**Email <johnathan@corganlabs.com>.** Please do not open a public issue
for a suspected vulnerability before we have had a chance to respond.

Useful things to include, none of them required:

- The commit hash the finding is against, and the distribution and
  release you saw it on. Behaviour here varies by distribution more than
  most projects: each one assembles the initramfs with its own tooling
  and its own busybox.
- The file and line you read, and what you read there.
- Whether you reached the defect from something an attacker controls, or
  inferred it from reading. Both are welcome; knowing which saves time.
- What the attacker needs: the ability to reach the node on the mesh,
  physical access to the disk, a local account on the booted system, or
  nothing at all.

Findings produced with automated or AI-assisted tooling are in scope and
welcome. We ask only that you tell us what was machine-generated and
what you checked yourself.

## What to expect

We will acknowledge a report within a few days and tell you whether we
think the finding holds, per item and in our own words. Where we
disagree with a severity we will say why rather than silently
reclassifying it. Where a report is right and we had missed it, we will
say that too.

There is no bug bounty and we cannot offer payment. We are glad to
credit you in the changelog under whatever name you prefer, and equally
glad not to.

Our default is that a finding stays private until a fix is released. Say
in your report if you have a deadline in mind. If we have not responded
at all within two weeks, treat that as a failure on our side and
escalate however you see fit.

## Scope

In scope is everything in this repository: the build-time hook, the two
boot scripts, the shared shell functions, the maintainer scripts, and
`debian/fetch-fips-deb.sh`, which downloads another project's release
artifacts at build time.

The classes we are most interested in:

- **Unlocking without the authorised key**, or obtaining the passphrase.
- **Reaching a shell in the initramfs** rather than `cryptroot-unlock`.
- **A check that fails open.** The premount script compares the address
  the node came up at against the one written into the image, and the
  package's value rests on that comparison actually running. A defect
  that makes it silently pass is a finding even if nothing else breaks.
- **Anything the maintainer scripts do as root** with a value an
  unprivileged user or a remote party can influence.

## Known and accepted

A report about these will get a pointer to the reasoning rather than a
fix. They are consequences of what the package is for.

- **The node's initramfs private key is on an unencrypted `/boot`.** The
  node has to come up before anything is decrypted, so the key cannot
  live behind the encryption. Treat that identity as lost with the
  machine, and keep it separate from the identity the booted system
  uses.
- **`/boot` is not verified.** Anyone who can write to it can replace
  the kernel or the initramfs on a machine with no verified boot. This
  package adds a key to that exposure; it does not create it.
- **The mesh address is reachable by anyone who knows the npub.** The
  authorised key is what stands between that and an unlock.
- **Console passphrase entry is never disabled**, deliberately. Physical
  access to the console unlocks the machine as it always did.

## Belongs elsewhere

- **The FIPS daemon and `fipsctl`** are another project. Report findings
  in them to <https://github.com/jmcorgan/fips>. This package carries
  their release binaries; it does not build them.
- **`dropbear-initramfs`, `cryptsetup-initramfs` and `initramfs-tools`**
  are their distributions' packages. We are interested in how this
  package uses them, not in defects inside them.

## Supported versions

There is no released version yet. Development is on `master`, and a fix
lands there. When releases begin, this section will say which lines
receive fixes.

## Security documentation

The **Security considerations** section of [README.md](README.md) states
the posture as built. It is worth reading before reporting, but it is
not a prerequisite: we would rather have a duplicate report than a
missing one.
