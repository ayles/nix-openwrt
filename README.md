# nix-openwrt

[![CI](https://github.com/ayles/nix-openwrt/actions/workflows/ci.yml/badge.svg)](https://github.com/ayles/nix-openwrt/actions/workflows/ci.yml)

Build OpenWrt firmware images from source with Nix.

Requires Linux and Nix with [flakes enabled](https://wiki.nixos.org/wiki/Flakes).

## Usage

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nix-openwrt.url = "github:ayles/nix-openwrt";
  };

  outputs = { nixpkgs, nix-openwrt, ... }:
    let
      pkgs = import nixpkgs { system = "aarch64-linux"; };

      openwrt = nix-openwrt.lib.build {
        inherit pkgs;
        src = pkgs.fetchFromGitHub {
          owner = "openwrt";
          repo = "openwrt";
          rev = "v25.12.1";
          hash = "sha256-...";
        };
        version = "25.12.1";  # optional, defaults to src.rev
        config = pkgs.fetchurl {
          url = "https://downloads.openwrt.org/releases/25.12.1/targets/mediatek/filogic/config.buildinfo";
          hash = "sha256-...";
        };
        target = "mediatek";
        subtarget = "filogic";
        profile = "bananapi_bpi-r4";
        downloadsHash = "sha256-...";

        # Optional: patch the OpenWrt source tree
        patches = {
          "package/kernel/mt76/patches/100-fix.patch" = ./patches/100-fix.patch;
        };

        # Optional: extra Kconfig lines appended before `make defconfig`
        extraConfig = ''
          CONFIG_FOO=y
        '';

        # Optional: extra packages in the FHS build environment
        extraBuildInputs = [ pkgs.go ];
      };
    in {
      packages.aarch64-linux.firmware = openwrt.mkImage {
        packages = [
          "luci" "luci-ssl"
          "dnsmasq-full" "-dnsmasq"
          "htop" "curl" "tcpdump"
        ];
        files = ./files;  # overlay onto firmware rootfs
      };
    };
}
```

## How it works

1. **Downloads** (fixed-output derivation) -- clone feeds, download all source tarballs, pre-fetch Go modules
2. **Full build** -- compile toolchain, kernel, base packages, ImageBuilder, and SDK
3. **mkImage** -- assemble firmware from ImageBuilder + compiled packages
4. **mkPackages** -- compile extra packages via SDK (own downloads FOD + offline build)

All stages run inside an FHS environment (`buildFHSEnv`) because OpenWrt's
build system assumes FHS paths.

## Extra packages via SDK

Use `mkPackages` to compile packages that aren't in the base image without
triggering a full rebuild:

```nix
sdkPackages = openwrt.mkPackages {
  packages = [ "nebula" "htop" ];
  downloadsHash = "sha256-...";

  # Optional: custom feed (installed with priority over stock feeds)
  feed = {
    name = "custom";
    src = ./feeds/custom;
  };

  # Optional: extra build deps and Kconfig for the SDK
  extraBuildInputs = [ pkgs.go ];
  extraConfig = ''
    CONFIG_GOLANG_EXTERNAL_BOOTSTRAP_ROOT="${pkgs.go}/share/go"
  '';
};

image = openwrt.mkImage {
  packages = [ "nebula" "htop" "-dnsmasq" "dnsmasq-full" "luci" ];
  extraPackages = [ sdkPackages ];
  files = ./files;
};
```

## Downloads hash

The `downloadsHash` is a fixed-output hash for the download phase. To compute it:

1. Set `downloadsHash = pkgs.lib.fakeHash;`
2. Build: `nix build .#default -L 2>&1 | grep "got:"`
3. Replace with the real hash

The same applies to `mkPackages { downloadsHash = ...; }`.

## Build configuration

`config` should point to the official `config.buildinfo` for your target.
When `profile` is set, nix-openwrt filters the config to only enable that
device (multi-device configs enable all devices by default).

## Patches

nix-openwrt automatically applies its own build-fix patches (apk fat-lto,
fakeroot EINVAL). User patches are passed via the `patches` attribute -- a set
mapping destination paths in the source tree to local patch files.

## Go modules

Go package sources are pre-fetched automatically in the downloads FOD stage.
OpenWrt's `make download` only fetches source tarballs; Go modules are fetched
implicitly by `go install` during compile, which would fail offline. nix-openwrt
detects Go packages and runs `go mod download` for each in the FOD stage.

## License

MIT (this project), GPL-2.0 (OpenWrt)
