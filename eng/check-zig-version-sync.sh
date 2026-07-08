#!/usr/bin/env bash
#
# ZigVersion drift guard.
#
# src/ZigVersion.props is the single source of truth for the pinned Zig
# toolchain version. The MSBuild files derive from it (Crosscompile.targets and
# AotAnywhere.nuproj <Import> it; Sdk/Sdk.props bakes it in at pack time), so
# they cannot drift. Two pins live outside MSBuild and cannot import it:
#
#   - .github/workflows/apple-sysroot-drift.yml  (upstream form, e.g. 0.16.0)
#   - .copilot-instructions.md                   (prose: package + upstream form)
#
# This script checks those against the authoritative value and fails on drift.
# It also guards against a version literal creeping back into the MSBuild files.
#
# Run locally or in CI: eng/check-zig-version-sync.sh
set -euo pipefail

cd "$(dirname "$0")/.."

fail() { echo "ZigVersion drift: $*" >&2; exit 1; }

# --- Authoritative value ---------------------------------------------------
# The Vezel.Zig.Toolsets package version, e.g. 0.16.0.2.
pkg_version="$(sed -n 's/.*<ZigVersion[^>]*>\([0-9][0-9.]*\)<\/ZigVersion>.*/\1/p' src/ZigVersion.props | head -n1)"
[ -n "$pkg_version" ] || fail "could not read <ZigVersion> from src/ZigVersion.props"

# Upstream zig release = package version minus the trailing packaging suffix,
# e.g. 0.16.0.2 -> 0.16.0.
upstream_version="${pkg_version%.*}"

echo "Authoritative ZigVersion (src/ZigVersion.props): $pkg_version (upstream $upstream_version)"

# --- apple-sysroot-drift.yml ----------------------------------------------
drift_yml=".github/workflows/apple-sysroot-drift.yml"
if ! grep -Eq "version:[[:space:]]*${upstream_version}([[:space:]]|\$|'|\")" "$drift_yml"; then
  fail "$drift_yml does not pin setup-zig to upstream $upstream_version (expected 'version: $upstream_version')"
fi

# --- .copilot-instructions.md ---------------------------------------------
copilot=".copilot-instructions.md"
grep -qF "$pkg_version" "$copilot" \
  || fail "$copilot does not mention the package version $pkg_version"
grep -qF "Zig $upstream_version" "$copilot" \
  || fail "$copilot does not mention upstream 'Zig $upstream_version'"

# --- Guard against a literal creeping back into the MSBuild files ----------
# These must derive from ZigVersion.props, never hardcode a version.
for f in src/Crosscompile.targets src/AotAnywhere.nuproj src/Sdk/Sdk.props; do
  if grep -Eq "<ZigVersion[^>]*>[0-9]" "$f"; then
    fail "$f hardcodes a <ZigVersion> literal; it must derive from src/ZigVersion.props"
  fi
done

echo "ZigVersion is in sync across all pins."
