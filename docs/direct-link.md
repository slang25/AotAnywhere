# Direct link

`src/DirectLink.targets` is the **only link flow for Linux targets**
(glibc and musl). The `/p:AotAnywhereDirectLink=false` escape hatch back
to the clang-shim flow — and with it the shim's Linux rewrite
(`processLinux`) and the `-shim` CI pseudo-targets — was retired once the
flows had proved equivalent; the clang personality now hard-errors if a
Linux link ever reaches it. macOS and Windows targets always use the
shim flows.

This document began as the prototype's design notes; the constraints and
findings below still describe how and why the flow works the way it does.

## What it does

The established flow lets the ILC SDK targets run their normal `LinkNative`
against a `clang` found on PATH, which is really the shim; the shim rewrites
the argument list and execs `zig cc`. The direct flow instead builds the
link command in MSBuild — from the same SDK-computed inputs — and runs
`zig cc` by absolute path. The division of labor:

- **SDK targets (unchanged, source of truth for _what_ to link):**
  `SetupOSSpecificProps` computes `$(NativeObject)`, `@(NativeLibrary)` and
  `@(LinkerArg)` — the runtime/framework static libs, system libs, hardening
  flags — exactly as before, including the `--target` triple injected by
  `OverwriteTargetTriple`.
- **`AotAnywhereDirectLinkNative` (new, owns _how_ it is linked):**
  replicates the command line the SDK's `LinkNative` would build for a
  non-Apple Unix target, applies the same zig fixups the clang shim applies
  at process-spawn time (drop `-lz`, `-pie -Wl,-pie`, the shared-library
  null entry point; add `-Wl,-u,__Module`), and `Exec`s
  `$(ZigPath)/zig cc ...` directly. The strip steps run the shim's objcopy
  personality by absolute path.

## Design constraints discovered

These shaped the implementation and are worth keeping in mind when deciding
whether to go further down this road:

- **`LinkNative` cannot be redefined by the package.** For real NuGet
  consumers our `.targets` are imported through the project-extensions hook
  at the top of `Microsoft.Common.targets`, while the SDK imports
  `Microsoft.NETCore.Native.targets` much later (`Microsoft.NET.Sdk.targets`,
  the `$(ILCompilerTargetsPath)` import). A later definition of a same-named
  target overrides an earlier one, so an override in our package would itself
  be overridden. Instead the new target runs `BeforeTargets="LinkNative"`
  with LinkNative's own `Inputs`/`Outputs`; once it has produced
  `$(NativeBinary)`, LinkNative's incremental check finds its output up to
  date and skips itself. (The test harness imports `src/` targets *after*
  `Sdk.targets` — the opposite order — so only order-independent mechanisms
  like this one behave the same in both.)
- **The shim is referenced by absolute path off Windows, by PATH on it.**
  `SetupOSSpecificProps` probes `command -v "$(CppLinker)"` (and the same for
  the objcopy symbol stripper; `where /Q` on Windows hosts) and errors when
  the tool is missing, before we ever run. `command -v` accepts an absolute
  path, so on non-Windows hosts `PointLinkerToShim` sets `CppLinker` (Linux
  and macOS targets) and `ObjCopyName` (Linux) to the materialized shim's
  absolute path and the probes resolve without the shim's directory on PATH.
  `where /Q` does **not**: it reads the drive-letter colon in an absolute
  path as its own `path:pattern` delimiter and fails with `Invalid pattern is
  specified in "path:pattern"`, so on Windows hosts the shim must be found by
  bare name with its directory prepended to PATH, as before. Eliminating the
  PATH prepend on Windows too would need a linker resolvable by a
  colon-free name — out of scope here. Windows *targets* are handled either
  way: win-cross already points `CppLinker` at the link shim by absolute path
  in `OverwriteTargetTriple` and runs no PATH probe, and a Windows host links
  win-* natively without importing the package.
- **The `-fuse-ld=lld` linker-version probe never fires for Linux.** The SDK
  defaults `LinkerFlavor` to `bfd` there, so `_LinkerVersion` stays unset and
  the SDK's `sections.ld` (`KEEP(*(__modules))`) path never applies; module
  retention rides on `-Wl,-u,__Module`, same as the shim flow.
