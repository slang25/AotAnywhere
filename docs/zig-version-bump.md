# Bumping ZigVersion

`ZigVersion` (the [Vezel.Zig.Toolsets](https://github.com/vezel-dev/zig-toolsets)
package version) has a **single source of truth**: the `<ZigVersion>` default in
`src/ZigVersion.props`. Everything else derives from it:

- `src/Crosscompile.targets` and `src/AotAnywhere.nuproj` `<Import>` it.
- `src/Sdk/Sdk.props` has it baked in at pack time (`BakeSdkProps` in the
  nuproj), because the default must be known during a consumer's very first
  restore — before the package's build targets are imported.

Two pins live outside MSBuild and cannot import the value, so they are checked
against `ZigVersion.props` by the `zig-version-sync` CI guard
(`eng/check-zig-version-sync.sh`) rather than kept in sync by hand:

- `.github/workflows/apple-sysroot-drift.yml` — pins `setup-zig` to the
  *upstream* form (the package version minus its packaging suffix, e.g.
  `0.16.0.2` → `0.16.0`).
- `.copilot-instructions.md` — mentions both forms in prose.

Zig has repeatedly changed behaviour relevant to this package between releases,
so every bump goes through the checklist below. Most of it is enforced
automatically — the notes say where.

## Checklist

- [ ] **The single pin is updated.** Change the `<ZigVersion>` default in
      `src/ZigVersion.props`. Renovate opens the bump PR (see
      [Automation](#automation)).

- [ ] **The out-of-band pins match.** Update the `setup-zig` version in
      `apple-sysroot-drift.yml` (upstream form) and the prose in
      `.copilot-instructions.md`.
      *Automated:* the `zig-version-sync` job fails the PR if either drifts from
      `ZigVersion.props`. Run `eng/check-zig-version-sync.sh` locally to check.

- [ ] **`zig test` the shims passes with the new toolchain.** The shim sources
      (`clang_shim.zig`, `objcopy_shim.zig`) must still compile and pass — zig's
      std APIs churn between releases.
      *Automated:* the `shim-tests` job in `cross-platform-validation.yml` runs
      `dotnet build -t:TestShims src/AotAnywhere.nuproj` on every PR. Run the
      same command locally to check before pushing.

- [ ] **Prebuilt shims rebuild for all host RIDs.** `BuildClangShims` in
      `AotAnywhere.nuproj` cross-compiles a shim for every host RID from one
      machine.
      *Automated:* the `pack` job builds the package (all host shims) on every
      PR.

- [ ] **Re-test the aarch64-windows codegen bug.** zig 0.16's aarch64-windows
      `build-exe` produces a shim that crashes at startup, so `win-arm64` is
      omitted as a host (`ShimTarget` in the nuproj, the CI matrix, and the
      README all leave it out). If a newer zig fixes it, re-add `win-arm64` to
      all three and confirm a cross-compiled shim runs on real arm64 Windows.

- [ ] **Re-check `zig objcopy` ELF-to-ELF support.** The bundled `objcopy_shim`
      exists because `zig objcopy` cannot strip ELF-to-ELF (issue #27). If a
      newer zig gains it, the shim may be simplifiable.

- [ ] **Full cross-platform validation matrix green.** The `build` and
      `validate` jobs in `cross-platform-validation.yml` exercise every host ×
      target combination and run the resulting binaries.
      *Automated:* runs on every PR.

## Automation

- **Renovate** (`renovate.json`) watches `Vezel.Zig.Toolsets.*` on nuget.org and
  opens a PR that bumps the `<ZigVersion>` value in `src/ZigVersion.props` (the
  single pin). The PR body carries this checklist.
- The **CI already covers most of the checklist** on any PR (`zig-version-sync`,
  `shim-tests`, `pack`, `build`, `validate`). The `zig-version-sync` guard
  catches the out-of-band pins Renovate does not touch. The manual items are the
  ones a green run cannot prove: the win-arm64 codegen and `zig objcopy`
  re-checks, which only matter when deciding whether a bump lets us *remove* a
  workaround.
