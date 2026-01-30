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
    in
    {
      # Library: the core OpenWrt builder
      lib.mkOpenWrt = import ./lib/openwrt.nix;

      # Example builds for BananaPi R4
      packages = forAllSystems (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
          openwrt = pkgs.callPackage ./lib/openwrt.nix {
            openwrtVersion = "25.12.0-rc2";
            openwrtRev = "4dd2e6ec5b81becd32dc25d85d977510d363a419";
            openwrtHash = "sha256-4Kht0uqi7UuLHD5lbmgpxQcW7aw5qTZivzNXRthmx2A=";
            target = "mediatek";
            subtarget = "filogic";
            profile = "bananapi_bpi-r4";
            configHash = "sha256-IxZUtmKBFtBhjLmceWyhqqrLpT7q5MJ9KGG4tGeEnT0=";
            feeds = [
              {
                name = "packages";
                owner = "openwrt";
                repo = "packages";
                rev = "b2ddc4a614a7a972715440b483020d3129fc059a";
                hash = "sha256-zP+ODT9j0egB2AnUlAy0KFON+lnyG7DN9ghWtCp5gSs=";
              }
              {
                name = "luci";
                owner = "openwrt";
                repo = "luci";
                rev = "6984d4d2a23ad87e1d76a5225f95f09b49c17184";
                hash = "sha256-j1QUFSoSMcTocYaEoA7R4XF9KZEaydtVOtQ8y+nbR2E=";
              }
              {
                name = "routing";
                owner = "openwrt";
                repo = "routing";
                rev = "b43e4ac560ccbafba21dc3ab0dbe57afc07e7b88";
                hash = "sha256-56ys3+vXxL+vYGWJVbz1XNzwpfBnDjKkYTbyBrJlozQ=";
              }
              {
                name = "telephony";
                owner = "openwrt";
                repo = "telephony";
                rev = "2618106d5846a4a542fdf5809f0d3ed228ce439b";
                hash = "sha256-/Up1QJ295WCWBeS76mKjopZbqvV5DJoH6o+cPJ516ls=";
              }
              {
                name = "video";
                owner = "openwrt";
                repo = "video";
                rev = "094bf58da6682f895255a35a84349a79dab4bf95";
                hash = "sha256-Y9AnAXWvALsHsAL/5hu4iMQDbnq6701ZZSxYESsonMg=";
              }
            ];
          };
          downloadsHash = "sha256-60iTy7VgYIXOGUm2IXNVxl+yRtFD5YTmJ87gJvu78ys=";
          nixPatches = {
            "package/system/apk/patches/0020-apk-use-fat-lto-objects.patch" = ./patches/apk-fat-lto-objects.patch;
            "tools/fakeroot/patches/900-einval.patch" = ./patches/fakeroot-einval.patch;
          };
        in
        {
          downloads = openwrt.downloads { inherit downloadsHash; };
          imagebuilder = openwrt.imagebuilder {
            inherit downloadsHash;
            extraFiles = nixPatches;
          };
          default = openwrt.mkImage {
            inherit downloadsHash;
            packages = [ "luci" "luci-ssl" ];
            extraFiles = nixPatches;
          };
        }
      );
    };
}
