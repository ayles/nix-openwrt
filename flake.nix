{
  description = "Build OpenWrt images from source with Nix";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { self, nixpkgs }:
    {
      lib.build =
        { pkgs, ... }@args:
        pkgs.callPackage ./lib/openwrt.nix (builtins.removeAttrs args [ "pkgs" ]);
    };
}
