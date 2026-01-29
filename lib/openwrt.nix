# OpenWrt from-source builder for Nix.
#
# Usage:
#   openwrt = nix-openwrt.lib.build {
#     inherit pkgs;
#     src = pkgs.fetchFromGitHub { owner = "openwrt"; repo = "openwrt"; ... };
#     config = pkgs.fetchurl { url = "https://downloads.openwrt.org/.../config.buildinfo"; ... };
#     version = "25.12.1";  # optional, defaults to src.rev
#     target = "mediatek";
#     subtarget = "filogic";
#     profile = "bananapi_bpi-r4";
#     downloadsHash = "sha256-...";
#   };
#
#   openwrt.mkImage {
#     packages = [ "luci" "htop" ];
#     files = ./files;
#   };
#
# Pipeline:
#   1. Downloads FOD — clone feeds, download sources, pre-fetch Go modules (has network)
#   2. Full build — compile toolchain, kernel, base packages, ImageBuilder, SDK
#   3. mkImage — assemble firmware from ImageBuilder + compiled packages
#   4. mkPackages — compile extra packages via SDK (own downloads FOD + offline build)
#
{
  lib,
  buildFHSEnv,
  runCommand,
  stdenv,
  writeScript,
  writeText,
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
  src,
  version ? src.rev,
  config,
  target,
  subtarget,
  profile ? null,
  downloadsHash,
  # Source tree patches: { "path/in/tree" = ./local/file; }
  # nix-openwrt's own build-fix patches are applied automatically.
  patches ? { },
  # Extra packages available in the FHS build environment.
  extraBuildInputs ? [ ],
  # Extra Kconfig lines appended to .config before `make defconfig`.
  extraConfig ? "",
}:

