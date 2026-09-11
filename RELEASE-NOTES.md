# fips-initramfs v0.1.1

**Released**: 2026-09-11

v0.1.1 fixes one defect in v0.1.0. A machine booted with no network link showed
no passphrase prompt until DHCP gave up, which took minutes and looked like a
hung boot. The prompt now appears at once, the network keeps being retried in
the background so a cable plugged in later still gives remote unlock, and remote
unlock on a working network becomes available a few seconds later than before.

**Upgrading needs nothing done by hand.** Installing the package rebuilds the
initramfs, and the next boot uses the fixed image.

## What was wrong

The premount script that starts the node configured the network first, in the
foreground. `initramfs-tools` runs premount scripts one at a time and the
cryptsetup passphrase prompt comes after them, so nothing could prompt until
that step returned.

With no network link, it returned only when DHCP timed out. Read from each
distribution's `initramfs-tools`, that is 265 seconds on Debian 12 and 13 and
Ubuntu 22.04, and 300 seconds on Ubuntu 24.04 and 26.04. When no network device
exists at all, it first waits up to 180 seconds more for one to appear. Until
then there was no prompt: on the machine this was reported from, the graphical
splash screen stayed blank. Plugging in a cable let the boot continue.

On the Ubuntu 24.04 test machine, with v0.1.0 installed and the link turned off,
the prompt appeared 318 seconds after the machine was started.

Any machine booted without its cable hit this. A machine whose only network is
Wi-Fi hit it on every boot, because the initramfs does not bring up Wi-Fi.

## What changed

**The premount script no longer configures the network in the foreground.**
`dropbear-initramfs` already makes that attempt in the background, for exactly
this reason, and its attempt now comes first.

The node starts without waiting for a link. `fips0` takes its address from the
node's identity, and a peer that cannot be reached yet is retried until it can.
So the passphrase prompt appears as soon as boot reaches it, with or without a
network.

**The premount script keeps retrying the network in the background.**
`initramfs-tools` makes one set of DHCP attempts and then stops for good. In
v0.1.0 two sets ran back to back, the premount script's own and then dropbear's,
so a cable plugged in within roughly ten minutes still got a network. With only
dropbear's set, a cable plugged in after about five minutes would never have
got one. The premount script now waits for dropbear's attempt to finish and, if
it failed, tries again until a network comes up. Its output goes to
`/run/fips-network.log` rather than over the passphrase prompt. When the disk is
unlocked at the console before any network comes up, the init-bottom script
stops the retry and everything it started, so nothing from the initramfs keeps
configuring interfaces in the booted system.

## What it costs

**With a network present, remote unlock becomes available about 10 to 15
seconds later than in v0.1.0.** On the test machines, the unlocking host reached
the initramfs after 2 or 3 of its 5-second retries, against 0 or 1 in the runs
checked before the fix. The likely cause is that the node now starts before DHCP has
finished, so its first attempt to reach its peers fails and it waits before
trying again. On a network where DHCP is slower, the delay may be longer; that
was not measured.

**A cable plugged in late gives remote unlock minutes later, not at once.**
With the link restored seven minutes into boot, the test machines were reached
over the mesh about five minutes after that. By then the node waits up to 300
seconds between attempts to reach its peers, so the network coming up is noticed
at its next attempt.

The console prompt pays neither cost.

## Upgrading

```bash
curl -sSfLO https://github.com/jmcorgan/fips-initramfs/releases/download/v0.1.1/fips-initramfs_0.1.1_amd64.deb
sudo apt install ./fips-initramfs_0.1.1_amd64.deb
```

Installing over v0.1.0 asks nothing and keeps the node identity, so the machine
unlocks at the same `<npub>.fips` name as before. The package rebuilds the
initramfs as part of the install.

**If you applied the workaround**, commenting out `configure_networking` in
`/usr/share/initramfs-tools/scripts/init-premount/a_fips`, there should be
nothing to undo. That file belongs to the package and is not a configuration
file, so dpkg replaces an edited copy on upgrade. This follows from how dpkg
treats such files and was not tried on a machine carrying the edit. The
workaround alone does not include the background retry; the upgrade does.

A first install on a new machine is unchanged from v0.1.0: it asks for the SSH
public key allowed to unlock the machine and a bootstrap peer, then prints the
name to connect to. The README's quick start covers it.

## What it bundles

**FIPS v0.5.1, unchanged from v0.1.0**, and still the minimum this package
supports. The release a given `.deb` was built against is recorded at
`/usr/share/fips-initramfs/fips-version` and in the `BUILD-INFO.txt` attached
here.

