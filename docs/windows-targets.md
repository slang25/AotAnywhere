# Windows targets

How AotAnywhere cross-compiles to `win-x64` / `win-arm64` from Linux and macOS
hosts.

On a Linux or macOS host, `dotnet publish -r win-x64` (or `win-arm64`) normally
stops at the `link.exe` step, since there is no MSVC. The package bridges that:
the shim also materializes as `link`, translates the MSVC-style response file
the ILC targets write, and drives `zig cc -target <arch>-windows-gnu`, which
links with lld against the MinGW-w64 (UCRT) import libraries zig bundles. The
MSVC-built NativeAOT runtime libraries link against the MinGW C runtime through
a small glue object the shim injects (MSVC `/GS` stack-cookie helpers,
MSVC-mangled `operator new`/`delete`, the arm64 `_Interlocked*` out-of-line
helpers, and a few marker symbols).

Things to know:

- The output imports the Universal CRT (`api-ms-win-crt-*`), exactly like an
  MSVC-linked NativeAOT binary, so it runs on any stock Windows 10+ system with
  no extra runtime.
- A `.pdb` is produced next to the binary and copied to the publish directory,
  as on Windows.
- `/MERGE` is honored — the shim renames the affected sections in copies of the
  input objects, which makes lld produce the same merged section layout as
  link.exe — and the `/GS` stack cookie is randomized at startup, mirroring
  MSVC's `__security_init_cookie`.
- Some MSVC hardening/link features are still not carried over: Control Flow
  Guard and CET shadow-stack markers (`/CETCOMPAT`) are not emitted, and
  identical-code folding (`/OPT:ICF`) is not performed, leaving the output
  somewhat larger than an MSVC link. For maximum-hardening release builds, link
  on Windows with MSVC.
- On a Windows host the package does nothing for `win-*` RIDs; the SDK's native
  MSVC link (including cross-arch win-x64 ↔ win-arm64 with the right VS
  components) applies.
