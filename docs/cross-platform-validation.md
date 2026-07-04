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
- `linux-musl-x64`
- `linux-musl-arm64`
- `osx-x64`
- `osx-arm64`

## Workflow Structure

### 1. Build Matrix
The workflow uses a matrix strategy to build from each host platform targeting all supported Linux platforms:

```yaml
strategy:
  matrix:
    include:
      - host: windows-latest
        host-name: windows
        targets: "linux-x64,linux-arm64,linux-musl-x64,linux-musl-arm64,osx-x64,osx-arm64"
      - host: macos-13
        host-name: macos-x64
        targets: "linux-x64,linux-arm64,linux-musl-x64,linux-musl-arm64,osx-x64,osx-arm64"
      - host: macos-latest
        host-name: macos-arm64
        targets: "linux-x64,linux-arm64,linux-musl-x64,linux-musl-arm64,osx-x64,osx-arm64"
```

### 2. Build Process
For each host-target combination:
- Sets up .NET 8.0
- Installs Zig for cross-compilation
- Builds the NuGet package
- Compiles the test application for each target platform
- Validates binary creation and uploads artifacts

### 3. macOS Code Signing
A dedicated job generates a throwaway self-signed Developer ID-style certificate with rcodesign. Every build host then publishes `osx-x64` with the `PublishAotCrossSignP12File` properties set, exercising the package's rcodesign signing integration from Windows, Linux and macOS hosts; `osx-arm64` keeps zig's default ad-hoc signature so that path stays covered. The build job asserts the expected certificate is present with `rcodesign print-signature-info`.

### 4. Runtime Validation
- Downloads build artifacts from all host platforms
- Tests x64 binaries on Ubuntu (can't test ARM64 on x64 runners)
- Tests macOS binaries on appropriate macOS runners (x64 on macos-13, ARM64 on macos-latest)
- On macOS runners, verifies code signatures with `codesign --verify --strict` (and checks the `osx-x64` binaries carry the CI test certificate) before running
- Verifies "Hello World" output
- Reports success/failure rates

### 5. Platform Support Report
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

The workflow validates that PublishAotCross successfully enables:
- Cross-compilation from Windows/macOS to Linux and macOS
- Support for both glibc and musl targets on Linux
- Support for both x64 and ARM64 architectures
- Functional binaries that run correctly on target platforms

## Limitations

- ARM64 binaries cannot be runtime-tested on x64 GitHub runners
- Cross-architecture testing (e.g., ARM64 binaries on x64 runners) is not supported
- Network connectivity required for downloading Zig toolchain
- Build time varies significantly based on platform and target

## Artifacts

The workflow produces:
- **Binary artifacts**: Compiled binaries for each host-target combination
- **Platform support report**: Markdown report with detailed matrix results
- **Build logs**: Detailed compilation and validation logs