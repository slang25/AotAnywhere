#!/usr/bin/env bash
# Prove StuDev.AotAnywhere works when consumed as a real NuGet package from a
# CLEAN NuGet cache — the path the rest of CI cannot see: test/Hello.csproj
# imports src/StuDev.AotAnywhere.targets directly, which makes the Zig toolset
# reference a first-class project reference. A real consumer gets that
# reference from inside the installed package's build/ targets, which NuGet
# restore does not evaluate (NuGet/Home#4790), and that difference is exactly
# what broke first-time consumers before Sdk/Sdk.props existed.
#
# Cases:
#   sdk        - <Sdk Name="StuDev.AotAnywhere"/> element: must work zero-config
#   bare       - plain PackageReference only: must fail with the actionable
#                AotAnywhere error (not the shim's bare "zig is not on the PATH")
#   workaround - PackageReference + explicit host Zig toolset: must work
#                (the documented alternative for PackageReference consumers)
#
# Usage: test-package-consumption.sh [host-rid]   (default: from dotnet --info)

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
host_rid="${1:-$(dotnet --info | sed -n 's/^ *RID: *//p' | head -1)}"
[ -n "$host_rid" ] || { echo "could not determine host RID"; exit 1; }

work="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/aotanywhere-consumption"
rm -rf "$work"
mkdir -p "$work/feed"

version="0.0.1-ci"
zig_version=$(sed -n "s/.*<ZigVersion[^>]*>\([^<]*\)<\/ZigVersion>.*/\1/p" "$repo_root/src/Crosscompile.targets" | head -1)

echo "==> Packing StuDev.AotAnywhere $version (host: $host_rid, zig: $zig_version)"
dotnet build -t:Pack "$repo_root/src/AotAnywhere.nuproj" -p:Version="$version"
nupkg=$(find "$repo_root/src/bin" -name "StuDev.AotAnywhere.$version.nupkg" | head -1)
[ -n "$nupkg" ] || { echo "packed nupkg not found"; exit 1; }
cp "$nupkg" "$work/feed/"

# Scaffold a consumer per case. Each gets its own directory (own obj/) and its
# own empty NUGET_PACKAGES, so nothing pre-restored can leak in.
scaffold() {
  local dir="$1" csproj_body="$2"
  mkdir -p "$dir"
  cat > "$dir/nuget.config" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <packageSources>
    <clear />
    <add key="local" value="$work/feed" />
    <add key="nuget.org" value="https://api.nuget.org/v3/index.json" />
  </packageSources>
</configuration>
EOF
  cat > "$dir/Program.cs" <<'EOF'
System.Console.WriteLine($"Hello from {System.Runtime.InteropServices.RuntimeInformation.RuntimeIdentifier}");
EOF
  cat > "$dir/Consumer.csproj" <<EOF
<Project Sdk="Microsoft.NET.Sdk">
$csproj_body
  <PropertyGroup>
    <OutputType>Exe</OutputType>
    <TargetFramework>net8.0</TargetFramework>
    <PublishAot>true</PublishAot>
    <InvariantGlobalization>true</InvariantGlobalization>
  </PropertyGroup>
</Project>
EOF
}

publish() {
  local dir="$1" rid="$2" log="$3"
  NUGET_PACKAGES="$dir/nuget-cache" dotnet publish "$dir/Consumer.csproj" \
    -r "$rid" -c Release -o "$dir/out/$rid" 2>&1 | tee "$log"
}

failures=0

echo
echo "==> Case: SDK element (must cross-compile from a clean cache, zero config)"
scaffold "$work/sdk" "  <Sdk Name=\"StuDev.AotAnywhere\" Version=\"$version\" />"
for rid in linux-arm64 win-x64; do
  bin="$work/sdk/out/$rid/Consumer"
  [ "$rid" = win-x64 ] && bin="$bin.exe"
  if publish "$work/sdk" "$rid" "$work/sdk-$rid.log" && [ -f "$bin" ]; then
    echo "✅ sdk: $rid produced $(basename "$bin")"
  else
    echo "❌ sdk: $rid failed or produced no binary"
    failures=$((failures + 1))
  fi
done

echo
echo "==> Case: bare PackageReference (must fail with the actionable error)"
scaffold "$work/bare" "  <ItemGroup>
    <PackageReference Include=\"StuDev.AotAnywhere\" Version=\"$version\" PrivateAssets=\"all\" />
  </ItemGroup>"
if publish "$work/bare" linux-arm64 "$work/bare.log"; then
  echo "❌ bare: expected the publish to fail on a clean cache, but it succeeded"
  failures=$((failures + 1))
elif grep -q "AotAnywhere: the Zig toolset" "$work/bare.log"; then
  echo "✅ bare: failed with the actionable AotAnywhere error"
else
  echo "❌ bare: failed, but without the actionable AotAnywhere error"
  failures=$((failures + 1))
fi

echo
echo "==> Case: PackageReference + explicit Zig toolset (documented alternative)"
scaffold "$work/workaround" "  <ItemGroup>
    <PackageReference Include=\"StuDev.AotAnywhere\" Version=\"$version\" PrivateAssets=\"all\" />
    <PackageReference Include=\"Vezel.Zig.Toolsets.$host_rid\" Version=\"$zig_version\" PrivateAssets=\"all\" GeneratePathProperty=\"true\" />
  </ItemGroup>"
if publish "$work/workaround" linux-arm64 "$work/workaround.log" && [ -f "$work/workaround/out/linux-arm64/Consumer" ]; then
  echo "✅ workaround: linux-arm64 produced Consumer"
else
  echo "❌ workaround: failed or produced no binary"
  failures=$((failures + 1))
fi

echo
if [ "$failures" -gt 0 ]; then
  echo "❌ $failures consumption case(s) failed"
  exit 1
fi
echo "✅ all package consumption cases passed"
