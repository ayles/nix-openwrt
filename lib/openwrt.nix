# OpenWrt from-source builder
#
# Usage:
#   openwrt = pkgs.callPackage ./lib/openwrt.nix {
#     openwrtVersion = "25.12.0-rc2";
#     openwrtRev = "4dd2e6ec5b81becd32dc25d85d977510d363a419";
#     openwrtHash = "sha256-...";
#     target = "mediatek";
#     subtarget = "filogic";
#     configUrl = "https://downloads.openwrt.org/releases/...";
#     configHash = "sha256-...";
#     feeds = [ { name = "packages"; owner = "openwrt"; ... } ];
#   };
#
#   openwrt.mkImage {
#     profile = "bananapi_bpi-r4";
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
  llvmPackages,
  fetchFromGitHub,
  fetchurl,
  # OpenWrt configuration
  openwrtVersion,
  openwrtRev,
  openwrtHash,
  target,
  subtarget,
  configUrl,
  configHash,
  feeds,
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

  # Fetch config.buildinfo for vermagic compatibility
  buildConfig = fetchurl {
    url = configUrl;
    hash = configHash;
  };

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
    llvmPackages.stdenv.cc
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

  # Common setup: configure feeds and build config
  setupBuild = ''
    ./scripts/feeds update -a -i
    ./scripts/feeds install -a
    cp ${buildConfig} .config
    chmod u+w .config
    echo "CONFIG_BPF_TOOLCHAIN_HOST=y" >> .config
    make defconfig
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

        postPatch = ''
          ${setupFeeds}
          ${copyExtraFiles extraFiles}
        '';

        buildPhase = ''
          ${setupBuild}

          # Download all sources needed for the build
          # The .config file determines what will be built, and thus what needs to be downloaded

          # 1. Download toolchain (sequential to avoid races)
          echo "==> Downloading toolchain sources..."
          if ! make toolchain/download -j1 V=s; then
            echo "ERROR: Failed to download toolchain sources"
            exit 1
          fi

          # 2. Download tools (parallel downloads)
          echo "==> Downloading build tool sources..."
          if ! make tools/download -j''${NIX_BUILD_CORES:-1} V=s; then
            echo "ERROR: Failed to download tool sources"
            exit 1
          fi

          # 3. Download all package sources (parallel downloads)
          # This includes both target and host packages based on what's enabled in .config
          echo "==> Downloading package sources..."
          if ! make download -j''${NIX_BUILD_CORES:-1} V=s; then
            echo "ERROR: Failed to download package sources"
            exit 1
          fi

          # 4. Verify all required sources are present
          echo "==> Verifying downloads..."
          if ! make check V=s; then
            echo "WARNING: Some downloads may be missing or have incorrect checksums"
            echo "Continuing anyway - build will fail later if truly needed"
          fi

          echo "==> Download phase complete"
          echo "Downloaded files:"
          du -sh dl/ || true
          find dl/ -type f | wc -l || true
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
          ${setupBuild}
          make -j''${NIX_BUILD_CORES:-1} V=s
        '';

        installPhase = ''
          mkdir -p $out

          # Copy ImageBuilder tarball
          if ! cp -v bin/targets/${target}/${subtarget}/openwrt-imagebuilder-*.tar.* $out/ 2>/dev/null; then
            echo "ERROR: ImageBuilder tarball not found!"
            echo "Expected: bin/targets/${target}/${subtarget}/openwrt-imagebuilder-*.tar.*"
            echo "Contents of bin/targets/${target}/${subtarget}/:"
            ls -la bin/targets/${target}/${subtarget}/ || true
            exit 1
          fi

          # Optional: SDK and metadata (may not always be built)
          cp -v bin/targets/${target}/${subtarget}/openwrt-sdk-*.tar.* $out/ 2>/dev/null || true
          cp -v bin/targets/${target}/${subtarget}/sha256sums $out/ 2>/dev/null || true
          cp -v bin/targets/${target}/${subtarget}/profiles.json $out/ 2>/dev/null || true
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

          # Copy all firmware files (different targets use different extensions)
          cp -v bin/targets/${target}/${subtarget}/*.{itb,bin,fip} $out/ 2>/dev/null || true
          cp -v bin/targets/${target}/${subtarget}/*.img.gz $out/ 2>/dev/null || true
          cp -v bin/targets/${target}/${subtarget}/sha256sums $out/ 2>/dev/null || true

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
      profile,
      packages ? [ ],
      files ? null,
      extraFiles ? { },
      downloadsHash,
      extraMakeFlags ? [ ],
    }:
    let
      downloads = mkDownloads { inherit downloadsHash extraFiles; };
      imagebuilder = mkImageBuilder { inherit downloads extraFiles; };
    in
    mkImageFromBuilder {
      inherit
        imagebuilder
        profile
        files
        packages
        extraMakeFlags
        ;
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
