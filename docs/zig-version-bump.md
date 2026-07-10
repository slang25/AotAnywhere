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

- [ ] **`win-arm64` host is still not viable — re-evaluate.** `win-arm64` is a
      supported *target* (cross-compiled from other hosts), but it is left out of
      the CI *host* matrix and the README because zig 0.16's aarch64-windows
      self-hosted code generation is broken. That originally broke building the
      native shim; the shim is gone now, and links go through `zig cc` (the LLVM
      backend), so an arm64-Windows *host* may now work. If you have access to
      one, test publishing from it; if it works, add it as a host.

- [ ] **Full cross-platform validation matrix green.** The `build` and
      `validate` jobs in `cross-platform-validation.yml` exercise every host ×
      target combination and run the resulting binaries.
      *Automated:* runs on every PR.

- [ ] **The Windows /OPT re-link still works.** The Windows link's second pass
      (`AotAnywhereWindowsLink.RelinkWithOptFlags`) leans on three undocumented
      zig behaviours: `zig cc -v` printing the `lld-link ...` argv line, the
      `zig lld-link` subcommand re-execing the bundled LLD COFF driver, and zig
      echoing the paths it was given verbatim (the spaced-path symlink aliasing
      in `LinkPathAliaser` depends on zig not realpath-ing them). If a bump
      changes any of these, the task fails the link with an "AotAnywhere:
      cannot replay the lld-link invocation" error - there is deliberately no
      fallback.
      *Automated:* any Windows-target job in the validation matrix goes red on
      that error.

## Automation

- **Renovate** (`renovate.json`) watches `Vezel.Zig.Toolsets.*` on nuget.org and
  opens a PR that bumps the `<ZigVersion>` value in `src/ZigVersion.props` (the
  single pin). The PR body carries this checklist.
- The **CI already covers most of the checklist** on any PR (`zig-version-sync`,
  `msbuild-logic-tests`, `build`, `validate`). The `build`/`validate` matrix runs
  a real `zig cc` link for every host × target and executes the resulting
  binaries, so any zig behaviour change that affects a link surfaces there. The
  `zig-version-sync` guard catches the out-of-band pins Renovate does not touch.
  The one manual item is the `win-arm64` host re-evaluation, which a green run
  cannot prove because no arm64-Windows host is in the matrix.
