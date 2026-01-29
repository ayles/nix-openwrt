{
  description = "Build OpenWrt images from source with Nix";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f system);

      # Import device configurations
      deviceConfigs = import ./lib/devices.nix;
    in
    {
      # Library functions for use by other flakes
      lib = {
        # Core OpenWrt builder
        mkOpenWrt = import ./lib/openwrt.nix;

        # Device configurations
        inherit deviceConfigs;

        # Helper: Create an OpenWrt builder for a specific device
        mkDevice =
          {
            pkgs,
            device,
            extraConfig ? { },
          }:
          let
            deviceConfig = deviceConfigs.${device};
            # Filter out 'profile' - it's metadata for mkImage, not for openwrt.nix
            openwrtConfig = builtins.removeAttrs (deviceConfig // extraConfig) [ "profile" ];
          in
          pkgs.callPackage ./lib/openwrt.nix openwrtConfig;
      };

      # Example builds for BananaPi R4
      packages = forAllSystems (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
          openwrt = self.lib.mkDevice {
            inherit pkgs;
            device = "bananapi-r4";
          };
          downloadsHash = "sha256-sXe9qSqLo4QI7p800wzn51On/1CGH/mJ9hyi3IMbIx0=";
        in
        {
          downloads = openwrt.downloads { inherit downloadsHash; };
          imagebuilder = openwrt.imagebuilder { inherit downloadsHash; };
          default = openwrt.mkImage {
            profile = deviceConfigs.bananapi-r4.profile;
            inherit downloadsHash;
            packages = [ "luci" "luci-ssl" ];
          };
        }
      );

      # Apps for managing device configurations
      apps = forAllSystems (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
        in
        {
          # Update device configuration
          # Usage: nix run .#update -- bananapi-r4 --version 25.12.0-rc2 --target mediatek --subtarget filogic
          update = {
            type = "app";
            program = "${./update.py}";
          };
        }
      );
    };
}