let
  # Combine user patches with nix-openwrt's build-fix patches.
  nixPatches = {
    "package/system/apk/patches/0020-apk-use-fat-lto-objects.patch" = ./patches/apk-fat-lto-objects.patch;
    "tools/fakeroot/patches/900-einval.patch" = ./patches/fakeroot-einval.patch;
  };
  allPatches = nixPatches // patches;
  extraConfigFile = writeText "extra-config" extraConfig;

  # Filter config to selected device profile (multi-device configs enable all devices)
  effectiveConfig =
    if profile == null then
      config
    else
      assert lib.assertMsg (builtins.match "[a-zA-Z0-9_-]+" profile != null)
        "profile '${profile}' contains characters unsafe for sed regex";
      runCommand "openwrt-config-${profile}" { } ''
        sed -e '/^CONFIG_TARGET_DEVICE_PACKAGES_/!s/^CONFIG_TARGET_DEVICE_\(.*\)=y$/# CONFIG_TARGET_DEVICE_\1 is not set/' \
            -e 's/^# CONFIG_TARGET_DEVICE_\(.*_DEVICE_${profile}\) is not set$/CONFIG_TARGET_DEVICE_\1=y/' \
            -e '/^CONFIG_TARGET_DEVICE_PACKAGES_.*_DEVICE_${profile}="/!{/^CONFIG_TARGET_DEVICE_PACKAGES_/d}' \
            ${config} > $out
      '';

  # Workaround for nixpkgs#21751: unwrapped GCC leaks arch-prefixed binaries
  # that can't link properly. Symlink them to the wrapped gcc.
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

  # gccFixWrapper must come first to shadow broken arch-prefixed binaries
  baseBuildDeps = [
    gccFixWrapper
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

  buildDeps = baseBuildDeps ++ extraBuildInputs;

  mkFhsWrapper =
    name: deps:
    buildFHSEnv {
      inherit name;
      targetPkgs = _: deps;
      extraOutputsToInstall = [ "dev" ];
      runScript = writeScript "exec-args" ''
        #!${bash}/bin/bash
        exec "$@"
      '';
    };

  # overrideDerivation (not overrideAttrs) is needed to access the
  # resolved builder/args that stdenv.mkDerivation computes internally.
  wrapInFHS =
    wrapper: drv:
    lib.overrideDerivation drv (old: {
      builder = "${wrapper}/bin/${wrapper.name}";
      args = [ old.builder ] ++ old.args;
    });

  fhsWrapper = mkFhsWrapper "openwrt-fhs-${target}-${subtarget}" buildDeps;
  runInFHS = wrapInFHS fhsWrapper;

  setupFeedsClone = ''
    ./scripts/feeds update -a
    find feeds -name .git -type d -prune -exec rm -rf {} +
  '';

  # Copy a Nix store path and make writable (store paths are read-only).
  # -rT treats dest as the target path, not a container — prevents
  # creating dest/basename(src) when dest already exists.
  copyWritable =
    src: dest: ''
      cp -rT ${src} ${dest}
      chmod -R u+w ${dest}
    '';

  setupConfig = ''
    ./scripts/feeds update -a -i
    ./scripts/feeds install -a
    cp ${effectiveConfig} .config
    chmod u+w .config
    cat ${extraConfigFile} >> .config
    make defconfig
  '';

  # Nix's binutils-wrapper exports AS/AR/LD/etc which break TF-A cross-compilation.
  unsetToolVars = ''
    unset AS AR LD NM OBJCOPY OBJDUMP RANLIB READELF SIZE STRIP STRINGS
  '';

  copyExtraFiles =
    files:
    lib.concatStringsSep "\n" (
      lib.mapAttrsToList (dest: src: "install -Dm644 ${src} ${dest}") files
    );

  # Download transitive compile-time dependencies not fetched by `make download`.
  # PKG_BUILD_DEPENDS (e.g. lm-sensors for htop) are compile-only deps outside
  # Kconfig, so `make download` skips them. Resolve via Make + BFS, then fetch.
  downloadExtraDeps = ''
    make -f ${./dump-deps.mk} __dump 2>/dev/null > /tmp/deps.txt
    python3 ${./openwrt_packages.py} extra-downloads /tmp/deps.txt tmp/.packageinfo \
      | sort -u > /tmp/extra_downloads.txt

    count=$(wc -l < /tmp/extra_downloads.txt)
    if [ "$count" -gt 0 ]; then
      echo "=== Downloading $count extra compile-dep packages ==="
      sed 's|.*|package/&/download|' /tmp/extra_downloads.txt \
        | xargs make -j''${NIX_BUILD_CORES:-1} V=s
    fi
  '';

  # Pre-fetch Go modules for offline compilation.
  # OpenWrt's `make download` only fetches source tarballs. Go modules are
  # fetched implicitly by `go install` during compile, which fails offline.
  # Extract each Go package's source and run `go mod download` so modules
  # land in dl/go-mod-cache/ (where OpenWrt's golang-package.mk expects them).
  downloadGoModules = ''
    go_sources=$(python3 ${./openwrt_packages.py} go-mod-sources tmp/.packageinfo)
    if [ -n "$go_sources" ]; then
      echo "=== Pre-fetching Go modules ==="
      mkdir -p dl/go-mod-cache
      modcache=$(realpath dl/go-mod-cache)
      for src in $go_sources; do
        [ -f "dl/$src" ] || continue
        d=$(mktemp -d)
        tar xf "dl/$src" -C "$d"
        gomod=$(find "$d" -name go.mod -type f | head -1)
        if [ -n "$gomod" ]; then
          echo "Fetching Go modules for $src"
          (cd "$(dirname "$gomod")" && GOMODCACHE="$modcache" GOFLAGS=-modcacherw go mod download)
        fi
        rm -rf "$d"
      done
    fi
  '';

  # Stage 1: download sources (FOD — has network access)
  downloads = runInFHS (
    stdenv.mkDerivation {
      pname = "openwrt-downloads-${target}-${subtarget}";
      inherit version src;

      outputHash = downloadsHash;
      outputHashMode = "recursive";
      outputHashAlgo = "sha256";

      impureEnvVars = lib.fetchers.proxyImpureEnvVars;

      # nativeBuildInputs is needed alongside the FHS wrapper: the wrapper
      # provides the FHS filesystem layout, but stdenv's setup builds $PATH
      # from nativeBuildInputs. Without it, tools like perl aren't in PATH.
      nativeBuildInputs = buildDeps;
      dontConfigure = true;
      dontFixup = true;
      hardeningDisable = [ "all" ];

      postPatch = ''
        ${setupFeedsClone}
        ${copyExtraFiles allPatches}
      '';

      buildPhase = ''
        ${unsetToolVars}
        ${setupConfig}

        make download -j''${NIX_BUILD_CORES:-1} V=s

        # Download ALL tool sources (not just tools-y).
        # The toplevel `make download` skips conditional tools like liblzo.
        make tools/download CHECK_ALL=1 -j''${NIX_BUILD_CORES:-1} V=s

        ${downloadExtraDeps}
        ${downloadGoModules}
      '';

      installPhase = ''
        mkdir -p $out
        cp -r dl $out/
        cp -r feeds $out/
      '';
    }
  );

  # Stage 2: full build (offline — produces ImageBuilder, SDK, and all stock packages)
  fullBuild = runInFHS (
    stdenv.mkDerivation {
      pname = "openwrt-build-${target}-${subtarget}";
      inherit version src;
      nativeBuildInputs = buildDeps;
      dontConfigure = true;
      dontFixup = true;
      hardeningDisable = [ "all" ];

      postPatch = ''
        ${copyWritable "${downloads}/dl" "dl"}
        ${copyWritable "${downloads}/feeds" "feeds"}
        ${copyExtraFiles allPatches}
      '';

      buildPhase = ''
        ${unsetToolVars}
        ${setupConfig}
        make -j''${NIX_BUILD_CORES:-1} V=s
      '';

      installPhase = ''
        mkdir -p $out
        cp -r bin $out/bin
      '';
    }
  );

  # Stage 3: assemble firmware image from ImageBuilder
  mkImage =
    {
      files ? null,
      packages ? [ ],
      extraPackages ? [ ],
      extraMakeFlags ? [ ],
    }:
    let
      imageProfile =
        if profile == null
        then throw "mkImage requires 'profile' to be set in nix-openwrt.lib.build"
        else profile;
    in
    runInFHS (
      stdenv.mkDerivation {
        pname = "openwrt-image-${imageProfile}";
        inherit version;
        nativeBuildInputs = buildDeps;
        dontUnpack = true;
        dontConfigure = true;
        dontFixup = true;
        dontInstall = true;

        buildPhase = ''
          set -euo pipefail

          tar xf "${fullBuild}"/bin/targets/${target}/${subtarget}/openwrt-imagebuilder-*.tar.*
          cd openwrt-imagebuilder-*

          # Copy extraPackages first so they take precedence over stock packages.
          ${lib.concatMapStringsSep "\n" (dir: ''
            find "${dir}" -name '*.apk' -exec cp -nt packages/ {} +
          '') extraPackages}

          find "${fullBuild}"/bin/targets/${target}/${subtarget}/packages "${fullBuild}"/bin/packages \
            -name '*.apk' -exec cp -nt packages/ {} +

          ${lib.optionalString (files != null) ''
            mkdir -p files
            cp -rv ${files}/* files/
          ''}

          make image PROFILE='${imageProfile}' \
            PACKAGES='${lib.concatStringsSep " " packages}' \
            ${lib.optionalString (files != null) "FILES=files/"} \
            ${lib.concatStringsSep " " extraMakeFlags} V=s

          mkdir -p "$out"

          find bin/targets/${target}/${subtarget} -maxdepth 1 \
            \( -name '*.itb' -o -name '*.bin' -o -name '*.fip' \
               -o -name '*.img.gz' -o -name 'sha256sums' \) \
            -exec cp -vt "$out/" {} +

          cd "$out"
          for f in *-squashfs-sysupgrade.itb; do
            [ -f "$f" ] && ln -sf "$f" sysupgrade.itb
          done
          for f in *-sdcard.img.gz; do
            [ -f "$f" ] && ln -sf "$f" sdcard.img.gz
          done
        '';
      }
    );

  # Compile packages via SDK (without full rebuild)
  mkPackages =
    {
      packages,
      downloadsHash,
      feed ? null,
      extraBuildInputs ? [ ],
      extraConfig ? "",
    }:
    let
      feedName = if feed != null then feed.name else "stock";
      sdkExtraConfigFile = writeText "sdk-extra-config" extraConfig;

      sdkDeps = buildDeps ++ extraBuildInputs;
      sdkFhsWrapper =
        if extraBuildInputs == [ ] then fhsWrapper
        else mkFhsWrapper "openwrt-sdk-fhs-${target}-${subtarget}" sdkDeps;
      runInSDKFHS = wrapInFHS sdkFhsWrapper;

      # Enable requested packages in SDK config
      enablePackages = lib.concatMapStringsSep "\n"
        (pkg: "echo 'CONFIG_PACKAGE_${pkg}=m' >> .config") packages;

      # Compile per-package using Make's native dependency resolution.
      # Map package names to Make targets (handles variants like dnsmasq-full → dnsmasq).
      # Single make invocation lets Make parallelize independent packages.
      compilePackages = ''
        targets=$(python3 ${./openwrt_packages.py} make-targets tmp/.packageinfo \
          ${lib.concatStringsSep " " packages})
        if [ -z "$targets" ]; then
          echo "Error: no Make targets resolved for requested packages"
          exit 1
        fi
        echo "=== Building: $targets ==="
        make $targets -j''${NIX_BUILD_CORES:-1} V=s
      '';

      # SDK setup: extract tarball, populate feeds, select requested packages
      sdkSetup = ''
        tar xf ${fullBuild}/bin/targets/${target}/${subtarget}/openwrt-sdk-*.tar.*
        cd openwrt-sdk-*

        # SDK doesn't ship feed sources — copy from downloads FOD.
        # feeds/base is a symlink to ../package (the base package tree),
        # which doesn't exist in the SDK. Copy userspace base packages;
        # skip kernel/ and boot/ which reference target/linux/ (absent in SDK).
        ${copyWritable "${downloads}/feeds" "feeds"}
        rm -f feeds/base
        mkdir feeds/base
        for d in ${src}/package/*/; do
          case "$(basename "$d")" in
            kernel|boot) ;;
            *) cp -r "$d" feeds/base/ ;;
          esac
        done
        chmod -R u+w feeds/base

        ${lib.optionalString (feed != null) ''
          cp feeds.conf.default feeds.conf
          echo "src-link ${feed.name} $(pwd)/feeds/${feed.name}" >> feeds.conf
          ${copyWritable "${feed.src}" "feeds/${feed.name}"}
        ''}

        ./scripts/feeds update -a -i
        ${lib.optionalString (feed != null) "./scripts/feeds install -a -p ${feed.name}"}
        ./scripts/feeds install -a

        # SDK defaults CONFIG_ALL=y which selects every package.
        # Write a minimal .config disabling bulk selection, then defconfig
        # resolves dependencies for only our requested packages.
        echo '# CONFIG_ALL is not set' > .config
        echo '# CONFIG_ALL_KMODS is not set' >> .config
        echo '# CONFIG_ALL_NONSHARED is not set' >> .config
        ${enablePackages}
        cat ${sdkExtraConfigFile} >> .config
        make defconfig
      '';

      # FOD: download sources for the selected packages
      sdkDownloads = runInSDKFHS (
        stdenv.mkDerivation {
          pname = "openwrt-sdk-downloads-${target}-${subtarget}-${feedName}";
          inherit version;
          dontUnpack = true;

          outputHash = downloadsHash;
          outputHashMode = "recursive";
          outputHashAlgo = "sha256";

          impureEnvVars = lib.fetchers.proxyImpureEnvVars;
          nativeBuildInputs = sdkDeps;
          dontConfigure = true;
          dontFixup = true;
          hardeningDisable = [ "all" ];

          buildPhase = ''
            ${sdkSetup}

            # Seed dl/ from the main build's downloads, then fetch any extras.
            ${copyWritable "${downloads}/dl" "dl"}
            make download -j''${NIX_BUILD_CORES:-1} V=s

            ${downloadExtraDeps}
            ${downloadGoModules}
          '';

          installPhase = ''
            mkdir -p $out
            cp -r dl $out/
          '';
        }
      );
    in
    runInSDKFHS (
      stdenv.mkDerivation {
        pname = "openwrt-packages-${target}-${subtarget}-${feedName}";
        inherit version;
        nativeBuildInputs = sdkDeps;
        dontUnpack = true;
        dontConfigure = true;
        dontFixup = true;
        hardeningDisable = [ "all" ];

        buildPhase = ''
          ${unsetToolVars}
          ${sdkSetup}

          ${copyWritable "${sdkDownloads}/dl" "dl"}

          ${compilePackages}
        '';

        installPhase = ''
          mkdir -p $out
          find bin/packages -name '*.apk' -exec cp -t $out/ {} +
          find bin/targets -name '*.apk' -exec cp -t $out/ {} +
        '';
      }
    );

in
{
  inherit mkImage mkPackages;
  inherit version target subtarget;
}
