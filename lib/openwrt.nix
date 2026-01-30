# OpenWrt from-source builder
#
# Usage:
#   openwrt = pkgs.callPackage ./lib/openwrt.nix {
#     openwrtVersion = "25.12.0-rc2";
#     openwrtRev = "4dd2e6ec5b81becd32dc25d85d977510d363a419";
#     openwrtHash = "sha256-...";
#     target = "mediatek";
#     subtarget = "filogic";
#     profile = "bananapi_bpi-r4";  # optional: filter to single device
#     configHash = "sha256-...";  # hash of official config.buildinfo
#     feeds = [ { name = "packages"; owner = "openwrt"; ... } ];
#   };
#
#   openwrt.mkImage {
#     packages = [ "luci" "htop" ];
#     files = ./files;
#     extraFiles = {
#       "package/kernel/mt76/patches/100-tx_power.patch" = ./patches/100-fix.patch;
#     };
#     downloadsHash = "sha256-...";
#   }
#
# Architecture:
# 1. Feeds pre-fetched via fetchFromGitHub (reliable, cached)
# 2. Package sources downloaded via FOD (deterministic hash)
# 3. Full OpenWrt build produces ImageBuilder
# 4. mkImage uses ImageBuilder for final firmware
#
{
  lib,
  buildFHSEnv,
  runCommand,
  stdenv,
  writeScript,
  bash,
  bison,
  cacert,
  cdrtools,
  curl,
  file,
  flex,
  gawk,
  gettext,
  git,
  ncurses,
  openssl,
  perl,
  pkg-config,
  swig,
  unzip,
  util-linux,
  wget,
  which,
  rsync,
  zlib,
  python3,
  fetchFromGitHub,
  fetchurl,
  # OpenWrt configuration
  openwrtVersion,
  openwrtRev,
  openwrtHash,
  target,
  subtarget,
  # Hash of the official config.buildinfo (fetched from downloads.openwrt.org)
  configHash,
  feeds,
  # Optional: build only for this device profile (e.g. "bananapi_bpi-r4").
  # When set, disables all other device profiles in the config.
  # Reduces build time by skipping ATF/u-boot for other boards.
  # Vermagic is unaffected since it depends only on kernel config.
  profile ? null,
  # Optional: override the build config entirely (path or derivation).
  # When set, configUrl/configHash are ignored.
  buildConfig ? null,
}:

