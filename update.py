#!/usr/bin/env nix-shell
#!nix-shell -i python3 -p python3 nix nix-prefetch-github cacert
"""
OpenWrt device configuration generator for nix-openwrt.

This script generates Nix attribute sets for OpenWrt device configurations
that can be added to lib/devices.nix.

Usage:
    # Generate config for a new device
    ./update.py my-router --version 25.12.0-rc2 --target mediatek --subtarget filogic --profile bananapi_bpi-r4

    # Update existing device
    ./update.py bananapi-r4 --version 25.12.0-rc3

    # Specify custom profile name
    ./update.py my-router --version 25.12.0-rc2 --target x86 --subtarget 64 --profile generic

The script will output Nix code that you can copy into lib/devices.nix.
"""

import argparse
import json
import re
import subprocess
import sys
import urllib.request
from typing import Any


def run(cmd: list[str], **kwargs) -> subprocess.CompletedProcess:
    """Run a command and return the result."""
    print(f"  $ {' '.join(cmd)}", file=sys.stderr)
    return subprocess.run(cmd, **kwargs)


def prefetch_github(owner: str, repo: str, rev: str) -> dict[str, Any]:
    """Prefetch a GitHub repository and return hash info."""
    result = run(
        ["nix-prefetch-github", owner, repo, "--rev", rev, "--json"],
        capture_output=True,
        text=True,
        check=True,
    )
    return json.loads(result.stdout)


def prefetch_url(url: str) -> str:
    """Prefetch a URL and return its SRI hash."""
    result = run(
        ["nix-prefetch-url", url, "--type", "sha256"],
        capture_output=True,
        text=True,
        check=True,
    )
    hash_hex = result.stdout.strip()
    sri_result = run(
        ["nix", "hash", "to-sri", "--type", "sha256", hash_hex],
        capture_output=True,
        text=True,
        check=True,
    )
    return sri_result.stdout.strip()


def parse_feeds_conf(content: str) -> list[dict[str, Any]]:
    """Parse feeds.conf.default content into structured data."""
    feeds = []
    for line in content.strip().split("\n"):
        line = line.strip()
        if not line or line.startswith("#"):
            continue

        match = re.match(r"^(src-git(?:-full)?)\s+(\S+)\s+(\S+)$", line)
        if not match:
            continue

        method, name, url_spec = match.groups()

        if "^" in url_spec:
            url, commit = url_spec.rsplit("^", 1)
        else:
            url = url_spec
            commit = None

        # Convert openwrt git URLs to GitHub for faster fetching
        github_url = url
        if "git.openwrt.org/feed/" in url or "git.openwrt.org/project/" in url:
            repo_name = url.split("/")[-1].replace(".git", "")
            github_url = f"https://github.com/openwrt/{repo_name}"

        feeds.append(
            {
                "name": name,
                "method": method,
                "url": github_url,
                "originalUrl": url,
                "rev": commit,
            }
        )

    return feeds


def format_feed_nix(feed: dict[str, Any], indent: int = 6) -> str:
    """Format a feed as a Nix attribute set."""
    ind = " " * indent
    return f"""{ind}{{
{ind}  name = "{feed['name']}";
{ind}  owner = "{feed['owner']}";
{ind}  repo = "{feed['repo']}";
{ind}  rev = "{feed['rev']}";
{ind}  hash = "{feed['hash']}";
{ind}}}"""


def format_device_config_nix(
    device_name: str,
    version: str,
    openwrt_info: dict[str, Any],
    target: str,
    subtarget: str,
    profile: str,
    config_url: str,
    config_hash: str | None,
    feeds: list[dict[str, Any]],
) -> str:
    """Format a complete device configuration as Nix code."""
    feeds_nix = "\n".join(format_feed_nix(feed) for feed in feeds)

    config_section = (
        f"""    # Official build configuration (for vermagic compatibility)
    configUrl = "{config_url}";
    configHash = "{config_hash}";"""
        if config_hash
        else """    # Official build configuration not available yet
    # Use a local .config file or wait for official release
    # configUrl = "{config_url}";
    # configHash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";"""
    )

    return f'''  {device_name} = {{
    # OpenWrt source
    openwrtVersion = "{version}";
    openwrtRev = "{openwrt_info['rev']}";
    openwrtHash = "{openwrt_info['hash']}";

    # Target configuration
    target = "{target}";
    subtarget = "{subtarget}";
    profile = "{profile}";

{config_section}

    # Package feeds
    feeds = [
{feeds_nix}
    ];
  }};'''