- **Version drift lands in the drop list, not the structure.** net8 always
  adds `-lz` and spells the shared-library entry `-Wl,-e0x0`; net10 links the
  bundled `libz.a`/brotli instead and spells it `-Wl,-e,0x0`. Everything else
  (new static libs like `libaotminipal.a`, `libRuntime.Vxsort*`, zlib-ng,
  brotli) flowed through `@(LinkerArg)` with no change here — which is the
  argument for keeping the SDK as the source of truth.

## What was validated

From a macOS arm64 host: linux-x64 (net8 and net10), linux-arm64 and
linux-musl-x64 publishes; binaries executed in Docker (Debian for glibc,
Alpine for musl); stripped output with `.dbg` sidecar and `.gnu_debuglink`
identical in shape to the shim flow; `LinkNative` confirmed skipping via
binlog; incremental republish behaves like the shim flow. CI exercised the
direct flow from every host with execution on the ubuntu-x64 validate job;
the Windows-host leg (cmd.exe Exec quoting) passed on the first run. After
the default flip, every Linux target in the matrix (glibc/musl,
x64/arm64/armv7, net8/net9/net10) links via the direct flow; the `-shim`
pseudo-targets kept the escape hatch covered until both were retired.

Bake coverage beyond Hello World, in both flows for A/B parity:

- **Shared libraries** (`test/HelloLib`, `NativeLib=Shared`, net8): both
  flows produced byte-identical `.so` files (same build id), loaded and
  called via ctypes. This surfaced a pre-existing package bug — lld (16+)
  errors on version-script symbols that are not defined (`_init`/`_fini`
  from ILC's generated exports), where GNU ld tolerates them, so net8
  shared libraries never linked through zig at all. The direct flow adds
  `-Wl,--undefined-version` whenever a version script is used (the shim's
  Linux rewrite did too, until it was retired).
- **Non-trivial app** (`--selftest`, net10, no InvariantGlobalization):
  exercises real ICU (tr-TR casing), zlib (GZip roundtrip through the
  bundled zlib-ng) and OpenSSL (RSA sign/verify) at run time. Both flows
  pass in a `runtime-deps` container and on the ubuntu-x64 CI runner.

## Why bother / what this buys

- The full `zig cc` command line appears in build logs and binlogs —
  no argv rewriting hidden inside a shim process.
- The linker invocation is constructed from structured items instead of
  reverse-engineered from a generated command line.
- The link no longer depends on the clang personality of the shim at all
  (the objcopy personality is still used for the ELF strip, which zig
  cannot do).
- It is the stepping stone to invoking zig without any PATH/environment
  mutation. The `SetupOSSpecificProps` linker/objcopy probes are now
  satisfied by absolute path on non-Windows hosts (`PointLinkerToShim`), so
  the shim's PATH prepend is gone there; Windows hosts still prepend it
  (their `where /Q` probe cannot take an absolute path), and zig itself
  remains on PATH on every host, because the shim still execs `zig` by bare
  name.

## Not covered (future work, if the experiment earns it)

- macOS targets (Apple sysroot flags, pad file, swift overlay libs — all
  currently clang-shim logic) and Windows targets (the MSVC `link.rsp`
  translation, MinGW glue, `/MERGE` COFF renames — all link-shim logic).
- `NativeLib=Static` (the SDK uses `ar` via `CppLibCreator`; untouched —
  the direct-link target conditions itself out and the SDK flow applies).
- Removing the remaining PATH prepends: the zig one (the shim execs `zig` by
  bare name; giving it zig's absolute path — e.g. via an env channel or argv
  — would let `SetPathToZig` drop the prepend) on every host, and the shim
  one still needed on Windows hosts (whose `where /Q` probe rejects an
  absolute path). Plus the `AOTANYWHERE_APPLE_SYSROOT` process-environment
  channel.
- `StaticICULinking`/`StaticOpenSslLinking` invoke `build-local.sh` with
  `CC=$(CppLinker)`, now the shim's absolute path (`PointLinkerToShim`);
  they keep working because the shim forwards compile-only invocations
  straight to `zig cc` (the Linux hard-error applies to link invocations
  only).
