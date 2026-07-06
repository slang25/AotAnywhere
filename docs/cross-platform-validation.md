# Cross-Platform Validation Workflow

This repository includes a comprehensive GitHub Actions workflow (`cross-platform-validation.yml`) that validates cross-compilation support across different host and target platforms.

## What It Tests

### Host Platforms
- **Windows** (latest)
- **macOS x64** (macos-13)
- **macOS ARM64** (macos-latest)

### Target Platforms
- `linux-x64`
- `linux-arm64`
- `linux-arm` (armv7, published as `net9.0` — ILCompiler packs for armv7 only ship for .NET 9+)
- `linux-musl-x64`
- `linux-musl-arm64`
- `linux-musl-arm` (armv7, published as `net9.0`)
- `osx-x64`
- `osx-arm64`
- `win-x64`
- `win-arm64`

## Workflow Structure

### 1. Build Matrix
The workflow uses a matrix strategy to build from each host platform targeting all supported Linux platforms:

```yaml
strategy:
  matrix:
    include:
      - host: windows-latest
        host-name: windows
        targets: "linux-x64,linux-arm64,linux-arm,linux-musl-x64,linux-musl-arm64,linux-musl-arm,osx-x64,osx-arm64,win-x64,win-arm64"
      # ... same target list from ubuntu-latest, ubuntu-24.04-arm,
      # macos-15-intel and macos-latest hosts
```

Beyond the plain RIDs — which link Linux targets via the default direct zig
invocation — every host also publishes decorated `linux-x64` variants (see
`build-targets.sh`): `linux-x64-shim` (`AotAnywhereDirectLink=false`, the
escape hatch back to the clang-shim link flow), `lib-linux-x64[-shim]` (a
`NativeLib=Shared` library, loaded and called via python ctypes during
validation) and `linux-x64-selftest[-shim]` (a net10.0 build exercising real
ICU, zlib and OpenSSL at run time via `--selftest`). The `-shim`/plain pairs
give A/B parity between the two link flows until the shim flow is retired.

### 2. Build Process
For each host-target combination:
- Sets up .NET 8.0
- Installs Zig for cross-compilation
- Builds the NuGet package
- Compiles the test application for each target platform
- Validates binary creation and uploads artifacts

### 3. macOS Code Signing
A dedicated job generates a throwaway self-signed Developer ID-style certificate with rcodesign. Every build host then publishes `osx-x64` with the `AotAnywhereSignP12File` properties set, exercising the package's rcodesign signing integration from Windows, Linux and macOS hosts; `osx-arm64` keeps zig's default ad-hoc signature so that path stays covered. The build job asserts the expected certificate is present with `rcodesign print-signature-info`.

### 4. Runtime Validation
- Downloads build artifacts from all host platforms
- Tests x64 binaries on Ubuntu x64 and ARM64 binaries on Ubuntu ARM64 runners
- Tests ARMv7 binaries under QEMU on the x64 runner, inside `linux/arm/v7` containers (Debian for the glibc target, Alpine for musl) — there is no hosted armv7 runner, and the hosted arm64 runners dropped 32-bit execution
- Tests macOS binaries on appropriate macOS runners (x64 on macos-15-intel, ARM64 on macos-latest)
- Tests Windows binaries on Windows runners (win-x64 on windows-latest, win-arm64 on windows-11-arm); binaries from the Windows host are MSVC-linked, the rest are zig/MinGW-linked by the shim's link personality
- On macOS runners, verifies code signatures with `codesign --verify --strict` (and checks the `osx-x64` binaries carry the CI test certificate) before running
- Verifies "Hello World" output
- Reports success/failure rates

### 5. Package Consumption
The build matrix imports `src/StuDev.AotAnywhere.targets` directly, which hides how the package behaves when installed from a feed: NuGet does not restore package references declared inside a package's build targets, so a first-time consumer only gets Zig through the `Sdk/Sdk.props` entry point. The `package-consumption` job packs the real `.nupkg` into a local feed and publishes a consumer project from a clean NuGet cache (`.github/scripts/test-package-consumption.sh`), asserting that SDK-element consumption works zero-config, that a bare `PackageReference` fails with the actionable error, and that the documented `PackageReference` + explicit Zig toolset alternative works.

### 6. Platform Support Report
Generates a comprehensive report showing:
- Which host-target combinations work
- Binary sizes and architecture information
- Runtime validation results
- Success/failure matrix

## Running the Workflow

The workflow can be triggered by:
- Pull requests to `master`
- Pushes to `master`
- Manual dispatch via GitHub Actions UI

## Expected Results

The workflow validates that AotAnywhere successfully enables:
- Cross-compilation from Windows/Linux/macOS hosts to Linux, macOS and Windows targets
- Support for both glibc and musl targets on Linux
- Support for x64, ARM64 and ARMv7 architectures
- Functional binaries that run correctly on target platforms

## Limitations

- ARMv7 runtime testing happens under QEMU user emulation, not real hardware
- Network connectivity required for downloading Zig toolchain
- Build time varies significantly based on platform and target

## Artifacts

The workflow produces:
- **Binary artifacts**: Compiled binaries for each host-target combination
- **Platform support report**: Markdown report with detailed matrix results
- **Build logs**: Detailed compilation and validation logs