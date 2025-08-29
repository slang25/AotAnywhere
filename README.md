# PublishAotCross

This is a NuGet package with an MSBuild target to aid in crosscompilation with [PublishAot](https://learn.microsoft.com/en-us/dotnet/core/deploying/native-aot/). It helps resolving following error:

```sh
$ dotnet publish -r linux-x64
Microsoft.NETCore.Native.Publish.targets(59,5): error : Cross-OS native compilation is not supported.
```

This NuGet package allows using [Zig](https://ziglang.org/) as the linker/sysroot to allow crosscompiling to linux-x64/linux-arm64/linux-musl-x64/linux-musl-arm64 from Windows and macOS machines, and to win-x64/win-x86/win-arm64 from macOS and Linux machines.

## Supported Host Platforms

- **Windows** (x86, x64, arm64) - can target Linux
- **macOS** (x64, arm64) - can target Linux and Windows
- **Linux** (x64, arm64) - can target Windows

## Usage

By default it relies on Zig provided by the unofficial [Vezel.Zig.Toolsets](https://github.com/vezel-dev/zig-toolsets) NuGet package. You can specify version of this package using the `ZigVersion` property. Instructions for using your own Zig binaries are near the end of this document.

1. Optional: [download](https://releases.llvm.org/) LLVM. We only need llvm-objcopy executable so if you care about size, you can delete the rest. The executable needs to be on PATH. This step is optional and is required only to strip symbols (make the produced executables smaller). If you don't care about stripping symbols, you can skip it.
2. To your project that is already using Native AOT, add a reference to this NuGet package.
3. Publish for one of the newly available RIDs:
    * `dotnet publish -r linux-x64`
    * `dotnet publish -r linux-arm64`
    * `dotnet publish -r linux-musl-x64`
    * `dotnet publish -r linux-musl-arm64`
    * `dotnet publish -r win-x64` (from macOS/Linux hosts)
    * `dotnet publish -r win-x86` (from macOS/Linux hosts)
    * `dotnet publish -r win-arm64` (from macOS/Linux hosts)
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

### Windows Target ABI Notes

When targeting Windows from macOS/Linux hosts, this package uses the GNU ABI (MinGW) rather than the MSVC ABI. This means:
- Generated executables will depend on the MinGW runtime rather than the MSVC runtime
- For maximum compatibility, you may want to link statically or bundle the required MinGW runtime libraries
- Some Windows-specific .NET features that rely on MSVC-specific behavior may not work identically
