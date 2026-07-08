# AotAnywhere roadmap

A living list of rough edges and missing features worth exploring, grouped by
priority. Items marked **(spike)** are exploratory — the deliverable may be a
"no, because X" writeup rather than a shipped feature.

Status at time of writing: shipped 1.0.0 to nuget.org (2026-07-06). The core is
solid — Linux links run directly through `zig cc` from MSBuild; Windows/macOS go
through the multi-call shim. The rough edges are mostly at the seams: the shim
personalities, the NuGet consumption model, and version/drift maintenance.

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
5. **macOS direct-link (spike).** macOS still runs entirely through the clang
   shim (Apple sysroot flags, GS pad, Swift overlay libs). Extending the
   DirectLink approach to macOS gets the full command line into binlogs and
   shrinks the shim's remaining surface — flagged as the next candidate in
   `docs/direct-link.md`.

## Tier 3 — Architecture / tech debt

6. **Zero PATH mutation.** Only the Windows-host shim prepend remains (because
   `where /Q` rejects a drive-lettered absolute path). Spike a colon-free linker
   name so the shim resolves by bare name without a prepend, then collapse the
   `AOTANYWHERE_ZIG` / `AOTANYWHERE_APPLE_SYSROOT` env channels. Finishes the
   arc that's ~90% done. **Spiked & resolved:** see `docs/zero-path-mutation.md`.
   A Windows-runner experiment proved `where /Q` accepts no colon-free path with
   a directory component (drive-relative, project-relative, forward-slash and
   `dir:pattern` all fail), so the prepend is irreducible without an upstream SDK
   hook (folds into #7). The env-channel collapse is feasible via `LinkerArg` but
   does not touch PATH, so it is deferred as marginal. This item is closed as
   "no, because `where /Q`".
7. **Upstream dotnet/runtime ask (exploratory).** The shim exists because ILC's
   linker probes are unskippable and there's no hook to override the link
   invocation. Draft the extension-point proposal / issue. Long shot, but the
   only path that makes the entire hack obsolete.

## Tier 4 — Reach / new capabilities

8. **Re-enable win-arm64 as a host (blocked, tracked).** Blocked on zig 0.16's
   broken aarch64-windows codegen. Standing item: re-test on each `ZigVersion`
   bump — both the `build-exe` crash and a cross-built binary actually running.
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

**#2 and #1 first** (adoption friction). **#6 is now closed** — the zero-mutation
arc is as complete as the SDK's `where /Q` probe allows (see
`docs/zero-path-mutation.md`); its only remaining route folds into **#7**. That
leaves **#4 / #5** as the meaty target-quality work, with **#7 and #9** as
background spikes.
