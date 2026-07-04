# PublishAotCross

This is a NuGet package with an MSBuild target to aid in crosscompilation with [PublishAot](https://learn.microsoft.com/en-us/dotnet/core/deploying/native-aot/). It helps resolving following error:

```sh
$ dotnet publish -r linux-x64
Microsoft.NETCore.Native.Publish.targets(59,5): error : Cross-OS native compilation is not supported.
```

This NuGet package allows using [Zig](https://ziglang.org/) as the linker/sysroot to allow crosscompiling to linux-x64/linux-arm64/linux-musl-x64/linux-musl-arm64 from Windows and macOS machines.

## Supported Host Platforms

- **Windows** (x86, x64, arm64)
- **macOS** (x64, arm64)  
- **Linux** (x64, arm64)

## Supported Target Platforms

- **Linux** (x64, arm64, glibc, musl) - Full support from all host platforms
- **macOS** (x64, arm64) - Cross-compilation using Apple linker stubs bundled with the package (see below)

### macOS Cross-Compilation

No Apple SDK is available on Windows and Linux, so the package ships a minimal set of self-generated Apple linker stubs (`.tbd` files, under `build/apple-sysroot` in the package) covering exactly the symbols that .NET's runtime packs reference in CoreFoundation, Foundation, Security, GSS, Network, CryptoKit, the Swift runtime libraries, libobjc, libicucore and libz. This means the base class library works as it does in a native macOS build, including cryptography (CryptoKit/Security), HTTPS, and ICU globalization. Stubs only matter at link time; at run time the real system libraries on the target Mac are used.

Things to know:

- The stub symbol lists are generated from the .NET 8, 9, 10, and 11-preview runtime packs (`eng/generate-apple-sysroot.py`). If a future .NET version references new Apple symbols, the link fails with an unresolved symbol until the stubs are regenerated.
- Symbols are not stripped for macOS targets (`StripSymbols` defaults to `false` there): Apple's `strip`/`dsymutil` are unavailable on other hosts and reject zig-linked binaries anyway.
- zig gives the binary an ad-hoc code signature. That runs fine locally, but for distribution you should sign (and if needed notarize) the result on a Mac: `codesign --force --sign <identity> <binary>`.
- To link against a real Apple SDK instead of the bundled stubs, set the `PublishAotCrossAppleSysroot` MSBuild property (or the `PUBLISHAOTCROSS_APPLE_SYSROOT` environment variable) to the SDK root.

## Usage

By default it relies on Zig provided by the unofficial [Vezel.Zig.Toolsets](https://github.com/vezel-dev/zig-toolsets) NuGet package. You can specify version of this package using the `ZigVersion` property. Instructions for using your own Zig binaries are near the end of this document.

1. Optional: [download](https://releases.llvm.org/) LLVM. We only need llvm-objcopy executable so if you care about size, you can delete the rest. The executable needs to be on PATH. This step is optional and is required only to strip symbols (make the produced executables smaller). If you don't care about stripping symbols, you can skip it.
2. To your project that is already using Native AOT, add a reference to this NuGet package.
3. Publish for one of the newly available RIDs:
    * `dotnet publish -r linux-x64`
    * `dotnet publish -r linux-arm64`
    * `dotnet publish -r linux-musl-x64`
    * `dotnet publish -r linux-musl-arm64`

    If you skipped the second optional step to download llvm-objcopy, you must also pass `/p:StripSymbols=false` to the publish command, or you'll see an error instructing you to do that.

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

If you don't want to use Zig from the Vezel.Zig.Toolsets NuGet package, you can specify `/p:UseExternalZig=true`. This will use whatever Zig is on your PATH. [Download](https://ziglang.org/download/) an archive with Zig for your host machine, extract it and place it on your PATH.


Even though Zig allows crosscompiling for Windows as well, it's not possible to crosscompile PublishAot like this due to ABI differences (MSVC vs. MingW ABI).

## Cross-Platform Validation

This repository includes a comprehensive GitHub Actions workflow that validates cross-compilation support across different host and target platforms. The workflow tests building from Windows and macOS hosts to all supported Linux targets (x64, ARM64, glibc, musl) and validates that the produced binaries run correctly.

See [docs/cross-platform-validation.md](docs/cross-platform-validation.md) for detailed information about the validation process and platform support matrix.
