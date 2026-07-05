# AotAnywhere

This is a NuGet package with an MSBuild target to aid in crosscompilation with [PublishAot](https://learn.microsoft.com/en-us/dotnet/core/deploying/native-aot/). It helps resolving following error:

```sh
$ dotnet publish -r linux-x64
Microsoft.NETCore.Native.Publish.targets(59,5): error : Cross-OS native compilation is not supported.
```

This NuGet package allows using [Zig](https://ziglang.org/) as the linker/sysroot to allow crosscompiling to linux-x64/linux-arm64/linux-arm/linux-musl-x64/linux-musl-arm64/linux-musl-arm from Windows and macOS machines.

## Supported Host Platforms

- **Windows** (x86, x64)
- **macOS** (x64, arm64)  
- **Linux** (x64, arm64)

> Windows on ARM64 is not currently supported as a host: zig 0.16's aarch64-windows code generation produces a `clang` shim that crashes at startup, so cross-compilation can't run there. This will be revisited when a newer Zig fixes it.

## Supported Target Platforms

- **Linux** (x64, arm64, glibc, musl) - Full support from all host platforms
- **macOS** (x64, arm64) - Cross-compilation using Apple linker stubs bundled with the package (see below)

### macOS Cross-Compilation

No Apple SDK is available on Windows and Linux, so the package ships a minimal set of self-generated Apple linker stubs (`.tbd` files, under `build/apple-sysroot` in the package) covering exactly the symbols that .NET's runtime packs reference in CoreFoundation, Foundation, Security, GSS, Network, CryptoKit, the Swift runtime libraries, libobjc, libicucore and libz. This means the base class library works as it does in a native macOS build, including cryptography (CryptoKit/Security), HTTPS, and ICU globalization. Stubs only matter at link time; at run time the real system libraries on the target Mac are used.

Things to know:

- The stub symbol lists are generated from the .NET 8, 9, 10, and 11-preview runtime packs (`eng/generate-apple-sysroot.cs`). If a future .NET version references new Apple symbols, the link fails with an unresolved symbol until the stubs are regenerated.
- Symbols are not stripped for macOS targets (`StripSymbols` defaults to `false` there): Apple's `strip`/`dsymutil` are unavailable on other hosts and reject zig-linked binaries anyway.
- zig gives osx-arm64 binaries an ad-hoc code signature (Apple Silicon refuses to run entirely unsigned code); osx-x64 binaries are left unsigned. Either way that only covers running locally — for distribution you should sign (and if needed notarize) the result, which works from any host, no Mac required; see [Signing and notarizing macOS binaries](#signing-and-notarizing-macos-binaries) below.
- To link against a real Apple SDK instead of the bundled stubs, set the `AotAnywhereAppleSysroot` MSBuild property (or the `AOTANYWHERE_APPLE_SYSROOT` environment variable) to the SDK root.

### Signing and notarizing macOS binaries

Out of the box the binaries only run locally: zig ad-hoc signs osx-arm64 output (Apple Silicon requires at least that much) and leaves osx-x64 output unsigned. That is not enough to distribute: anything downloaded with a browser gets quarantined, and Gatekeeper only clears it when the binary is signed with a Developer ID certificate and notarized by Apple. Both steps can be done from any host — no Mac required.

#### Signing during publish

Export your "Developer ID Application" certificate and private key as a `.p12` file, put its password in a file, and pass both to publish:

```sh
dotnet publish -r osx-arm64 \
  /p:AotAnywhereSignP12File=certificate.p12 \
  /p:AotAnywhereSignP12PasswordFile=certificate.password.txt
```

The freshly linked binary is re-signed in place with the hardened-runtime flag and a secure timestamp, so it is ready for notarization. This uses [rcodesign](https://github.com/indygreg/apple-platform-rs) and works on Windows, Linux and macOS hosts alike — install it from the GitHub releases (or `cargo install apple-codesign`), or point `AotAnywhereRCodesignPath` at the executable if it is not on `PATH`.

On a macOS host you can use Apple's `codesign` with a keychain identity instead:

```sh
dotnet publish -r osx-arm64 "/p:AotAnywhereCodesignIdentity=Developer ID Application: Jane Doe (TEAMID)"
```

To embed entitlements with either flavor, set `/p:AotAnywhereEntitlements=path/to/entitlements.plist`.

Things to know:

- The password lives in a file rather than an MSBuild property so it does not end up in build logs or binlogs. In CI, store the `.p12` (base64-encoded) and its password as secrets and write them to files before publishing.
- If you create the `.p12` with OpenSSL 3+, pass `-legacy` (`openssl pkcs12 -export -legacy ...`). rcodesign cannot read OpenSSL 3's default PFX encryption and fails with "incorrect password given when decrypting PFX data". Exports from Keychain Access work as-is.
- Signing happens right after the native link. On an incremental publish where the binary is up to date, the link is skipped and the existing binary is re-signed with the current properties — but if you *remove* the signing properties, the previous signature stays until something triggers a relink. Publish clean (or `dotnet clean`) when changing signing configuration.

#### Notarizing

Notarization is a submission to Apple's notary service and needs an [App Store Connect API key](https://gregoryszorc.com/docs/apple-codesign/stable/apple_codesign_app_store_connect.html). Encode the key once:

```sh
rcodesign encode-app-store-connect-api-key -o api-key.json <issuer-id> <key-id> AuthKey_<key-id>.p8
```

Then either let the publish do everything — sign, zip, submit and wait for Apple's verdict:

```sh
dotnet publish -r osx-arm64 \
  /p:AotAnywhereSignP12File=certificate.p12 \
  /p:AotAnywhereSignP12PasswordFile=certificate.password.txt \
  /p:AotAnywhereNotarize=true \
  /p:AotAnywhereNotaryApiKeyFile=api-key.json
```

or run the submission yourself after a signed publish:

```sh
zip hello.zip Hello
rcodesign notary-submit --api-key-file api-key.json --wait hello.zip
```

`AotAnywhereNotarize` requires Developer ID signing in the same publish (Apple rejects ad-hoc submissions) and rcodesign, even when the signing itself was done with `AotAnywhereCodesignIdentity`. Submission typically takes a minute or two; the publish fails if Apple rejects the binary.

A bare executable cannot be stapled (stapling only works for bundles, disk images and installer packages), so just distribute the notarized binary — Gatekeeper fetches the notarization ticket online the first time it runs. If you ship a `.dmg` or `.pkg` instead, notarize that artifact and `rcodesign staple` it.

Note that only browser downloads get the quarantine attribute; binaries fetched by `curl`, CI tooling or package managers typically run without any of this.

## Usage

By default it relies on Zig provided by the unofficial [Vezel.Zig.Toolsets](https://github.com/vezel-dev/zig-toolsets) NuGet package. You can specify version of this package using the `ZigVersion` property. Instructions for using your own Zig binaries are near the end of this document.

1. To your project that is already using Native AOT, add a reference to the [`StuDev.AotAnywhere`](https://www.nuget.org/packages/StuDev.AotAnywhere) NuGet package:

    ```sh
    dotnet add package StuDev.AotAnywhere
    ```
2. Publish for one of the newly available RIDs:
    * `dotnet publish -r linux-x64`
    * `dotnet publish -r linux-arm64`
    * `dotnet publish -r linux-arm` (requires .NET 9+)
    * `dotnet publish -r linux-musl-x64`
    * `dotnet publish -r linux-musl-arm64`
    * `dotnet publish -r linux-musl-arm` (requires .NET 9+)

   The armv7 targets (`linux-arm`, `linux-musl-arm`) need a `net9.0` or later target framework: .NET only ships ILCompiler runtime packs for them from .NET 9 onwards.

No other tools are needed. That includes symbol stripping (`StripSymbols` defaults to `true` for Linux targets): the shim doubles as `llvm-objcopy` and performs the strip, the `.dbg` symbol sidecar and the `.gnu_debuglink` itself, so no LLVM install is required. The `.dbg` sidecar it produces is a full copy of the unstripped binary — larger than llvm-objcopy's, but debuggers consume it the same way via the debug link.

## Runtime Dependencies on Target Linux Systems

When running the cross-compiled binaries on Linux systems, you may encounter runtime dependency errors. Here are the most common issues and solutions:

### ICU Library Missing

If you see an error like:
```
Process terminated. Couldn't find a valid ICU package installed on the system. Please install libicu (or icu-libs) using your package manager and try again.
```

**Solution 1 (Recommended):** Install ICU on the target Linux system:
```bash
# Ubuntu/Debian
sudo apt-get install libicu-dev

# CentOS/RHEL/Fedora
sudo yum install libicu-devel
# or for newer versions:
sudo dnf install libicu-devel

# Alpine Linux
sudo apk add icu-libs
```

**Solution 2:** Build with invariant globalization (no ICU dependency):
```bash
dotnet publish -r linux-x64 /p:InvariantGlobalization=true
```

Note: Using invariant globalization disables culture-specific formatting, sorting, and other globalization features.

## Advanced Configuration

### The clang shim

Cross-compilation works by putting a small `clang` shim on `PATH` that rewrites the linker invocation and forwards it to `zig cc`. The package ships this shim **prebuilt** for the common host RIDs (Windows x86/x64, macOS x64/arm64, Linux x64/arm64) under `build/shim/<host-rid>`, so a normal build just copies it and does no compilation. On any other host the shim is compiled on demand from the bundled `clang_shim.zig` with the Zig toolchain. Pass `/p:UsePrebuiltClangShim=false` to force the compile-on-demand path.

The prebuilt shims are cross-compiled from a single machine at pack time (see `BuildClangShims` in `AotAnywhere.nuproj`); Zig makes producing all host binaries from one host trivial.

### Using your own Zig

If you don't want to use Zig from the Vezel.Zig.Toolsets NuGet package, you can specify `/p:UseExternalZig=true`. This will use whatever Zig is on your PATH. [Download](https://ziglang.org/download/) an archive with Zig for your host machine, extract it and place it on your PATH.


Even though Zig allows crosscompiling for Windows as well, it's not possible to crosscompile PublishAot like this due to ABI differences (MSVC vs. MingW ABI).

## Cross-Platform Validation

This repository includes a comprehensive GitHub Actions workflow that validates cross-compilation support across different host and target platforms. The workflow tests building from Windows and macOS hosts to all supported Linux targets (x64, ARM64, ARMv7, glibc, musl) and validates that the produced binaries run correctly (natively on hosted runners, or under QEMU in arm/v7 containers for the ARMv7 targets).

See [docs/cross-platform-validation.md](docs/cross-platform-validation.md) for detailed information about the validation process and platform support matrix.