let
  version = openwrtVersion;

  # Fetch OpenWrt source
  openwrtSrc = fetchFromGitHub {
    owner = "openwrt";
    repo = "openwrt";
    rev = openwrtRev;
    hash = openwrtHash;
  };

  # Build configuration: use override or fetch official + optionally filter device
  officialConfig = fetchurl {
    url = "https://downloads.openwrt.org/releases/${version}/targets/${target}/${subtarget}/config.buildinfo";
    hash = configHash;
  };

  filteredConfig =
    if profile == null then
      officialConfig
    else
      runCommand "openwrt-config-${profile}" { } ''
        cp ${officialConfig} $out
        sed -i '/^CONFIG_TARGET_DEVICE_PACKAGES_/!s/^CONFIG_TARGET_DEVICE_\(.*\)=y$/# CONFIG_TARGET_DEVICE_\1 is not set/' $out
        sed -i 's/^# CONFIG_TARGET_DEVICE_\(.*_DEVICE_${profile}\) is not set$/CONFIG_TARGET_DEVICE_\1=y/' $out
        sed -i '/^CONFIG_TARGET_DEVICE_PACKAGES_.*_DEVICE_${profile}="/!{/^CONFIG_TARGET_DEVICE_PACKAGES_/d}' $out
      '';

  effectiveConfig = if buildConfig != null then buildConfig else filteredConfig;

  # Fix for https://github.com/NixOS/nixpkgs/issues/21751
  # Unwrapped GCC leaks architecture-prefixed binaries (e.g., aarch64-unknown-linux-gnu-gcc)
  # into PATH, which can't link properly. Create symlinks pointing these to the wrapped gcc.
  # See: https://github.com/nix-community/nix-environments/blob/master/envs/openwrt/shell.nix
  gccFixWrapper = stdenv.mkDerivation {
    name = "gcc-fix-wrapper";
    dontUnpack = true;
    installPhase = ''
      mkdir -p $out/bin
      for i in ${stdenv.cc.cc}/bin/*-gnu-gcc*; do
        ln -s ${stdenv.cc}/bin/gcc $out/bin/$(basename "$i")
      done
      for i in ${stdenv.cc.cc}/bin/*-gnu-{g++,c++}*; do
        ln -s ${stdenv.cc}/bin/g++ $out/bin/$(basename "$i")
      done
      ln -sf ${stdenv.cc.cc}/bin/{,*-gnu-}gcc-{ar,nm,ranlib} $out/bin
    '';
  };

  # Build dependencies (matches OpenWrt's documented requirements)
  # gccFixWrapper MUST come first to override the broken arch-prefixed gcc
  # that leaks from stdenv.cc (nixpkgs#21751)
  buildDeps = [
    gccFixWrapper # Must be before stdenv.cc to override broken binaries
    stdenv.cc
    bash
    bison
    cacert
    cdrtools
    curl
    file
    flex
    gawk
    gettext
    git
    ncurses
    openssl
    perl
    pkg-config
    swig
    unzip
    util-linux
    wget
    which
    rsync
    zlib
    (python3.withPackages (ps: [ ps.setuptools ]))
  ];

  # FHS environment for OpenWrt build
  fhsWrapper = buildFHSEnv {
    name = "openwrt-fhs";
    targetPkgs = _: buildDeps;
    extraOutputsToInstall = [ "dev" ];
    runScript = writeScript "exec-args" ''
      #!${bash}/bin/bash
      exec "$@"
    '';
  };

  runInFHS =
    drv:
    lib.overrideDerivation drv (old: {
      builder = "${fhsWrapper}/bin/${fhsWrapper.name}";
      args = [ old.builder ] ++ old.args;
    });

  # Pre-fetch all feeds
  fetchedFeeds = map (feed: {
    inherit (feed) name;
    src = fetchFromGitHub {
      owner = feed.owner;
      repo = feed.repo;
      rev = feed.rev;
      hash = feed.hash;
    };
  }) feeds;

  # Common setup: copy pre-fetched feeds
  setupFeeds = ''
    mkdir -p feeds
    ${lib.concatMapStringsSep "\n" (
      feed: "cp -r ${feed.src} feeds/${feed.name} && chmod -R u+w feeds/${feed.name}"
    ) fetchedFeeds}
  '';

  # Setup config: index feeds and apply build configuration
  setupConfig = ''
    ./scripts/feeds update -a -i
    ./scripts/feeds install -a
    cp ${effectiveConfig} .config
    chmod u+w .config
    make defconfig
  '';

  # Nix's binutils-wrapper exports AS=as, AR=ar, LD=ld, etc.
  # TF-A's toolchain.mk uses these if defined, bypassing CROSS_COMPILE derivation,
  # which causes the host assembler to be used instead of the cross-assembler.
  unsetToolVars = ''
    unset AS AR LD NM OBJCOPY OBJDUMP RANLIB READELF SIZE STRIP STRINGS
  '';

  # Copy extra files into source tree: { "path/in/tree" = ./local/file; }
  copyExtraFiles =
    extraFiles:
    lib.concatStringsSep "\n" (lib.mapAttrsToList (dest: src: "cp ${src} ${dest}") extraFiles);

  # Build downloads FOD
  mkDownloads =
    {
      downloadsHash,
      extraFiles ? { },
    }:
    runInFHS (
      stdenv.mkDerivation {
        pname = "openwrt-downloads-${target}-${subtarget}";
        inherit version;
        src = openwrtSrc;

        outputHash = downloadsHash;
        outputHashMode = "recursive";
        outputHashAlgo = "sha256";

        # Pass through proxy settings from host environment for users behind corporate proxies
        # Set these in your environment: http_proxy, https_proxy, ftp_proxy, all_proxy
        impureEnvVars = lib.fetchers.proxyImpureEnvVars;

        nativeBuildInputs = buildDeps;
        dontConfigure = true;
        dontFixup = true;
        hardeningDisable = [ "all" ];

        postPatch = ''
          ${setupFeeds}
          ${copyExtraFiles extraFiles}
        '';

        buildPhase = ''
          ${unsetToolVars}
          ${setupConfig}

          # Phase 1: download tools, toolchain, and selected packages via
          # the toplevel download target (also compiles flock/zstd/mkhash).
          make download -j''${NIX_BUILD_CORES:-1} V=s

          # Phase 1b: download ALL tool sources (not just tools-y).
          # The toplevel `make download` only fetches tools in builddirs-default
          # (= tools-y). Conditional tools like liblzo (compile dep of lzop) are
          # skipped. CHECK_ALL=1 on tools/download specifically expands just the
          # tools list without affecting package selection.
          make tools/download CHECK_ALL=1 -j''${NIX_BUILD_CORES:-1} V=s

          # Phase 2: download transitive compile-time dependencies.
          # The toplevel `make download` only fetches sources for selected
          # packages (CONFIG_PACKAGE_*=y/m). But the full build also needs
          # sources for compile-time dependencies (e.g. ncurses is needed
          # to build util-linux). Use Make to resolve the conditional
          # dependency graph from .packagedeps (respecting $(if ...) guards),
          # then BFS in Python to compute the transitive closure.
          #
          # Note: `make package/download CHECK_ALL=1` would be simpler but
          # downloads ALL packages including unrelated targets, hitting
          # non-deterministic git archives (zstd -T0) that break FOD hashing.

          # Dump resolved compile deps via Make (evaluates $(if CONFIG_X,...) against .config)
          make -f ${./dump-deps.mk} __dump 2>/dev/null > /tmp/resolved_deps.txt

          # Compute transitive closure and find extra packages to download
          python3 ${./resolve-extra-downloads.py} /tmp/resolved_deps.txt tmp/.packageinfo \
            | sort -u > /tmp/extra_downloads.txt

          echo "=== Downloading $(wc -l < /tmp/extra_downloads.txt) extra compile-dep packages ==="
          while read -r srcdir; do
            make "package/$srcdir/download" V=s
          done < /tmp/extra_downloads.txt
        '';

        installPhase = ''
          mkdir -p $out
          cp -r dl $out/
        '';
      }
    );

  # Build ImageBuilder
  mkImageBuilder =
    {
      downloads,
      extraFiles ? { },
    }:
    runInFHS (
      stdenv.mkDerivation {
        pname = "openwrt-imagebuilder-${target}-${subtarget}";
        inherit version;
        src = openwrtSrc;
        nativeBuildInputs = buildDeps;
        dontConfigure = true;
        dontFixup = true;
        hardeningDisable = [ "all" ];

        postPatch = ''
          cp -r ${downloads}/dl .
          chmod -R u+w dl
          ${setupFeeds}
          ${copyExtraFiles extraFiles}
        '';

        buildPhase = ''
          ${unsetToolVars}
          ${setupConfig}
          make -j''${NIX_BUILD_CORES:-1} V=s
        '';

        installPhase = ''
          mkdir -p $out
          cp -v bin/targets/${target}/${subtarget}/* $out/
        '';
      }
    );

  # Create final image
  mkImageFromBuilder =
    {
      imagebuilder,
      profile,
      files ? null,
      packages ? [ ],
      extraMakeFlags ? [ ],
    }:
    runInFHS (
      stdenv.mkDerivation {
        pname = "openwrt-image-${profile}";
        inherit version;
        src = imagebuilder;
        nativeBuildInputs = buildDeps;
        dontConfigure = true;
        dontFixup = true;

        unpackPhase = ''
          tar xf $src/openwrt-imagebuilder-*.tar.*
          cd openwrt-imagebuilder-*
          sourceRoot=$(pwd)
        '';

        buildPhase = ''
          ${lib.optionalString (files != null) "cp -rv ${files}/* files/ || mkdir -p files"}
          make image PROFILE='${profile}' \
            PACKAGES='${lib.concatStringsSep " " packages}' \
            ${lib.optionalString (files != null) "FILES=files/"} \
            ${lib.concatStringsSep " " extraMakeFlags} V=s
        '';

        installPhase = ''
          mkdir -p $out

          # Copy firmware files — not all extensions exist for every target,
          # so use find instead of globs that would fail with set -e.
          find bin/targets/${target}/${subtarget} -maxdepth 1 \
            \( -name '*.itb' -o -name '*.bin' -o -name '*.fip' \
               -o -name '*.img.gz' -o -name 'sha256sums' \) \
            -exec cp -v {} $out/ \;

          # Create convenience symlinks for common upgrade paths
          # Note: These patterns may vary between OpenWrt versions and targets
          cd $out
          for f in *-squashfs-sysupgrade.itb; do
            [ -f "$f" ] && ln -sf "$f" sysupgrade.itb
          done
          for f in *-sdcard.img.gz; do
            [ -f "$f" ] && ln -sf "$f" sdcard.img.gz
          done
        '';
      }
    );
in
{
  # High-level: build complete image in one call
  mkImage =
    {
      packages ? [ ],
      files ? null,
      extraFiles ? { },
      downloadsHash,
      extraMakeFlags ? [ ],
    }:
    let
      downloads = mkDownloads { inherit downloadsHash extraFiles; };
      imagebuilder = mkImageBuilder { inherit downloads extraFiles; };
      imageProfile = assert profile != null; profile;
    in
    mkImageFromBuilder {
      inherit
        imagebuilder
        files
        packages
        extraMakeFlags
        ;
      profile = imageProfile;
    };

  # Low-level: expose individual stages for debugging/incremental builds
  downloads =
    {
      downloadsHash,
      extraFiles ? { },
    }:
    mkDownloads { inherit downloadsHash extraFiles; };

  imagebuilder =
    {
      downloadsHash,
      extraFiles ? { },
    }:
    let
      downloads = mkDownloads { inherit downloadsHash extraFiles; };
    in
    mkImageBuilder { inherit downloads extraFiles; };

  # Expose metadata
  inherit version target subtarget;
}
