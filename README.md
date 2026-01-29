# nix-openwrt

Nix flake library for building OpenWrt firmware from source.

## Usage

```nix
{
  inputs.nix-openwrt.url = "github:ayles/nix-openwrt";

  outputs = { nixpkgs, nix-openwrt, ... }:
    let
      pkgs = import nixpkgs { system = "x86_64-linux"; };
      openwrt = nix-openwrt.lib.mkDevice {
        inherit pkgs;
        device = "bananapi-r4";
      };
    in {
      packages.x86_64-linux.default = openwrt.mkImage {
        profile = nix-openwrt.lib.deviceConfigs.bananapi-r4.profile;
        downloadsHash = "sha256-...";  # see below
        packages = [ "luci" "htop" ];
        files = ./files;
        extraFiles = {
          "package/foo/patches/001-fix.patch" = ./patches/001-fix.patch;
        };
      };
    };
}
```

## Downloads Hash

```bash
# Set downloadsHash = lib.fakeHash, then:
nix build .#default -L 2>&1 | grep "got:"
```

## Adding Devices

```bash
./update.py my-device --version 24.10.0 --target mediatek --subtarget filogic --profile my_profile
# Copy output to lib/devices.nix
```

## License

MIT (this project), GPL-2.0 (OpenWrt)
