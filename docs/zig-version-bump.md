# Bumping ZigVersion

`ZigVersion` (the [Vezel.Zig.Toolsets](https://github.com/vezel-dev/zig-toolsets)
package version) is pinned in three places that **must stay in sync**:

- `src/Crosscompile.targets`
- `src/AotAnywhere.nuproj`
- `src/Sdk/Sdk.props` (the default must be known during a consumer's very
  first restore, before the package's build targets are imported)

Zig has repeatedly changed behaviour relevant to this package between releases,
so every bump goes through the checklist below. Most of it is enforced
automatically — the notes say where.

## Checklist

- [ ] **All pins updated and in sync.** Update the `<ZigVersion>` default in
      *all three* files above. Renovate opens the bump PR (see
      [Automation](#automation)); confirm it touched all of them.

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
  opens a PR that bumps the `<ZigVersion>` value in all three files. The PR body
  carries this checklist.
- The **CI already covers most of the checklist** on any PR (`shim-tests`,
  `pack`, `build`, `validate`). The manual items are the ones a green run cannot
  prove: the win-arm64 codegen and `zig objcopy` re-checks, which only matter
  when deciding whether a bump lets us *remove* a workaround.
