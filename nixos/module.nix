# A FIPS mesh node in the NixOS initrd, for remote LUKS unlock over the mesh.
#
# This is the NixOS implementation of the contract in ../docs/porting.md.
# The three moments that document names are here:
#
#   image build   this module: it puts the daemon, the configuration and the
#                 identity into the initrd, and NixOS's own initrd-ssh module
#                 puts sshd in beside them.
#   early boot    fips-mesh.service, ordered before cryptsetup-pre.target, and
#                 fips-mesh-check.service, which makes the address comparison.
#   teardown      systemd stage 1 stops its units at switch-root, and the TUN
#                 device goes with the process that opened it.
#
# What differs from the .deb, and why:
#
#   * The image generator is a NixOS module rather than an initramfs-tools
#     hook, so there is no hook to fail and no apt run to abort. The
#     build-time failures the .deb turns into warnings are assertions here:
#     they stop `nixos-rebuild switch` at the machine you are standing at,
#     which is the same protection by a different route. Nothing at boot time
#     is allowed to fail: see fips-mesh-check.service.
#   * sshd is OpenSSH, from boot.initrd.network.ssh, rather than dropbear.
#   * The unlock restriction is root's login shell, not a forced command in
#     authorized_keys. It lands the session on systemd's password agent, which
#     answers the prompt and nothing else. debug.sshShell.enable is the
#     off-switch, and is the analogue of FIPS_FORCE_UNLOCK_COMMAND=no.
#   * The expected mesh address is derived in the initrd from the public key
#     that sits beside the private one, rather than written into the image at
#     build time. It cannot be derived at build time: the key deliberately
#     lives outside the Nix store, so evaluation never sees it. Deriving it in
#     the initrd is strictly the stronger check, because it also catches a
#     public key that does not match the private key next to it.
#
# IMPORTANT: this module enables boot.initrd.systemd.enable (systemd stage 1).
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.fips.initrd;

  yamlFormat = pkgs.formats.yaml { };

  # One `lanN` transport per wired interface, so each gets its own socket and
  # neighbour state.
  ethernetTransports = builtins.listToAttrs (
    lib.imap0 (i: iface: {
      name = "lan${toString i}";
      value = {
        interface = iface;
        listen = true;
        announce = true;
        auto_connect = true;
        accept_connections = true;
        # Deliberately short. The daemon starts about 1.4 seconds into the
        # boot, before systemd-networkd has the links up, so the first beacon
        # always fails with ENETDOWN. At the default interval the next one
        # lands after the initrd is gone and the peer never hears us. At two
        # seconds the node re-announces as soon as carrier appears, and the
        # cost is a tiny L2 frame in an initrd that lives for seconds.
        beacon_interval_secs = 2;
      };
    }) cfg.ethernetInterfaces
  );

  # The defaults are the ones ../conf/fips.yaml.example argues for, in Nix.
  # Keep the two in step: that file is the shared reference, and its comments
  # carry the reasoning that the option descriptions here only summarise.
  baseSettings = {
    node = {
      # Required. The default is an ephemeral keypair generated on every
      # start, which puts the node at a new address on every boot and makes it
      # unreachable by construction. The failure is silent: the daemon runs
      # normally under the new identity.
      identity.persistent = true;
      # Stage 1 only has to be reachable for the unlock. It does not forward
      # for anyone.
      leaf_only = true;
      log_level = cfg.logLevel;
      # Required. Left unset the path resolves to a fallback that does not
      # exist here. A node whose control socket fails to bind still routes;
      # you simply cannot query it. RuntimeDirectory below creates /run/fips.
      control.socket_path = "/run/fips/control.sock";
      # mDNS on the local broadcast domain, which is sub-second and needs no
      # relay. It is not a substitute for peers: see the peers option.
      discovery.lan.enabled = true;
      # Binds the datagram API socket, which is what fipsctl talks to from
      # the console debug shell.
      native_api.enabled = true;
    };

    tun = {
      # Required. The default is false, which yields a healthy daemon with no
      # mesh interface at all and nothing for sshd to be reached on.
      enabled = true;
      name = cfg.interface;
      # Pinned rather than discovered. The session carries a passphrase and a
      # little terminal traffic, so the value costs nothing, and path
      # discovery in early boot is one more thing to stall on.
      mtu = 1280;
    };

    dns.enabled = cfg.dns.enable;

    transports = {
      udp = {
        bind_addr = "0.0.0.0:2121";
        accept_connections = true;
      };
      # For a network where UDP egress is blocked. Equal to UDP; the daemon
      # picks whichever path is available. TCP has no accept_connections
      # field: setting bind_addr opens the listening socket.
      tcp.bind_addr = "0.0.0.0:8443";
    }
    // lib.optionalAttrs (ethernetTransports != { }) { ethernet = ethernetTransports; }
    // lib.optionalAttrs cfg.bluetooth.enable {
      ble = {
        adapter = cfg.bluetooth.adapter;
        advertise = true;
        scan = true;
        auto_connect = true;
        accept_connections = true;
      };
    };

    peers = cfg.peers;
  };

  configFile = yamlFormat.generate "fips-initrd.yaml" (lib.recursiveUpdate baseSettings cfg.settings);

  # D-Bus wants a machine-id. The initrd is RAM-only and thrown away, so a
  # fixed dummy is fine; it identifies nothing that outlives the boot.
  dbusMachineId = pkgs.writeText "machine-id" ''
    00000000000000000000000000000001
  '';

  btInit = pkgs.writeShellScript "fips-initrd-bluetooth-init" ''
    ${pkgs.util-linux}/bin/rfkill unblock bluetooth 2>/dev/null || true
    ${pkgs.coreutils}/bin/mkdir -p /var/lib/bluetooth || true
  '';

  # An OPEN network, deliberately. An initrd sits on an unencrypted /boot, so
  # a PSK put here would be readable by anyone holding the disk. Link-layer
  # secrecy is not what protects this node: the mesh is authenticated and
  # encrypted end to end on top of whatever carries it. scan_ssid=1 so a
  # hidden SSID is still found.
  wpaConf = pkgs.writeText "fips-initrd-wpa_supplicant.conf" ''
    ctrl_interface=/run/wpa_supplicant
    update_config=0

    network={
      ssid="${cfg.wifi.ssid}"
      key_mgmt=NONE
      scan_ssid=1
    }
  '';

  wifiInit = pkgs.writeShellScript "fips-initrd-wifi-init" ''
    ${pkgs.util-linux}/bin/rfkill unblock wifi 2>/dev/null || true
  '';

  # Root's login shell for SSH sessions in the initrd, and the reason a
  # session cannot become a shell. systemd's agent answers the passphrase
  # prompt and exits; it takes no command from the client.
  passwordShell = pkgs.writeShellScript "fips-initrd-shell" ''
    echo
    echo "=== FIPS initrd — remote unlock ==="
    echo "Enter the passphrase for the encrypted root."
    echo "Boot continues on its own once it is accepted."
    echo
    exec ${config.boot.initrd.systemd.package}/bin/systemd-tty-ask-password-agent --query
  '';

  # The address comparison, which is the part of ../docs/porting.md that must
  # survive a port. Everything here exits 0: a machine that reaches this point
  # is at its console passphrase prompt either way, and nothing found here is
  # worth taking that away.
  checkScript = pkgs.writeShellScript "fips-initrd-check" ''
    set -u
    iface=${lib.escapeShellArg cfg.interface}
    # fips.pub holds the npub itself, which is both the name to connect to and
    # what the expected address is derived from. The .deb copies it into the
    # image under two further names; here boot.initrd.secrets has already put
    # it where the daemon looks for it, so there is nothing to copy.
    pub=/etc/fips/fips.pub

    warn() { echo "fips-initrd: WARNING: $*" >&2; }

    current_address() {
        ${pkgs.iproute2}/bin/ip -6 addr show dev "$iface" scope global 2>/dev/null \
            | ${pkgs.gnused}/bin/sed -n 's|^[[:space:]]*inet6 \([0-9a-fA-F:]*\)/.*|\1|p' \
            | ${pkgs.gnused}/bin/sed -n '1p'
    }

    address=""
    i=0
    while [ "$i" -lt ${toString cfg.waitSeconds} ]; do
        address=$(current_address)
        [ -n "$address" ] && break
        ${pkgs.coreutils}/bin/sleep 1
        i=$((i + 1))
    done

    if [ -z "$address" ]; then
        warn "$iface has no global address after ${toString cfg.waitSeconds}s; remote unlock is unavailable."
        warn "A daemon that runs without an interface means the tun module is"
        warn "absent or tun.enabled is false. Unlock at the console."
        exit 0
    fi

    # The public key is in the image beside the private one, so the address
    # the node is supposed to hold can be derived here rather than trusted.
    # This catches the two failures that leave a perfectly healthy daemon: a
    # key missing from the image, where the daemon generates a fresh identity
    # and runs normally at an address nobody is connecting to, and a public
    # key that does not match the private one next to it.
    if [ ! -r "$pub" ]; then
        warn "$pub is missing, so the identity cannot be checked."
        warn "$iface came up at $address. If that is not the address you"
        warn "recorded, the node generated a new identity and is unreachable."
        exit 0
    fi

    expected=$(${cfg.package}/bin/fipsctl address --key "$pub" 2>/dev/null) || expected=""
    if [ -z "$expected" ]; then
        warn "fipsctl could not derive an address from $pub; identity unchecked."
        warn "$iface came up at $address."
        exit 0
    fi

    if [ "$address" != "$expected" ]; then
        warn "$iface came up at $address, not the expected $expected."
        warn "The node is running under a different identity, so it is not at"
        warn "the address you recorded and remote unlock is unavailable."
        exit 0
    fi

    # The name first, and the address only as a secondary fact. A connection
    # must use the name: resolving <npub>.fips through a FIPS DNS responder is
    # what drives the mesh lookup, and a bare address resolves nothing.
    echo "fips-initrd: node up at $(${pkgs.coreutils}/bin/cat "$pub").fips ($address)"
  '';

  # ── key material lives OUTSIDE the flake ────────────────────────────────
  # Every path below is a STRING, not a Nix path literal, and the distinction
  # is the whole point. A path literal is copied into the Nix store at
  # evaluation time and the store is world readable, so the private keys would
  # be exposed to every local user. A string is left alone: boot.initrd.secrets
  # and the initrd-ssh module read it as root at `nixos-rebuild switch` time
  # and append it straight to the image.
  #
  # Do NOT guard these with builtins.pathExists. Flakes evaluate in pure mode,
  # where pathExists on an absolute path outside the store returns false even
  # when the file is there. It does not error, it lies, so a mkIf guard would
  # always be false and would silently drop the keys: the daemon would come up
  # under a generated identity at an address nobody knows, and sshd with no
  # host key, on a machine whose only purpose is remote unlock. Referencing
  # them unconditionally means a missing file fails loudly during the switch,
  # where the appender's cp runs, at the machine you are standing at.
  fipsKeyPath = "${cfg.secretsDir}/fips.key";
  fipsPubPath = "${cfg.secretsDir}/fips.pub";
  sshHostKeyPath = "${cfg.secretsDir}/ssh_host_ed25519_key";
