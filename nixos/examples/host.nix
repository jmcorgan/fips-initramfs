# An example host, and the flake's evaluation check.
#
# Everything outside the services.fips.initrd block is here only so that a
# NixOS configuration evaluates: a bootloader, a root filesystem, and the LUKS
# device the module asserts on. On a real machine those come from your own
# configuration and from hardware-configuration.nix, and this file is worth
# reading for the fips block alone.
{ ... }:
{
  # ── the parts a real machine already has ────────────────────────────────
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # The mapping the passphrase unlocks. It belongs to the configuration that
  # declares the filesystem, not to this module: two declarations of one device
  # give two passphrase prompts and a cryptsetup failure.
  boot.initrd.luks.devices."root".device = "/dev/disk/by-uuid/00000000-0000-0000-0000-000000000000";

  fileSystems."/" = {
    device = "/dev/mapper/root";
    fsType = "ext4";
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-uuid/0000-0000";
    fsType = "vfat";
  };

  system.stateVersion = "25.05";

  # ── the part this project is about ──────────────────────────────────────
  services.fips.initrd = {
    enable = true;

    # The key you will unlock from. Reserve one for this rather than reusing a
    # general-purpose key: it names something that may unlock this machine.
    ssh.authorizedKeys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleExampleExampleExampleExampleExa you@workstation"
    ];

    # Per machine, and wrong silently: a name that does not exist binds
    # nothing, and the node never appears where you are looking for it. Get
    # them from `ip -o link`. Leave the list empty if this machine reaches the
    # mesh only through its default route.
    ethernetInterfaces = [ "enp1s0" ];

    # The default is the FIPS public test mesh, which is fine for trying this
    # out and is not what to rely on. Give the initrd the same peers the booted
    # system uses.
    #
    # peers = [
    #   {
    #     npub = "npub1...";
    #     alias = "relay";
    #     connect_policy = "auto_connect";
    #     addresses = [
    #       { transport = "udp"; addr = "relay.example.org:2121"; priority = 10; }
    #       { transport = "udp"; addr = "203.0.113.10:2121"; priority = 20; }
    #     ];
    #   }
    # ];

    # Uncomment during bring-up, and turn both off once the unlock works. The
    # console shell is unauthenticated at the keyboard; the SSH shell turns a
    # session that could only answer the prompt into a root shell on the mesh.
    #
    # debug.consoleShell.enable = true;
    # debug.sshShell.enable = true;
  };
}
