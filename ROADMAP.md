# AotAnywhere roadmap

A living list of rough edges and missing features worth exploring, grouped by
priority. Items marked **(spike)** are exploratory — the deliverable may be a
"no, because X" writeup rather than a shipped feature.

Status at time of writing: shipped 1.0.0 to nuget.org (2026-07-06). The core is
solid — there is no native shim any more: Linux and macOS links run directly
through `zig cc` from MSBuild, Windows links and the ELF strip run through a
single managed task assembly, and the SDK's linker probes are pointed at zig.
The rough edges are now mostly at the NuGet consumption model and version/drift
maintenance.

## Tier 1 — Rough edges that bite real users

1. **Kill the `<Sdk>`-vs-`<PackageReference>` awkwardness (spike).** Consumers
   must use an `Sdk` reference because `build/` PackageReferences aren't restored
   ([NuGet/Home#4790](https://github.com/NuGet/Home/issues/4790)). Spike a real
   nuspec `<dependency>` on `Vezel.Zig.Toolsets.<rid>` (RID-specific dependency
   groups) so a plain `PackageReference` "just works". Removes the single most
   confusing thing about adoption.
2. **Single source of truth for `ZigVersion`.** Pinned in three places
   (`src/Crosscompile.targets`, `src/Sdk/Sdk.props`, `.copilot-instructions.md`)
   that must stay in sync by hand. Make one authoritative, derive/verify the
   others, add a CI drift guard.
3. **Actionability audit of failure modes.** Walk the top failure paths (missing
   Apple symbol, dangling `$(ZigPath)` degrading to PATH zig, unsupported RID,
   missing zig) and make each fail fast with a copy-pasteable fix. Several
   already do; make it uniform.

## Tier 2 — Target output quality

4. **Windows hardening parity (spike → feature).** CFG, `/CETCOMPAT`, `/OPT:ICF`
   are dropped, so cross-linked Windows binaries are larger and less hardened
   than an MSVC link. Spike what lld / `zig cc` can express here; landing ICF-
   equivalent folding and CET markers would close the "link on Windows for
   release" caveat. See `docs/windows-targets.md`.
5. **macOS direct-link. ✅ Done.** macOS now links through the DirectLink
   MSBuild takeover (`AotAnywhereDirectLinkMacNative`) like Linux — Apple sysroot
   flags, GS pad and Swift overlay libs are reconstructed as MSBuild items, the
   full command line is in binlogs, and the clang shim is gone. This, plus the
   Windows link task and the managed ELF strip, retired the native shim entirely.
5b. **Demote ILC's external symbols on macOS for net8/net9 (spike).** Issue #62's
   dominant cost (local symbols + stabs) is fixed by link-time `-Wl,-x -Wl,-S`,
   but symbols older ILCs emit as true externals survive: zig's linker ignores
   `-exported_symbols_list` (and rejects `-(un)exported_symbol`), which is how
   the standard pipeline demotes them before `strip -x`. net10+ marks them
   hidden so output is near-parity; net8 keeps ~14k externals (~1 MB of mangled
   names in `__LINKEDIT` for the Hello app). Spike: pre-link nlist surgery on
   the ILC object (set `N_PEXT` on non-exported externals — zig then emits them
   as locals and `-x` drops them; no re-sign needed since the surgery is on the
   relocatable input, not the signed output). Keep-list: `ExportsFile` entries
   plus `_main`.

## Tier 3 — Architecture / tech debt

6. **Zero PATH mutation.** Only the Windows-host zig-dir prepend remains (because
   `where /Q` rejects a drive-lettered absolute path). Spike a colon-free linker
   name so zig resolves by bare name without a prepend, then collapse the
   `AOTANYWHERE_ZIG` / `AOTANYWHERE_APPLE_SYSROOT` env channels. Finishes the
   arc that's ~90% done. **Spiked & resolved:** see `docs/zero-path-mutation.md`.
   A Windows-runner experiment proved `where /Q` accepts no colon-free path with
   a directory component (drive-relative, project-relative, forward-slash and
   `dir:pattern` all fail), so the prepend is irreducible without an upstream SDK
   hook (folds into #7). The `AOTANYWHERE_ZIG` / `AOTANYWHERE_APPLE_SYSROOT` env
   channels are since **gone** (the shim that read them was removed), so nothing
   but the one Windows-host prepend remains. This item is closed as
   "no, because `where /Q`".
7. **Upstream dotnet/runtime ask (exploratory).** The DirectLink takeovers and
   the zig-pointed probe exist because ILC's linker probes are unskippable and
   there's no hook to override the link invocation. The native shim is gone, but
   the one residue — the Windows-host `PATH` prepend — needs an upstream hook to
   remove. Draft the extension-point proposal / issue. Long shot, but the only
   path that makes the last workaround obsolete.

## Tier 4 — Reach / new capabilities

8. **Re-enable win-arm64 as a host (blocked, tracked).** Blocked on zig 0.16's
   broken aarch64-windows self-hosted codegen. Now that links go through
   `zig cc` (the LLVM backend) rather than a `zig build-exe`-compiled shim, an
   arm64-Windows *host* may already work — standing item: on each `ZigVersion`
   bump (or given an arm64-Windows machine), test publishing from it.
9. **New target RIDs (spike).** Zig can target things .NET partially supports —
   `linux-bionic` (Android), FreeBSD. Spike whether any are reachable with the
   existing sysroot machinery.

## Tier 5 — Maintenance & DX

10. **Automate Apple sysroot drift.** `apple-sysroot-drift.yml` already detects
    drift; close the loop so a new .NET preview referencing new Apple symbols
    opens a PR (or clearly instructs regeneration) rather than surfacing as a
    link failure. See `docs/macos-targets.md`.
11. **CI cost review.** `cross-platform-validation.yml` (~32K of YAML, QEMU
    armv7, multi-host) is thorough but expensive. Decide what runs per-PR vs.
    nightly/pre-release to keep PR latency and Actions spend sane.
12. **Ecosystem: a real sample + docs surface.** Build on `slang25/aotanywhere-demo`
    with a "ship a CLI tool to 8 RIDs from one GitHub Action" showcase — likely
    does more for adoption than any single feature.

## Suggested ordering

**#1 first** (adoption friction). **#5 and #6 are now closed** — macOS is on the
DirectLink takeover and the native shim is gone entirely; the zero-mutation arc
is as complete as the SDK's `where /Q` probe allows (see
`docs/zero-path-mutation.md`), its only remaining route folding into **#7**. That
leaves **#4** (Windows hardening parity) as the meaty target-quality work, with
**#7 and #9** as background spikes.