in
{
  options.services.fips.initrd = {
    enable = lib.mkEnableOption "a FIPS mesh node in the initrd, for remote unlock of an encrypted root over the mesh";

    package = lib.mkPackageOption pkgs "fips" { };

    secretsDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/fips-initrd";
      description = ''
        Directory holding this node's initrd key material:

        - `fips.key` and `fips.pub`, the persistent mesh identity
        - `ssh_host_ed25519_key`, the host key for the initrd sshd

        Deliberately outside the flake, and a string rather than a path
        literal: anything inside a flake is copied into the world-readable Nix
        store on every evaluation, which would expose these private keys to
        every local user. At an absolute path only root reads them, at switch
        time.

        The keys still end up inside the initrd image on an unencrypted
        `/boot`, which is inherent to unlocking a disk you have not unlocked
        yet. What this avoids is the additional exposure of the store and of
        git. Treat this identity as compromised if the disk is taken.

        The corollary is that a fresh clone of your configuration cannot
        rebuild this node's identity. Back the directory up, or accept that
        losing it means a new mesh address and a new initrd host key.

        See `nixos/README.md` for how to create it.
      '';
    };

    interface = lib.mkOption {
      type = lib.types.str;
      default = "fips0";
      description = ''
        Name of the mesh TUN interface the daemon creates. Changing it is
        rarely useful; it exists because the address check and the daemon
        configuration have to agree on the name, and hard-coding it twice
        invites them to disagree.
      '';
    };

    logLevel = lib.mkOption {
      type = lib.types.str;
      default = "info";
      example = "debug";
      description = ''
        Daemon log level in the initrd. Stage 1 logs to the console, over the
        passphrase prompt, so `debug` is for bring-up rather than for normal
        running.
      '';
    };

    waitSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 20;
      description = ''
        How long to wait for the mesh interface to get a global address before
        reporting that remote unlock is unavailable.

        The wait is bounded and its expiry never stops the boot: the machine
        arrives at its console passphrase prompt either way.
      '';
    };

    ssh.authorizedKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI... you@workstation" ];
      description = ''
        Public keys admitted to the initrd sshd as root. Without one there is
        no remote unlock at all, so an assertion requires at least one.

        Use a key reserved for this. A session opened with one of these keys
        lands on the passphrase prompt and can do nothing else, but the key
        still names something that may unlock this machine.
      '';
    };

    ethernetInterfaces = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [
        "enp1s0"
        "enp3s0"
      ];
      description = ''
        Wired interfaces to run the FIPS ethernet transport on, in stage-1
        naming. One `lanN` transport is generated per name.

        The transport speaks L2 directly, so it needs no DHCP lease, no route
        and no resolver, all of which early boot is bad at. That makes it
        worth having here even though the UDP and TCP transports are what
        reach the wider mesh.

        There is no useful default: interface names are per machine, and a
        name that does not exist is not an error anyone sees. The daemon binds
        nothing, stage 1 has no ethernet transport, and the node simply never
        appears where you are looking for it. `ip -o link` on the machine
        lists them; stage 1 uses the same predictable names as the booted
        system.

        Leaving this empty is allowed and generates no ethernet transport at
        all, which is the right answer for a machine whose only path to the
        mesh is its default route.
      '';
    };

    peers = lib.mkOption {
      type = lib.types.listOf (lib.types.attrsOf lib.types.unspecified);
      description = ''
        Static bootstrap peers, written into the image as the `peers` list.

        Static only. Nostr-mediated rendezvous needs DNS, a plausible wall
        clock and relay reachability, none of which hold this early in a boot.

        Auto-discovery is not a substitute either, and this is the failure
        worth understanding before relying on the default. Two nodes are
        mutually routable only if they share a spanning tree. A node that
        finds one neighbour by ethernet beacon attaches to it and is perfectly
        healthy, on a tree that has no anchor to the relays everything else
        meets at, and it is then unreachable from a machine that reaches the
        booted system fine. Give the initrd the same peers the booted system
        uses.

        Each peer takes a list of addresses tried in order of `priority`,
        lowest first, so a hostname can be preferred with a literal address as
        the fallback for a boot where DNS has not come up. The hostname form
        does work here: the initrd takes a resolver from its DHCP lease.
        Neither form alone survives both the peer moving and DNS being
        unavailable.

        A machine whose peers have all moved becomes unreachable with no
        signal as to why, and the recovery is physical access to the console.
        More than one peer is the only mitigation on offer.

        The default is the FIPS public test mesh, which accepts inbound
        peering from any npub, so an untouched configuration is usable rather
        than inert. Replace it for anything you rely on. Keep it in step with
        `conf/fips.yaml.example`, which carries the same list for the `.deb`.
      '';
      default = [
        {
          npub = "npub1qmc3cvfz0yu2hx96nq3gp55zdan2qclealn7xshgr448d3nh6lks7zel98";
          alias = "test-us01";
          connect_policy = "auto_connect";
          addresses = [
            {
              transport = "udp";
              addr = "test-us01.fips.network:2121";
              priority = 10;
            }
            {
              transport = "udp";
              addr = "217.77.8.91:2121";
              priority = 20;
            }
          ];
        }
        {
          npub = "npub10yffd020a4ag8zcy75f9pruq3rnghvvhd5hphl9s62zgp35s560qrksp9u";
          alias = "test-us02";
          connect_policy = "auto_connect";
          addresses = [
            {
              transport = "udp";
              addr = "test-us02.fips.network:2121";
              priority = 10;
            }
            {
              transport = "udp";
              addr = "23.182.128.74:2121";
              priority = 20;
            }
          ];
        }
      ];
    };

    settings = lib.mkOption {
      inherit (yamlFormat) type;
      default = { };
      example = lib.literalExpression ''
        {
          transports.udp.bind_addr = "0.0.0.0:12121";
        }
      '';
      description = ''
        Extra node configuration, merged recursively over what this module
        generates and written into the image as `/etc/fips/fips.yaml`.

        The escape hatch for anything the options above do not express. What
        it can express is whatever the daemon's schema accepts, and that
        schema is not yet stable, so a setting here is a setting you own
        across FIPS upgrades.
      '';
    };

    dns.enable = lib.mkEnableOption ''
      the daemon's `.fips` DNS responder in the initrd. Off by default: nothing
      in the initrd resolves `.fips` names, so the responder is dead weight.
      Turn it on together with a resolver in `extraBin` to look a peer up from
      the console debug shell
    '';

    networkKernelModules = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "r8169"
        "e1000e"
        "igb"
        "ixgbe"
        "tg3"
        "atlantic"
      ];
      description = ''
        Kernel modules for the network card, loaded in the initrd so the node
        can reach its peers. The default is a starter set of common wired
        NICs, not a promise about your machine: find yours with `lspci -k` and
        read the "Kernel driver in use" line.

        `tun` is added unconditionally and is not listed here. Without it
        there is no mesh interface at all.
      '';
    };

    extraBin = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ ];
      example = lib.literalExpression "[ pkgs.ldns pkgs.curl ]";
      description = ''
        Extra packages to put on the initrd's PATH, for use from the console
        debug shell. `drill` from `pkgs.ldns` resolves `.fips` names when
        `dns.enable` is on; `curl` reaches a peer over the mesh.

        Everything here is in the image on an unencrypted `/boot` and costs
        space in every kernel's initrd, so add during bring-up and remove
        afterwards.
      '';
    };

    wifi = {
      enable = lib.mkEnableOption ''
        joining an open wifi network in the initrd. Association only: the
        address comes from the initrd's DHCP, and peers on that network are
        found by the daemon's own discovery
      '';

      interface = lib.mkOption {
        type = lib.types.str;
        default = "";
        example = "wlp2s0";
        description = ''
          Wifi interface to associate with. Predictable interface naming is
          active in systemd stage 1, so this is the same name the booted
          system uses; `ls /sys/class/net` lists them.
        '';
      };

      ssid = lib.mkOption {
        type = lib.types.str;
        default = "";
        example = "open-guest";
        description = ''
          SSID of the OPEN, unencrypted network to join.

          Open by construction, and there is no option for a PSK. An initrd
          lives on an unencrypted `/boot`, so a PSK put here would be readable
          by anyone who can pull the disk. Nothing sensitive rides on the
          link: the mesh is authenticated and encrypted end to end regardless
          of what carries it.
        '';
      };

      kernelModules = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "iwlwifi" ];
        description = ''
          Kernel modules for the wifi adapter. Find yours with `lspci -k`.

          Unlike the wired list this has no defaults on purpose. A wifi module
          drags its whole firmware set into the initrd, and adding the usual
          suspects grew one machine's initrd module closure from 8 MB to
          31 MB. Name only the driver this machine uses.

          Note also that 802.11s mesh point mode is not involved anywhere
          here. This joins an ordinary network in managed mode; check
          `iw list` before assuming an adapter can do more.
        '';
      };
    };

    bluetooth = {
      enable = lib.mkEnableOption ''
        BlueZ and the FIPS BLE transport in the initrd. Best-effort: if the
        daemon or the adapter fails, the node still runs on its other
        transports
      '';

      adapter = lib.mkOption {
        type = lib.types.str;
        default = "hci0";
        description = "HCI adapter the BLE transport uses.";
      };

      kernelModules = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [
          "bluetooth"
          "btusb"
          "btrtl"
          "btintel"
          "btbcm"
          "btmtk"
          "rfkill"
          "ecdh_generic"
        ];
        description = ''
          Kernel modules for Bluetooth, loaded in the initrd so the BLE
          transport can reach the HCI adapter.
        '';
      };
    };

    debug = {
      consoleShell.enable = lib.mkEnableOption ''
        a root shell on tty2 in the initrd. Alt+F2 at the passphrase prompt
        reaches it, Alt+F1 goes back, and `fipsctl show peers` works there as
        soon as the daemon is up.

        It is A ROOT SHELL WITH NO AUTHENTICATION on the console, reachable by
        anyone at the keyboard while the disk is still locked. Turn it off
        once stage 1 behaves
      '';

      sshShell.enable = lib.mkEnableOption ''
        an interactive root shell for SSH sessions into the initrd, instead of
        the passphrase prompt. This is the analogue of the `.deb`'s
        `FIPS_FORCE_UNLOCK_COMMAND=no`, and it is for bring-up: a shell in the
        initrd is how a failed unlock gets diagnosed.

        With it on, a key in `ssh.authorizedKeys` opens a root shell on the
        mesh rather than only answering a prompt, so it is a foothold on the
        mesh and not only on this machine. `systemd-tty-ask-password-agent
        --query` from that shell still does the unlock
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # Required for custom stage-1 units and for the built-in initrd sshd.
    boot.initrd.systemd.enable = true;

    # ── stage-1 networking ────────────────────────────────────────────────
    # The UDP and TCP transports need a real address to reach peers with.
    # systemd stage 1 has no udhcpc; DHCP is systemd-networkd's, which
    # boot.initrd.network.enable pulls into the image.
    boot.initrd.network.enable = true;

    # Hand stage 2 a clean slate rather than the initrd's addresses.
    #
    # With systemd in the initrd this defaults to false, and networkd then
    # keeps its configuration on stop so stage 2 can inherit the lease. That
    # handoff is designed for a stage 2 that also runs networkd. A stage 2
    # running NetworkManager does not understand it: NM starts, finds the link
    # already carrying an address, marks it "connected (externally)" and never
    # runs DHCP of its own.
    #
    # While the initrd's DHCP succeeds that is invisible, because NM adopts a
    # good lease. When it does not, the interface keeps the link-local
    # fallback below and NM adopts that, permanently: an interface sitting on
    # 169.254.0.0/16 with no default route, NM's whole journal for the boot
    # being "Starting Network Manager... Started Network Manager", and every
    # name lookup on the box failing.
    #
    # true makes networkd drop the addresses at switch-root, so NM starts from
    # nothing. Nothing in stage 1 needs the address by then: the unlock is
    # finished, and the daemon re-establishes its transports in stage 2.
    boot.initrd.network.flushBeforeStage2 = lib.mkDefault true;

    boot.initrd.systemd.network.networks."10-fips-initrd-dhcp" = {
      # By name, so the unit never touches the mesh interface: the daemon
      # assigns that address on the TUN device itself.
      matchConfig.Name = "en* eth* wl*";
      networkConfig = {
        DHCP = "yes";
        # IPv4 link-local as a fallback when DHCP finds no server, which is
        # exactly the case on a direct cable between two machines. networkd
        # defaults this to "ipv6", so without it the interface gets only an
        # IPv6 link-local address. A peer discovered over mDNS then advertises
        # its own 169.254 address and the handshake dies with ENETUNREACH,
        # because there is no IPv4 route at all.
        LinkLocalAddressing = "yes";
      };
      # "carrier", not the default "degraded", is what wait-online below
      # counts as online. The ethernet transport is raw L2 and needs no
      # address, so a link with carrier is already useful; waiting for an
      # address would mean waiting out the DHCP timeout on every boot.
      linkConfig.RequiredForOnline = "carrier";
    };

    # Wait for one link before the daemon starts.
    #
    # This is an ordering bug waiting to happen rather than a nicety. The
    # daemon opens its AF_PACKET beacon sockets at startup, and a socket
    # opened while the device is down stays unusable. Measured once: links
    # gained carrier at 4.8s and the daemon was still failing every beacon
    # with ENETDOWN at 11.4s, so no beacon ever left the machine.
    #
    # --any because the second port usually has no cable and a wlan interface
    # may never associate. --timeout because a cable-less boot must cost
    # fifteen seconds rather than hang; the unit then fails, which is why
    # fips-mesh only wants it.
    boot.initrd.systemd.services.systemd-networkd-wait-online = {
      overrideStrategy = "asDropin";
      # Same reasoning as fips-mesh: this runs before cryptsetup, so it must
      # not inherit the default sysinit.target ordering.
      unitConfig.DefaultDependencies = false;
      serviceConfig.ExecStart = [
        ""
        "${config.boot.initrd.systemd.package}/lib/systemd/systemd-networkd-wait-online --any --timeout=15"
      ];
    };

    # "tun" is what creates /dev/net/tun, without which there is no mesh
    # interface. Firmware for these modules is pulled in automatically.
    boot.initrd.kernelModules = [
      "tun"
    ]
    ++ cfg.networkKernelModules
    ++ lib.optionals cfg.wifi.enable cfg.wifi.kernelModules
    ++ lib.optionals cfg.bluetooth.enable cfg.bluetooth.kernelModules;

    boot.initrd.systemd.initrdBin = [
      cfg.package
      pkgs.iproute2
      pkgs.util-linux
      pkgs.coreutils
    ]
    ++ cfg.extraBin
    ++ lib.optional (cfg.debug.consoleShell.enable || cfg.debug.sshShell.enable) pkgs.bashInteractive
    ++ lib.optionals cfg.bluetooth.enable [
      pkgs.dbus
      pkgs.bluez
    ]
    ++ lib.optionals cfg.wifi.enable [
      pkgs.wpa_supplicant
      pkgs.iw
    ];

    # The daemon's shared-library closure has to be in the image: autoPatchelf
    # wrote those store paths into its RPATH at build time, and a binary that
    # cannot load is a node that does not exist.
    boot.initrd.systemd.storePaths = [
      "${cfg.package}/bin/fips"
      "${cfg.package}/bin/fipsctl"
      "${config.boot.initrd.systemd.package}/bin/systemd-tty-ask-password-agent"
    ];

    boot.initrd.systemd.contents = {
      "/etc/fips/fips.yaml".source = configFile;
      "/etc/machine-id".source = dbusMachineId;
      # Not under /bin: make-initrd-ng turns /bin into a symlink to the
      # read-only initrdBin store environment, so nothing can be created
      # inside it.
      "/etc/fips/initrd-shell".source = passwordShell;
    }
    // lib.optionalAttrs cfg.wifi.enable {
      "/etc/wpa_supplicant.conf".source = wpaConf;
    };

    # ── the identity, appended to the image at switch time ────────────────
    # The bootloader installer appends these as real files rather than store
    # symlinks, so they are readable in stage 1 and the store never holds a
    # copy. They ARE in the image on an unencrypted /boot, which is
    # unavoidable for a key the machine needs before the disk is unlocked.
    #
    # A missing file fails `nixos-rebuild switch` at append-initrd-secrets,
    # which runs cp under bash -e. That is deliberate: generate the keys
    # first. See nixos/README.md.
    boot.initrd.secrets = {
      "/etc/fips/fips.key" = fipsKeyPath;
      "/etc/fips/fips.pub" = fipsPubPath;
    };

    boot.initrd.network.ssh = {
      enable = true;
      authorizedKeys = cfg.ssh.authorizedKeys;
      # A plain string, so the host key is read at switch time and never
      # copied into the world-readable store. This is the pattern the upstream
      # option documents.
      hostKeys = [ sshHostKeyPath ];
    };

    # The unlock restriction. A session lands on systemd's password agent,
    # which answers the prompt and exits; it takes no command from the client.
    # debug.sshShell.enable replaces it with a real shell for bring-up.
    boot.initrd.systemd.users.root.shell =
      if cfg.debug.sshShell.enable then "${pkgs.bashInteractive}/bin/bash" else "/etc/fips/initrd-shell";

    boot.initrd.systemd.services.fips-mesh = {
      description = "FIPS mesh node (initrd)";
      wantedBy = [ "initrd.target" ];
      before = [
        "sshd.service"
        "cryptsetup-pre.target"
      ];
      # Ordered after wait-online so the links have carrier before the daemon
      # binds its AF_PACKET sockets. `wants`, not `requires`: wait-online
      # fails when it times out with no cable, and that must not stop the
      # daemon, because the mesh may still come up over another transport and
      # the passphrase prompt has to appear regardless.
      #
      # Deliberately NOT network-online.target. That target carries default
      # dependencies, so depending on it pulls this service after
      # sysinit.target while it also declares before=cryptsetup-pre.target — a
      # contradiction systemd resolves by silently breaking one edge, which is
      # how this service once ended up starting after the passphrase prompt.
      # Depending on the wait-online service directly, with default
      # dependencies off on both, keeps it early.
      wants = [ "systemd-networkd-wait-online.service" ];
      after = [
        "systemd-networkd.service"
        "systemd-networkd-wait-online.service"
      ];

      unitConfig = {
        # Must run before cryptsetup, so it cannot inherit the default
        # sysinit.target ordering.
        DefaultDependencies = false;
        # Bounded, but more generous than the optional services below:
        # without this there is no way in at all.
        StartLimitIntervalSec = 300;
        StartLimitBurst = 10;
      };

      serviceConfig = {
        Type = "simple";
        ExecStart = "${cfg.package}/bin/fips --config /etc/fips/fips.yaml";
        Restart = "on-failure";
        RestartSec = 3;
        RuntimeDirectory = "fips";
        RuntimeDirectoryMode = "0770";
      };
    };

    # The address comparison. Ordered before the passphrase prompt so its
    # verdict is on the console above it, and Type=oneshot so the prompt does
    # not appear until the wait is over and there is something to say.
    boot.initrd.systemd.services.fips-mesh-check = {
      description = "Check the FIPS node came up at the expected address (initrd)";
      wantedBy = [ "initrd.target" ];
      # `wants`, not `requires`. A daemon that failed to start is exactly the
      # case this unit exists to report; requiring it would mean saying
      # nothing at all in the one case where silence is worst.
      wants = [ "fips-mesh.service" ];
      after = [ "fips-mesh.service" ];
      before = [ "cryptsetup-pre.target" ];
      unitConfig.DefaultDependencies = false;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = checkScript;
        StandardOutput = "journal+console";
        StandardError = "journal+console";
      };
    };

    # sshd after the mesh, so fips0 exists when it starts, but only `wants`:
    # sshd is still worth having on the ordinary network if the mesh failed.
    boot.initrd.systemd.services.sshd = {
      after = [ "fips-mesh.service" ];
      wants = [ "fips-mesh.service" ];
    };

    boot.initrd.systemd.services.fips-debug-shell = lib.mkIf cfg.debug.consoleShell.enable {
      description = "Root debug shell on tty2 (initrd)";
      wantedBy = [ "initrd.target" ];
      after = [ "fips-mesh.service" ];

      unitConfig = {
        DefaultDependencies = false;
        # Exiting the shell respawns it, which is wanted. A tty that never
        # works is not: bound the retries so it cannot become a hot loop.
        StartLimitIntervalSec = 60;
        StartLimitBurst = 10;
      };

      serviceConfig = {
        Type = "idle";
        ExecStart = "${pkgs.bashInteractive}/bin/bash";
        Restart = "always";
        RestartSec = 1;
        StandardInput = "tty-force";
        StandardOutput = "inherit";
        StandardError = "inherit";
        TTYPath = "/dev/tty2";
        TTYReset = true;
        TTYVHangup = true;
        IgnoreSIGPIPE = false;

        # An interactive bash ignores SIGTERM. With the default KillSignal and
        # KillMode=process this unit sits through the whole
        # DefaultTimeoutStopSec on every switch-root before being killed,
        # which is a ninety-second stall at the end of stage 1. SIGHUP is the
        # signal an interactive shell acts on, KillMode=mixed also reaps
        # anything started from the shell, and the short timeout caps the
        # damage if something in there still refuses to die.
        KillMode = "mixed";
        KillSignal = "SIGHUP";
        TimeoutStopSec = 5;
      };
    };

    # Association only. The address comes from the DHCP unit above, which
    # matches wl*, and peers on that network are found by the daemon itself.
    # Restart so a late-appearing network is still joined while the machine
    # sits at the passphrase prompt.
    boot.initrd.systemd.services.wpa_supplicant = lib.mkIf cfg.wifi.enable {
      description = "wpa_supplicant — join ${cfg.wifi.ssid} (initrd)";
      wantedBy = [ "initrd.target" ];
      before = [ "fips-mesh.service" ];
      unitConfig = {
        DefaultDependencies = false;
        # Give up instead of looping forever. systemd's default limit is five
        # starts per ten seconds, which RestartSec=3 can never trip, so the
        # unit would retry until the end of time, spamming the console over
        # the passphrase prompt. These numbers make the limit reachable.
        StartLimitIntervalSec = 120;
        StartLimitBurst = 5;
      };

      serviceConfig = {
        Type = "simple";
        ExecStartPre = wifiInit;
        ExecStart = toString [
          "${pkgs.wpa_supplicant}/bin/wpa_supplicant"
          "-i ${cfg.wifi.interface}"
          "-c /etc/wpa_supplicant.conf"
          # -W would wait for the control interface and -u needs D-Bus.
          # Neither is wanted: this is a bare association with no client.
        ];
        RuntimeDirectory = "wpa_supplicant";
        Restart = "on-failure";
        RestartSec = 3;
      };
    };

    # NixOS provides dbus in stage 1 itself (boot.initrd.systemd.dbus, on by
    # default): it bakes /etc/dbus-1, the messagebus user and the
    # socket-activated unit into the image. Nothing to redefine here; this
    # unit only depends on the socket.
    boot.initrd.systemd.services.bluetoothd = lib.mkIf cfg.bluetooth.enable {
      description = "BlueZ bluetoothd (initrd)";
      wantedBy = [ "initrd.target" ];
      after = [ "dbus.socket" ];
      requires = [ "dbus.socket" ];
      before = [ "fips-mesh.service" ];
      # Same bounded-restart reasoning as wpa_supplicant: no adapter and no
      # firmware must not become an endless retry loop.
      unitConfig = {
        StartLimitIntervalSec = 120;
        StartLimitBurst = 5;
      };

      serviceConfig = {
        Type = "simple";
        ExecStartPre = btInit;
        ExecStart = "${pkgs.bluez}/libexec/bluetooth/bluetoothd --nodetach";
        Restart = "on-failure";
        RestartSec = 3;
      };
    };

    # ── the LUKS device is deliberately not declared here ──────────────────
    # An earlier version of this module added its own boot.initrd.luks.devices
    # entry, which was a second mapping for the same physical device that
    # hardware-configuration.nix already declares. The result, every boot: two
    # passphrase prompts, because each mapping runs its own ask-password; the
    # KDF run twice; and the loser failing hard once the winner had the
    # device, with "Cannot use device ... which is in use" and a failed
    # cryptsetup.target.
    #
    # The root device belongs to the configuration that names it and that
    # fileSystems."/" refers to. This module only needs the mesh and sshd to
    # exist before the prompt; it does not need to own the device.
    assertions = [
      {
        assertion = cfg.ssh.authorizedKeys != [ ];
        message = ''
          services.fips.initrd is enabled but services.fips.initrd.ssh.authorizedKeys
          is empty, so nothing could log in to unlock this machine and the node
          would sit on the mesh admitting nobody. Add the public key you will
          unlock from.
        '';
      }
      {
        assertion = cfg.peers != [ ];
        message = ''
          services.fips.initrd is enabled but services.fips.initrd.peers is
          empty. The initrd node uses static peers only, so it would start,
          reach nobody, and leave a machine that looks configured and is not.
        '';
      }
      {
        assertion = config.boot.initrd.luks.devices != { };
        message = ''
          services.fips.initrd is enabled but no boot.initrd.luks.devices are
          declared, so there is nothing to unlock and the initrd SSH session
          would have no purpose. Declare the root device where your
          configuration names its filesystems, normally
          hardware-configuration.nix.
        '';
      }
      {
        assertion = !cfg.wifi.enable || (cfg.wifi.interface != "" && cfg.wifi.ssid != "");
        message = ''
          services.fips.initrd.wifi is enabled but its interface or ssid is
          unset. Both are per machine and neither has a safe default: an empty
          interface associates with nothing, silently.
        '';
      }
    ];

    warnings = lib.optional (cfg.debug.sshShell.enable && cfg.enable) ''
      services.fips.initrd.debug.sshShell is enabled, so a key in
      services.fips.initrd.ssh.authorizedKeys opens a root shell in the initrd
      with the mesh already attached, rather than only answering the passphrase
      prompt. That is a foothold on the mesh and not only on this machine. It
      is for bring-up; turn it off once the unlock works.
    '';
  };
}
