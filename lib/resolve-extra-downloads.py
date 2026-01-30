"""Resolve extra package downloads needed for an OpenWrt build.

Reads the dependency graph dumped by dump-deps.mk and computes the
transitive closure of compile-time dependencies. Prints source
directories that need downloading but aren't in the selected set.

Usage (from OpenWrt source root):
    make -f dump-deps.mk __dump 2>/dev/null > /tmp/resolved_deps.txt
    python3 resolve-extra-downloads.py /tmp/resolved_deps.txt tmp/.packageinfo
"""

import re
import sys


def parse_deps(deps_path):
    """Parse DEPS:/SELECTED: lines from Make dump."""
    compile_deps = {}  # src_dir -> set of dep src_dirs
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


def bfs_closure(selected, compile_deps):
    """Compute transitive closure of compile dependencies via BFS."""
    closure = set()
    queue = list(selected)
    while queue:
        node = queue.pop()
        if node in closure:
            continue
        closure.add(node)
        for dep in compile_deps.get(node, set()):
            if dep not in closure:
                queue.append(dep)
    return closure


def packages_with_source(packageinfo_path):
    """Find packages that have downloadable source tarballs."""
    has_source = set()
    cur = None

    with open(packageinfo_path) as f:
        for line in f:
            m = re.match(r"Source-Makefile: package/(.+)/Makefile", line)
            if m:
                cur = m.group(1)
                continue
            m = re.match(r"Source: (\S+)", line)
            if m and cur:
                has_source.add(cur)

    return has_source


def main():
    deps_path = sys.argv[1] if len(sys.argv) > 1 else "/tmp/resolved_deps.txt"
    pkginfo_path = sys.argv[2] if len(sys.argv) > 2 else "tmp/.packageinfo"

    compile_deps, selected = parse_deps(deps_path)
    closure = bfs_closure(selected, compile_deps)
    has_source = packages_with_source(pkginfo_path)

    # Only download extras (already-selected packages are handled by `make download`)
    extra = closure - selected
    for d in sorted(extra):
        # Host variants (e.g. "feeds/packages/libffi/host") share their
        # parent's source directory — map to the download target.
        dl = d[:-5] if d.endswith("/host") else d
        if dl in has_source:
            print(dl)


if __name__ == "__main__":
    main()
