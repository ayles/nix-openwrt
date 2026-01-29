"""OpenWrt package dependency resolution utilities.

Subcommands:
  extra-downloads  — print source dirs needing download beyond the selected set
  make-targets     — map package names to Make compile targets (handles variants)
  go-mod-sources   — print source tarballs for Go packages (need module pre-fetch)

Usage:
    make -f dump-deps.mk __dump 2>/dev/null > /tmp/deps.txt

    # Extra downloads for full build or SDK
    python3 openwrt_packages.py extra-downloads /tmp/deps.txt tmp/.packageinfo

    # Map package names to per-package Make targets (SDK compilation)
    python3 openwrt_packages.py make-targets tmp/.packageinfo dnsmasq-full curl htop

    # List source tarballs for Go packages
    python3 openwrt_packages.py go-mod-sources tmp/.packageinfo
"""

import re
import sys


def parse_deps(deps_path):
    """Parse DEPS:/SELECTED: lines from dump-deps.mk output."""
    compile_deps = {}
    selected = set()

    with open(deps_path) as f:
        for line in f:
            line = line.strip()
            if line.startswith("SELECTED:"):
                selected.add(line[9:])
            elif line.startswith("DEPS:"):
                parts = line[5:].split(":", 1)
                if len(parts) == 2:
                    compile_deps[parts[0]] = set(parts[1].split())

    return compile_deps, selected


def transitive_closure(roots, compile_deps):
    """Compute transitive closure of compile dependencies."""
    closure = set()
    queue = list(roots)
    while queue:
        node = queue.pop()
        if node in closure:
            continue
        closure.add(node)
        for dep in compile_deps.get(node, set()):
            if dep not in closure:
                queue.append(dep)
    return closure


def parse_packageinfo(pkginfo_path):
    """Parse tmp/.packageinfo for source dirs and downloadable packages."""
    has_source = set()
    name_to_dir = {}
    cur = None

    with open(pkginfo_path) as f:
        for line in f:
            m = re.match(r"Source-Makefile: package/(.+)/Makefile", line)
            if m:
                cur = m.group(1)
                continue
            m = re.match(r"Package: (\S+)", line)
            if m and cur:
                name_to_dir[m.group(1)] = cur
                continue
            m = re.match(r"Source: (\S+)", line)
            if m and cur:
                has_source.add(cur)

    return name_to_dir, has_source


def cmd_extra_downloads(deps_path, pkginfo_path):
    """Print source dirs that need downloading beyond the selected set."""
    compile_deps, selected = parse_deps(deps_path)
    closure = transitive_closure(selected, compile_deps)
    _, has_source = parse_packageinfo(pkginfo_path)

    extra = closure - selected
    for d in sorted(extra):
        dl = d.removesuffix("/host")
        if dl in has_source:
            print(dl)


def cmd_make_targets(pkginfo_path, package_names):
    """Map package names to per-package Make compile targets.

    Handles variants (e.g. dnsmasq-full -> package/dnsmasq/compile)
    by resolving through tmp/.packageinfo source dirs and extracting
    the last path component. OpenWrt's build system registers each
    source dir's basename as a Make target alias (PKG_NAME defaults
    to the directory name), so package/dnsmasq/compile works regardless
    of the full source path (network/services/dnsmasq).
    """
    name_to_dir, _ = parse_packageinfo(pkginfo_path)

    seen = set()
    for name in package_names:
        srcdir = name_to_dir.get(name)
        if srcdir is None:
            print(f"Warning: package '{name}' not found in .packageinfo", file=sys.stderr)
            continue
        diralias = srcdir.rsplit("/", 1)[-1]
        if diralias not in seen:
            seen.add(diralias)
            print(f"package/{diralias}/compile")


def cmd_go_mod_sources(pkginfo_path):
    """Print source tarballs for Go packages (those with golang in Build-Depends).

    OpenWrt's `make download` only fetches source tarballs, not Go modules.
    Modules are fetched implicitly by `go install` during compile.  In an
    offline compile (nix-openwrt's model), we need to pre-fetch them in the
    FOD stage by extracting each source and running `go mod download`.
    """
    go_sources = set()
    cur_dir = None
    cur_tarball = None
    cur_is_go = False

    with open(pkginfo_path) as f:
        for line in f:
            line = line.rstrip("\n")
            m = re.match(r"Source-Makefile: package/(.+)/Makefile", line)
            if m:
                if cur_dir and cur_tarball and cur_is_go:
                    go_sources.add(cur_tarball)
                cur_dir = m.group(1)
                cur_tarball = None
                cur_is_go = False
                continue
            m = re.match(r"Source: (\S+)", line)
            if m and cur_dir:
                cur_tarball = m.group(1)
                continue
            if re.match(r"Build-Depends:.*golang", line) and cur_dir:
                cur_is_go = True

    if cur_dir and cur_tarball and cur_is_go:
        go_sources.add(cur_tarball)

    for src in sorted(go_sources):
        print(src)


def main():
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <extra-downloads|make-targets|go-mod-sources> ...", file=sys.stderr)
        sys.exit(1)

    cmd = sys.argv[1]
    if cmd == "extra-downloads":
        deps_path = sys.argv[2] if len(sys.argv) > 2 else "/tmp/deps.txt"
        pkginfo_path = sys.argv[3] if len(sys.argv) > 3 else "tmp/.packageinfo"
        cmd_extra_downloads(deps_path, pkginfo_path)
    elif cmd == "make-targets":
        pkginfo_path = sys.argv[2]
        package_names = sys.argv[3:]
        cmd_make_targets(pkginfo_path, package_names)
    elif cmd == "go-mod-sources":
        pkginfo_path = sys.argv[2] if len(sys.argv) > 2 else "tmp/.packageinfo"
        cmd_go_mod_sources(pkginfo_path)
    else:
        print(f"Unknown command: {cmd}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
