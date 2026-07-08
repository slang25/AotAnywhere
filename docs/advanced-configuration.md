# Advanced configuration

Internals and knobs most users never need. For everyday use see the
[Quick start](../README.md#quick-start) section of the README.

## The clang shim

The package materializes a small multi-call shim binary and puts it on `PATH`.
Its roles: materialized as `clang` it satisfies the ILC SDK's linker probes and
rewrites macOS link invocations to `zig cc` (Linux links never go through it —
they run zig directly from MSBuild, and the shim errors if one reaches it);
materialized as `llvm-objcopy` it performs the Linux symbol strip; materialized
as `link` it stands in for MSVC's linker when targeting Windows from a
non-Windows host. The package ships this shim **prebuilt** for the common host
RIDs (Windows x86/x64, macOS x64/arm64, Linux x64/arm64) under
`build/shim/<host-rid>`, so a normal build just copies it and does no
compilation. On any other host the shim is compiled on demand from the bundled
`clang_shim.zig` with the Zig toolchain. Pass `/p:UsePrebuiltClangShim=false` to
force the compile-on-demand path.

The prebuilt shims are cross-compiled from a single machine at pack time (see
`BuildClangShims` in `AotAnywhere.nuproj`); Zig makes producing all host
binaries from one host trivial.

## Direct zig linking for Linux targets

Linux targets are linked by invoking `zig cc` directly from MSBuild — the SDK
still computes everything that goes into the link, and the full zig command line
is visible in build logs and binlogs. This is the only Linux link flow: the
former `AotAnywhereDirectLink=false` escape hatch back to the clang shim was
retired after the flows proved equivalent (byte-identical output in our
shared-library tests). macOS and Windows targets always link through the shim
personalities. See [direct-link.md](direct-link.md) for the design.

## Using your own Zig

By default the package relies on Zig provided by the unofficial
[Vezel.Zig.Toolsets](https://github.com/vezel-dev/zig-toolsets) NuGet package.
You can select the version with the `ZigVersion` property.

If you don't want to use Zig from the Vezel.Zig.Toolsets NuGet package, you can
specify `/p:UseExternalZig=true`. This will use whatever Zig is on your PATH.
[Download](https://ziglang.org/download/) an archive with Zig for your host
machine, extract it and place it on your PATH.

> Maintainers: bumping the pinned `ZigVersion` follows the
> [ZigVersion bump checklist](zig-version-bump.md).
