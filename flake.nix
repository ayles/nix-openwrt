{
  description = "Build OpenWrt images from source with Nix";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { self, nixpkgs }:
    {
      lib = {
        # Build an OpenWrt configuration. Returns an attrset with:
        #   mkImage, downloads, imagebuilder, version, target, subtarget
        #
        # Usage (in a consumer flake):
        #
        #   inputs.nix-openwrt.url = "github:...";
        #
        #   let
        #     openwrt = nix-openwrt.lib.build {
        #       inherit pkgs;
        #       src = pkgs.fetchFromGitHub { owner = "openwrt"; repo = "openwrt"; rev = "v25.12.0-rc4"; ... };
        #       config = pkgs.fetchurl { url = "https://downloads.openwrt.org/releases/.../config.buildinfo"; ... };
        #       target = "mediatek";
        #       subtarget = "filogic";
        #       profile = "bananapi_bpi-r4";
        #     };
        #   in
        #     openwrt.mkImage {
        #       downloadsHash = "sha256-...";
        #       packages = [ "luci" ];
        #       extraFiles = { "path/in/tree" = ./patch; };
        #     }
        #
        build =
          { pkgs, ... }@args:
          pkgs.callPackage ./lib/openwrt.nix (builtins.removeAttrs args [ "pkgs" ]);

        # Nix build patches needed for OpenWrt to build under Nix.
        # Apply via extraFiles in mkImage/imagebuilder/downloads.
        patches = {
          "package/system/apk/patches/0020-apk-use-fat-lto-objects.patch" = ./patches/apk-fat-lto-objects.patch;
          "tools/fakeroot/patches/900-einval.patch" = ./patches/fakeroot-einval.patch;
        };
      };
    };
}