def main():
    parser = argparse.ArgumentParser(
        description="Generate OpenWrt device configuration for nix-openwrt"
    )
    parser.add_argument(
        "device_name",
        help="Device name (e.g., bananapi-r4, x86-64-generic)",
    )
    parser.add_argument(
        "--version",
        required=True,
        help="OpenWrt version (e.g., 25.12.0-rc2)",
    )
    parser.add_argument(
        "--target",
        required=True,
        help="Target platform (e.g., mediatek, x86)",
    )
    parser.add_argument(
        "--subtarget",
        required=True,
        help="Subtarget (e.g., filogic, 64)",
    )
    parser.add_argument(
        "--profile",
        help="Device profile (e.g., bananapi_bpi-r4). Defaults to device_name with hyphens as underscores",
    )
    args = parser.parse_args()

    # Default profile is device name with hyphens converted to underscores
    profile = args.profile or args.device_name.replace("-", "_")

    print(f"\n==> Generating configuration for {args.device_name}", file=sys.stderr)
    print(f"    Version: {args.version}", file=sys.stderr)
    print(f"    Target: {args.target}/{args.subtarget}", file=sys.stderr)
    print(f"    Profile: {profile}", file=sys.stderr)

    # Step 1: Prefetch OpenWrt source
    print(f"\n==> Prefetching OpenWrt v{args.version}...", file=sys.stderr)
    openwrt_info = prefetch_github("openwrt", "openwrt", f"v{args.version}")

    # Step 2: Fetch and parse feeds.conf.default
    print(f"\n==> Fetching feeds.conf.default...", file=sys.stderr)
    feeds_url = f"https://raw.githubusercontent.com/openwrt/openwrt/v{args.version}/feeds.conf.default"
    print(f"  From: {feeds_url}", file=sys.stderr)

    try:
        with urllib.request.urlopen(feeds_url) as response:
            feeds_conf_content = response.read().decode()
    except Exception as e:
        print(f"  ERROR: Failed to fetch feeds.conf.default: {e}", file=sys.stderr)
        sys.exit(1)

    feeds = parse_feeds_conf(feeds_conf_content)
    print(f"  Found {len(feeds)} feeds", file=sys.stderr)

    # Step 3: Prefetch each feed
    feeds_with_hashes = []
    for feed in feeds:
        if not feed.get("rev"):
            print(
                f"  Warning: feed '{feed['name']}' has no pinned commit, skipping",
                file=sys.stderr,
            )
            continue

        print(f"\n==> Prefetching feed: {feed['name']}...", file=sys.stderr)

        url = feed["url"]
        if "github.com/" in url:
            path = url.split("github.com/")[1].rstrip("/").replace(".git", "")
            owner, repo = path.split("/")[:2]
            info = prefetch_github(owner, repo, feed["rev"])
            feed["hash"] = info["hash"]
            feed["owner"] = owner
            feed["repo"] = repo
            feeds_with_hashes.append(feed)
        else:
            print(
                f"  Warning: non-GitHub feed '{feed['name']}', skipping",
                file=sys.stderr,
            )

    # Step 4: Try to fetch config.buildinfo hash
    print(
        f"\n==> Fetching config.buildinfo for {args.target}/{args.subtarget}...",
        file=sys.stderr,
    )
    config_url = f"https://downloads.openwrt.org/releases/{args.version}/targets/{args.target}/{args.subtarget}/config.buildinfo"

    config_hash = None
    try:
        config_hash = prefetch_url(config_url)
        print(f"  Success: {config_hash}", file=sys.stderr)
    except subprocess.CalledProcessError:
        print(
            f"  Warning: config.buildinfo not available (release may not exist yet)",
            file=sys.stderr,
        )

    # Generate Nix code
    print(f"\n{'='*70}", file=sys.stderr)
    print(f"Configuration generated successfully!", file=sys.stderr)
    print(f"{'='*70}", file=sys.stderr)
    print(f"\nAdd this to lib/devices.nix:\n", file=sys.stderr)

    nix_code = format_device_config_nix(
        args.device_name,
        args.version,
        openwrt_info,
        args.target,
        args.subtarget,
        profile,
        config_url,
        config_hash,
        feeds_with_hashes,
    )

    # Output to stdout so it can be redirected
    print(nix_code)

    print(f"\n{'='*70}", file=sys.stderr)
    print(f"Next steps:", file=sys.stderr)
    print(f"  1. Copy the output above into lib/devices.nix", file=sys.stderr)
    print(
        f"  2. Build the image: nix build .#packages.<system>.default",
        file=sys.stderr,
    )
    print(
        f"  3. Or reference it: nix-openwrt.lib.mkDevice {{ pkgs = ...; device = \"{args.device_name}\"; }}",
        file=sys.stderr,
    )


if __name__ == "__main__":
    main()
