{
  description = "A FIPS mesh node in the NixOS initrd, for remote unlock of an encrypted root";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # The daemon itself, and the overlay that puts it in pkgs. This flake
    # forwards that overlay rather than defining a package of its own, so a
    # machine runs one build of FIPS whether it also runs the stage-2 daemon
    # or only the initrd node.
    fips.url = "github:jmcorgan/fips";
  };

  outputs =
    {
      self,
      nixpkgs,
      fips,
      ...
    }:
    {
      nixosModules.default = ./module.nix;
      nixosModules.fips-initrd = ./module.nix;

      # Forwarded from the FIPS flake. The module takes its daemon from
      # `pkgs.fips`, so a configuration importing the module needs this overlay
      # or a `services.fips.initrd.package` of its own.
      overlays.default = fips.overlays.default;

      # An evaluation check, not a machine. It is the cheapest thing that
      # catches an option type error or a stale NixOS interface, and it is what
      # CI runs:
      #
      #   nix eval .#nixosConfigurations.example.config.system.build.toplevel.drvPath
      #
      # Building it would be a different and much longer exercise, and would
      # still not be the test that matters: the unlock needs a booted machine
      # with an encrypted root reaching a live mesh.
      nixosConfigurations.example = nixpkgs.lib.nixosSystem {
        modules = [
          self.nixosModules.default
          {
            nixpkgs.hostPlatform = "x86_64-linux";
            nixpkgs.overlays = [ self.overlays.default ];
          }
          ./examples/host.nix
        ];
      };
    };
}
