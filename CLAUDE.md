# nix-openwrt

Build OpenWrt firmware images from source with Nix.

## Architecture

4-stage pipeline, each a separate Nix derivation:

1. **Downloads FOD** (`openwrt-downloads-{target}-{subtarget}`) — fixed-output derivation with network access. Clones feeds, runs `make download`, fetches transitive compile deps (`dump-deps.mk` + `openwrt_packages.py extra-downloads`), pre-fetches Go modules (`openwrt_packages.py go-mod-sources`).

2. **Full build** (`openwrt-build-{target}-{subtarget}`) — offline. Compiles toolchain, kernel, base packages. Produces ImageBuilder and SDK tarballs in `bin/`.

3. **mkImage** (`openwrt-image-{profile}`) — extracts ImageBuilder, copies in stock + extra packages, runs `make image`. Output: firmware files (sysupgrade.itb, sdcard.img.gz, etc).

4. **mkPackages** (`openwrt-packages-{target}-{subtarget}-{feed}`) — extracts SDK, compiles selected packages. Has its own downloads FOD for package-specific sources + Go modules. Output: .apk files.

All stages run inside an FHS environment (`buildFHSEnv`) because OpenWrt's build system assumes FHS paths.

## Key files

- `lib/openwrt.nix` — main build logic, all 4 stages
- `lib/openwrt_packages.py` — package dependency resolution (extra-downloads, make-targets, go-mod-sources)
- `lib/dump-deps.mk` — extracts resolved compile deps from OpenWrt's `.packagedeps`
- `lib/patches/` — build-fix patches applied automatically (apk fat-lto, fakeroot EINVAL)
- `flake.nix` — exposes `lib.build` via `callPackage`
- `.github/workflows/ci.yml` — CI: flake check + show

## Important patterns

- `extraConfig` is Kconfig text written to a file via `writeText`, then `cat`-appended to `.config`. An empty string produces an empty file — no hash impact.
- SDK gets a separate FHS wrapper only when `extraBuildInputs != []` (avoids rebuilding base stages).
- Custom feed packages are installed first (`scripts/feeds install -a -p <name>`) so they take precedence over stock feeds.
- Go packages need module pre-fetching: `make download` only gets source tarballs, not Go modules. The `downloadGoModules` snippet handles this in FOD stages.
- `version` defaults to `src.rev`; override with e.g. `"25.12.1"` for prettier derivation names.
- `downloadsHash` is a fixed-output hash — use `lib.fakeHash` to discover the correct value.

## Testing changes

Changes to the downloads FOD or FHS wrapper invalidate all downstream stages. The full build takes ~2-3 hours. Test changes that only affect mkImage/mkPackages first (seconds to minutes).