## Tested on

|                                     | Debian 12 | Debian 13 | Ubuntu 22.04 | Ubuntu 24.04 | Ubuntu 26.04 |
|-------------------------------------|:---------:|:---------:|:------------:|:------------:|:------------:|
| Commands the scripts need           |    ✅     |    ✅     |      ✅      |      ✅      |      ✅      |
| Builds, installs, images            |    ✅     |    ✅     |      ✅      |      ✅      |      ✅      |
| Installs, boots, unlocks            |    ✅     |    ✅     |      ✅      |      ✅      |      ✅      |
| Boots with the link down, unlocks   |    ✅     |    ✅     |      ✅      |      ✅      |      ✅      |
| Link restored late, unlocks         |  not run  |    ✅     |   not run    |      ✅      |   not run    |
| Console unlock with no link         |  not run  |    ✅     |   not run    |      ✅      |   not run    |

The first four rows were run against this release's commit on 2026-09-11. The
container level reported 44 checks passed and none failed on each distribution,
and the boot level passed on all five machines, both with the link up and with
it down. The last two rows were run the same day against the same boot scripts, before
this release's documentation was written.

**Installs, boots, unlocks** has the same meaning as for v0.1.0: the package was
installed on a machine with an encrypted root, the machine came up, was reached
over the mesh, and unlocked with nothing typed on its console, with the address
in the console output matching the one the install reported.

**Boots with the link down, unlocks** is new, and it is the test for this fix.
The machine reboots with its network link turned off and must show the
passphrase prompt within 90 seconds. The link stays off until 90 seconds, is
turned back on, and the machine is then unlocked over the mesh. The test was
checked by breaking it: with the old foreground call put back into one image,
it failed.

Before release, the fix passed that test on all five machines. With the link
down, the prompt appeared 21 to 30 seconds after the reboot. Measured from
power-on, the same change took Ubuntu 24.04 from 318 seconds to 17. Installing
v0.1.1 over v0.1.0 rebuilt the initramfs on all five.

**Link restored late, unlocks** keeps the link off for 420 seconds, past the
point where dropbear's DHCP attempt gives up, then unlocks over the mesh. It was
run on Debian 13 and Ubuntu 24.04, one for each DHCP client `initramfs-tools`
uses. Without the retry, Ubuntu 24.04 was never reached; with it, both were.

**Console unlock with no link** types the passphrase at the console while the
retry is part-way through its own DHCP attempt, then checks after boot that no
process from the initramfs is still running. The check was shown to find a
deliberately planted process first.

As before, the first two rows are automated in GitHub Actions and the last two
need a booted machine with an encrypted root reaching a live mesh, so they are
run by hand and no check gates them.

**A field report, not a test:** a user unlocked Ubuntu Desktop 22.04.5 LTS
remotely over FIPS with v0.1.0 while the graphical passphrase screen was
showing. None of the test machines boots with the graphical splash, so this is
the only evidence that the two coexist. v0.1.1 changes when the prompt appears,
not how it is shown.

## What is not covered

- **Real network hardware.** The link was turned off and on through QEMU, and
  the boot testing runs over QEMU user-mode networking. No USB Ethernet adapter
  or bridged network was tested.
- **A machine with no network device at all**, such as a USB adapter left
  unplugged. It goes through the same removed call and the same retry, but every
  test machine has a network device.
- **A late link on Debian 12, Ubuntu 22.04 and Ubuntu 26.04**, which were not run
  through the late-link and console-unlock tests. Each uses the same DHCP client
  as one of the two machines that were.
- **A slow boot after a console unlock with no network, when the kernel command
  line sets `ip=`.** `initramfs-tools` configures the network again after the root
  is mounted, and some Ubuntu server images carry a second script that does the
  same, so the boot can wait out further DHCP attempts. On the Ubuntu 24.04 test
  machine it was still waiting more than eight minutes after the passphrase was
  typed. This package does not add it and does not
  change it; a desktop install without `ip=` is not affected.
- **Carried over from v0.1.0:** a kernel upgrade regenerating the image,
  `dpkg -r` against `dpkg -P`, any architecture but amd64, and a FIPS schema
  break.

## Security

Nothing in the security model changes in this release. Read `SECURITY.md` and
the security section of the README before putting this on a machine that
matters. The initramfs image is not encrypted and the node's private key is in
it, the passphrase leaves your machine when you unlock remotely, and anyone who
knows the npub can reach the node, so use a key reserved for this.

## License

MIT.
