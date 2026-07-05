#!/usr/bin/env bash
# Build and verify a group of AotAnywhere publish targets. Invoked by
# cross-platform-validation.yml, where the target groups run concurrently as
# parallel steps. Concurrent publishes share test/Hello.csproj, so each target
# publishes with its own BaseIntermediateOutputPath - a shared obj/ would race
# on project.assets.json.
#
# Usage: build-targets.sh <host-name> <target,target,...>

set -uo pipefail

host_name="$1"
IFS=',' read -ra TARGET_ARRAY <<< "$2"

# rcodesign is invoked by the SignMacOsBinary target for osx-x64
export PATH="$PWD/.rcodesign:$PATH"

# The target groups run concurrently (parallel steps in
# cross-platform-validation.yml), so up to three dotnet processes run at once on
# this host. Anything they share and write to races; give each invocation its
# own copy. The group id keys every per-invocation path below.
group_id="${host_name}-$(echo "$2" | tr ',' '_')"

# NuGet's global-packages folder (~/.nuget/packages) and HTTP cache are shared,
# and concurrent restores race extracting the same packages into them - notably
# the large Vezel zig toolset, which macOS re-extracts even when already present
# - producing "Directory not empty", missing-temp-file, and http-cache
# `.dat-new` errors. Serial pre-warming doesn't help (macOS still re-extracts),
# so isolate the folders per group instead: nothing shared, no collision.
# $RUNNER_TEMP is a native path on every host, so this is safe on Windows too,
# and the cache step archives the whole $RUNNER_TEMP/nuget tree.
nuget_root="${RUNNER_TEMP:-/tmp}/nuget/$group_id"
export NUGET_PACKAGES="$nuget_root/packages"
export NUGET_HTTP_CACHE_PATH="$nuget_root/http-cache"
mkdir -p "$NUGET_PACKAGES" "$NUGET_HTTP_CACHE_PATH"

# coreclr derives its shared-memory dir from $TMPDIR
# ($TMPDIR/.dotnet/shm/session<id>, keyed on the login session, not the PID), so
# the concurrent processes collide creating it and one fails with
# `mkdir(...session<id>) == -1; errno == EEXIST`. Give each invocation its own
# TMPDIR so the shm trees don't overlap. Skipped on Windows: it has no such shm
# path, and an MSYS-style TMPDIR wouldn't survive the bash -> dotnet boundary.
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) ;;
  *)
    TMPDIR="${RUNNER_TEMP:-/tmp}/dotnet-tmp/$group_id"
    mkdir -p "$TMPDIR"
    export TMPDIR
    ;;
esac

build_success=true

for target in "${TARGET_ARRAY[@]}"; do
  echo "=========================================="
  echo "Building for target: $target"
  echo "=========================================="

  # Create output directory
  mkdir -p "artifacts/$host_name/$target"

  # Per-target intermediate dir; RUNNER_TEMP is a native path on every host
  # (including Windows), which MSBuild accepts where an MSYS /d/... path
  # would not survive the bash -> dotnet boundary.
  obj_dir="$RUNNER_TEMP/aot-obj/$target/"

  # Determine if this is a cross-compilation or native build
  if [[ "$target" == linux-* ]]; then
    echo "Cross-compiling to Linux target using AotAnywhere..."
    # Deliberately no StripSymbols override: it defaults to true
    # for Linux targets and is served by the shim's llvm-objcopy
    # personality, so this exercises the strip pipeline on every
    # host x target combination.
    if dotnet publish test/Hello.csproj \
      -r "$target" \
      -c Release \
      -p:InvariantGlobalization=true \
      -p:BaseIntermediateOutputPath="$obj_dir" \
      --output "artifacts/$host_name/$target"; then

      echo "✅ Cross-compilation build succeeded for $target"
      build_result="success"
    else
      echo "❌ Cross-compilation build failed for $target"
      build_result="failed"
    fi
  elif [[ "$target" == osx-* ]]; then
    echo "Cross-compiling to macOS target using AotAnywhere..."
    # osx-x64 is signed with the throwaway CI certificate to
    # exercise the rcodesign signing integration from every host;
    # osx-arm64 is left with zig's default ad-hoc signature so that
    # path stays covered too.
    sign_args=()
    if [[ "$target" == "osx-x64" ]]; then
      p12="$PWD/test-cert/cert.p12"
      pass="$PWD/test-cert/cert.pass"
      if command -v cygpath >/dev/null 2>&1; then
        p12=$(cygpath -w "$p12")
        pass=$(cygpath -w "$pass")
      fi
      sign_args=(
        "-p:AotAnywhereSignP12File=$p12"
        "-p:AotAnywhereSignP12PasswordFile=$pass"
      )
    fi
    # For macOS targets, use AotAnywhere for cross-compilation
    if dotnet publish test/Hello.csproj \
      -r "$target" \
      -c Release \
      -p:StripSymbols=false \
      -p:InvariantGlobalization=true \
      -p:BaseIntermediateOutputPath="$obj_dir" \
      ${sign_args[@]+"${sign_args[@]}"} \
      --output "artifacts/$host_name/$target"; then

      echo "✅ Cross-compilation build succeeded for $target"
      build_result="success"
    else
      echo "❌ Cross-compilation build failed for $target"
      build_result="failed"
    fi
  else
    echo "❌ Unknown target platform: $target"
    build_result="failed"
  fi

  # Verify the binary was created (if build was successful)
  if [[ "$build_result" == "success" ]]; then
    binary_name="Hello"

    if [ -f "artifacts/$host_name/$target/$binary_name" ]; then
      echo "✅ Binary confirmed: $binary_name for $target"

      # Show file info
      ls -la "artifacts/$host_name/$target/$binary_name"

      # Show binary type if file command is available
      if command -v file >/dev/null 2>&1; then
        file "artifacts/$host_name/$target/$binary_name"
      fi

      # Try to get binary size
      size_kb=$(du -k "artifacts/$host_name/$target/$binary_name" | cut -f1)
      echo "Binary size: ${size_kb}KB"

      # Assert the strip pipeline ran for Linux targets: the
      # publish must produce the Hello.dbg symbol sidecar.
      if [[ "$target" == linux-* ]]; then
        if [ -f "artifacts/$host_name/$target/Hello.dbg" ]; then
          echo "✅ Symbol sidecar check: Hello.dbg present"
        else
          echo "❌ Symbol sidecar check: Hello.dbg missing (StripSymbols pipeline did not run)"
          build_success=false
        fi
      fi

      # Assert the signing integration actually signed osx-x64
      if [[ "$target" == "osx-x64" ]]; then
        if rcodesign print-signature-info "artifacts/$host_name/$target/$binary_name" | grep -q "AotAnywhere CI Test"; then
          echo "✅ Signature check: signed with the CI test certificate"
        else
          echo "❌ Signature check: expected CI test certificate signature not found"
          build_success=false
        fi
      fi

    else
      echo "❌ Binary not found after successful build: $binary_name for $target"
      echo "Contents of output directory:"
      ls -la "artifacts/$host_name/$target/" || echo "Output directory not found"
      build_success=false
    fi
  elif [[ "$build_result" == "failed" ]]; then
    build_success=false
  fi

  echo ""
done

if [ "$build_success" = false ]; then
  # Fail the step: the parallel group's other target groups still run to
  # completion, and artifact upload is if: always(), so partial results
  # still reach the validate/report jobs.
  echo "❌ One or more builds in this group failed"
  exit 1
fi

echo "🎉 All builds in this group completed successfully!"
