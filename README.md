# AotAnywhere

**Cross-compile [Native AOT](https://learn.microsoft.com/en-us/dotnet/core/deploying/native-aot/) .NET apps to Linux, macOS and Windows — from any of them.**

[PublishAot](https://learn.microsoft.com/en-us/dotnet/core/deploying/native-aot/)
normally refuses to build for another OS:

```sh
$ dotnet publish -r linux-x64
Microsoft.NETCore.Native.Publish.targets(59,5): error : Cross-OS native compilation is not supported.
```

AotAnywhere is a NuGet package that lifts that restriction. Add it to your
project and `dotnet publish -r <rid>` just works for Linux, macOS and Windows
RIDs, from a Windows, macOS or Linux machine. It uses [Zig](https://ziglang.org/)
as the linker and sysroot, and brings everything it needs with it — no extra
SDKs, cross toolchains or system packages to install on the build machine.

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/assets/platform-matrix-dark.svg">
    <img alt="Diagram: builds on Windows (x64, x86), macOS (arm64, x64) and Linux (x64, arm64) hosts, through AotAnywhere (dotnet publish -r <rid>), and runs on Linux glibc and musl (x64, arm64, arm), macOS (osx-arm64, osx-x64) and Windows (win-x64, win-arm64). Every combination is CI-tested: 5 hosts × 10 target RIDs." src="docs/assets/platform-matrix-light.svg" width="880">
  </picture>
</p>

## Quick start

1. In a project that already uses Native AOT, add an `Sdk` reference to
   [`StuDev.AotAnywhere`](https://www.nuget.org/packages/StuDev.AotAnywhere)
   inside the `<Project>` element:

   ```xml
   <Project Sdk="Microsoft.NET.Sdk">

     <Sdk Name="StuDev.AotAnywhere" Version="1.0.3" />
   ```

   (Or omit the `Version` and pin it once in `global.json` under
   [`msbuild-sdks`](https://learn.microsoft.com/en-us/visualstudio/msbuild/how-to-use-project-sdk#how-project-sdks-are-resolved).)

2. Publish for one of the newly available RIDs:

   ```sh
   dotnet publish -r linux-x64        # or linux-arm64, linux-arm*
   dotnet publish -r linux-musl-x64   # or linux-musl-arm64, linux-musl-arm*
   dotnet publish -r osx-x64          # or osx-arm64
   dotnet publish -r win-x64          # or win-arm64
   ```

That's it — no other tools required, including symbol stripping (the package
handles that itself, no LLVM install needed).

> **Why an `Sdk` reference and not a `PackageReference`?** The package pulls in
> its Zig linker toolchain through a second, host-specific NuGet package, and
> NuGet cannot restore package references declared inside a package's build
> targets ([NuGet/Home#4790](https://github.com/NuGet/Home/issues/4790)). SDK
> props *are* evaluated during restore, so the `Sdk` form fetches everything the
> first time with no further setup. A plain `PackageReference` still works if you
> restore Zig yourself — see [Advanced configuration](docs/advanced-configuration.md).

## Supported platforms

**Host machines** (where you run `dotnet publish`):

- **Windows** (x86, x64)
- **macOS** (x64, arm64)
- **Linux** (x64, arm64)

**Targets** (what you can publish for), from any supported host:

| Target | RIDs | Notes |
| --- | --- | --- |
| **Linux** | `linux-x64`, `linux-arm64`, `linux-arm`, `linux-musl-x64`, `linux-musl-arm64`, `linux-musl-arm` | glibc and musl. The `arm`/ARMv7 RIDs require a `net9.0`+ target framework. |
| **macOS** | `osx-x64`, `osx-arm64` | Links against bundled Apple linker stubs. See [macOS targets](docs/macos-targets.md). |
| **Windows** | `win-x64`, `win-arm64` | From Linux/macOS hosts, via zig's MinGW-w64 import libraries. On a Windows host the SDK links these natively with MSVC. See [Windows targets](docs/windows-targets.md). |

## Things to be aware of

- **ARMv7 needs .NET 9+.** The `linux-arm` and `linux-musl-arm` targets require a
  `net9.0` or later target framework — .NET only ships ILCompiler runtime packs
  for them from .NET 9 onwards.

- **macOS binaries need signing before you distribute them.** Out of the box the
  output only runs locally (osx-arm64 gets an ad-hoc signature, osx-x64 is
  unsigned). To hand it to other people you must sign it with a Developer ID
  certificate and notarize it — both doable from any host, no Mac required. See
  [Signing and notarizing](docs/macos-targets.md#signing-and-notarizing).

- **Windows output skips some MSVC hardening.** Control Flow Guard and CET
  markers (`/CETCOMPAT`) are not carried over. For maximum-hardening release
  builds, link on Windows with MSVC. Details in [Windows targets](docs/windows-targets.md).

- **Windows on ARM64 is not supported as a host.** zig 0.16's aarch64-windows
  code generation is broken, so Zig can't reliably run there. It will be
  revisited when a newer Zig fixes it. (win-arm64 as a *target* is fully
  supported.)

- **Linux ICU dependency.** A cross-compiled binary may need the ICU library on
  the target machine, the same as any globalization-enabled .NET app. See
  [Runtime dependencies on Linux](#runtime-dependencies-on-target-linux-systems)
  below.

## Runtime dependencies on target Linux systems

When running the cross-compiled binaries on Linux, you may hit a missing ICU
library:

```
Process terminated. Couldn't find a valid ICU package installed on the system. Please install libicu (or icu-libs) using your package manager and try again.
```

**Solution 1 (recommended):** install ICU on the target system:

```bash
# Ubuntu/Debian
sudo apt-get install libicu-dev

# CentOS/RHEL/Fedora
sudo yum install libicu-devel   # or: sudo dnf install libicu-devel

# Alpine Linux
sudo apk add icu-libs
```

**Solution 2:** build with invariant globalization (no ICU dependency):

```bash
dotnet publish -r linux-x64 /p:InvariantGlobalization=true
```

Note that invariant globalization disables culture-specific formatting, sorting,
and other globalization features.

## Documentation

- [macOS targets](docs/macos-targets.md) — Apple linker stubs, and signing &
  notarizing for distribution
- [Windows targets](docs/windows-targets.md) — how win-x64/win-arm64 cross-linking works
- [Advanced configuration](docs/advanced-configuration.md) — how linking works
  (MSBuild takeovers + managed tasks), and using your own Zig
- [Cross-platform validation](docs/cross-platform-validation.md) — the CI matrix
  that tests every host → target combination

## Credits

AotAnywhere began as a fork of Michal Strehovsky's
[PublishAotCross](https://github.com/MichalStrehovsky/PublishAotCross), which
first demonstrated that Zig could stand in as the linker and sysroot to make
Native AOT cross-compilation work. It has since been substantially rewritten —
the native shim is gone, links run directly through `zig cc` and managed MSBuild
tasks, and it ships bundled Apple sysroot stubs, symbol stripping, and a full
host × target CI matrix — but the original insight and inspiration are Michal's.
Thank you.

## License

MIT — see [LICENSE.TXT](LICENSE.TXT).
