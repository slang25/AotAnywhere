# Zero PATH mutation (spike)

This is the design writeup for ROADMAP item #6. It records where the
environment-mutation arc stands, what the single remaining PATH mutation is, and
why — after measuring the options on a real Windows runner — it is the terminal
state rather than something we can remove. The short version:

- **The last PATH mutation is a single, process-scoped `PATH` prepend that only
  happens on a Windows *host*.** Non-Windows hosts already run with zero PATH
  mutation (`PointLinkerToShim` points the SDK probes at the shim by absolute
  path). Linux and macOS *hosts* are done.
- **Removing it would need the shim resolvable by a colon-free name** that the
  SDK's `where /Q` linker probe accepts. **A Windows-runner experiment showed no
  such form exists** (see [The `where /Q` experiment](#the-where-q-experiment)):
  every colon-free path `where` was given failed to resolve, and it cannot take
  the absolute path because of the drive colon. The bare-name-on-PATH form is
  the only one that works, which is exactly what the prepend provides. So the
  prepend stays — this is the "no, because X" outcome the ROADMAP anticipated.
- **The `AOTANYWHERE_ZIG` / `AOTANYWHERE_APPLE_SYSROOT` env channels can be
  collapsed** into `LinkerArg`-injected flags, but that does not touch PATH (they
  are namespaced, process-scoped env vars, not PATH) and it adds parse-and-strip
  surface to the shim's link hot path. It is optional cleanup, not a path to the
  headline goal, and is deferred.

See also the "Design constraints discovered" and "Not covered" sections of
[`direct-link.md`](direct-link.md), which this document extends.

## Current state

The link no longer needs anything on `PATH` except in one case. Walking the
mutations that used to exist and where they went:

| Channel | Was | Now |
| --- | --- | --- |
| Shim directory on `PATH` | prepended on every host | **gone off Windows** (`CppLinker`/`ObjCopyName` set to the shim's absolute path; `command -v` accepts it). Still prepended on a **Windows host** — see below. |
| `zig` on `PATH` | prepended | gone everywhere. `SetPathToZig` resolves zig's absolute path; the direct link and shim compilation use `$(_AotAnywhereZigExe)`, and the shim receives it through `AOTANYWHERE_ZIG`. |
| `AOTANYWHERE_ZIG` | — | process-env var the `clang`/`link` shim personalities read to exec zig by absolute path (falls back to `zig` on `PATH`). |
| `AOTANYWHERE_APPLE_SYSROOT` | — | process-env var the `clang` personality reads for the Apple stub sysroot. |

So the remaining mutations are: one Windows-host `PATH` prepend, plus two
process-scoped, namespaced env vars.

## Why the Windows-host prepend is still there

On a Windows host targeting Linux/macOS, `SetupOSSpecificProps` (in the ILC
SDK's `Microsoft.NETCore.Native.Unix.targets`) probes the linker and the objcopy
symbol stripper before we ever run:

```xml
<_CommandProbe>command -v</_CommandProbe>
<_CommandProbe Condition="$([MSBuild]::IsOSPlatform('Windows'))">where /Q</_CommandProbe>
...
<Exec Command="$(_CommandProbe) &quot;$(CppLinker)&quot;" IgnoreExitCode="true" ... />
```

and `Error`s if the probe exits non-zero. `command -v "<abs path>"` accepts an
absolute path, so off Windows we point `CppLinker`/`ObjCopyName` straight at the
materialized shim and skip PATH entirely. `where /Q "<abs path>"` does **not**:
it reads the drive-letter colon in `C:\...\clang.exe` as its own `path:pattern`
delimiter and fails with `Invalid pattern is specified in "path:pattern"`. So on
a Windows host the shim has to be found by a bare name (`clang`,
`llvm-objcopy` — the SDK defaults) with its directory prepended to `$PATH`.

The probe `Exec` is unconditional and runs with no `WorkingDirectory`, and the
value it probes (`$(CppLinker)`) is the same value later exec'd as the real
linker — so we cannot skip the probe, cannot give it a probe-only value that
differs from the exec path, and cannot rely on a particular working directory.

## The `where /Q` experiment

The one open question was whether *any* colon-free form of the shim path would
satisfy `where /Q`. Measured directly on `windows-latest` through an MSBuild
`<Exec>` (the same task the SDK uses), against a real file. Exit `0` = `where`
resolved it.

| # | Form probed | Exit | Verdict |
| --- | --- | --- | --- |
| 0 | bare `clang.exe`, dir on `PATH` | **0** | today's approach — works |
| 1 | `C:\…\clang.exe` (drive colon) | 2 | baseline failure (`path:pattern` misparse) |
| 2 | `\…\clang.exe` (drive-relative, colon-free) | 1 | not found |
| 3 | `C:/…/clang.exe` (forward slashes) | 2 | colon still present — fails |
| 4 | `where-probe\clang.exe` (relative), cwd = containing dir | 1 | not found |
| 5 | `where-probe\clang.exe` (relative), cwd = elsewhere | 1 | not found |
| 6 | `\…\where-probe:clang.exe` (`where` `dir:pattern`, colon-free dir) | 1 | not found |

The finding is unambiguous: **`where` resolves a bare filename (via `PATH` or the
current directory) but not any path that carries a directory component**, colon
or not. Removing the colon does not help — forms 2, 4, 5 and 6 are all colon-free
and all fail. There is therefore no "colon-free linker name" that lets the shim
sit in its own intermediate directory and still be found without putting that
directory on `PATH`.

(The experiment lived in `eng/where-probe/` and `.github/workflows/where-probe.yml`
and was removed once it had answered the question; this table is its result.)

## Options considered

### A. Colon-free `CppLinker` path — rejected (measured)

Point `CppLinker`/`ObjCopyName` at the shim by a colon-free path (drive-relative,
project-relative, or `where`'s `dir:pattern`). The experiment above shows `where`
rejects all of them: it will not resolve a value containing a directory
component. Dead end.

### B. `where "$ENVVAR:pattern"` — rejected

`where` accepts `where "$SOMEVAR:clang"` (search the `;`-list in env var
`SOMEVAR`). But `$(CppLinker)` is also exec'd as the real linker, and
`"$SOMEVAR:clang" args` is not a runnable executable. Probe-name and exec-path
are the same property; they cannot diverge. (This is essentially a namespaced
`PATH` in an env var anyway — not less mutation, just spelled differently.)

### C. Skip / pre-satisfy the probe — rejected

The probe `Exec` is unconditional and overwrites `_WhereLinker` with its own
result, so a pre-set value cannot survive, and there is no package hook to
condition the `Exec` out.

### D. Drop a bare-named shim into the current directory — rejected

`where` searches the current directory, so a bare `clang.exe` in the build's cwd
resolves with no `PATH` mutation — but the probe's cwd is the consumer's launch
directory (the `Exec` sets no `WorkingDirectory`), not ours, and writing a build
artifact there would be worse than a scoped, process-only prepend of our own obj
directory anyway.

### E. Accept the prepend as terminal — the outcome

The current state *is* the terminal one: a single, process-scoped prepend of the
shim's own intermediate directory, on Windows hosts only, gated behind the SDK's
own `where /Q` limitation. It mutates nothing persistent and nothing outside the
build process. Short of the SDK gaining a way to pass the linker by absolute path
on Windows (an upstream ask — see ROADMAP #7), this is as far as the arc goes.

## Collapsing the env channels (optional, deferred)

Independently of PATH, `AOTANYWHERE_ZIG` and `AOTANYWHERE_APPLE_SYSROOT` could
move from process-env vars to flags injected through `@(LinkerArg)` — the same
channel `OverwriteTargetTriple` already uses for `--target=<triple>`, which
reaches **both** shim personalities that need it:

- The `clang` personality (macOS targets) gets `LinkerArg` items on its command
  line directly.
- The `link` personality (Windows targets) gets them too: `--target` is injected
  via `LinkerArg` and arrives inside the expanded `link.rsp` (see the
  `link_shim.zig` header). A `--aotanywhere-zig=<path>` line would arrive the
  same way.
- The `objcopy` personality needs neither var — it does its own ELF surgery and
  never execs zig — so it needs no channel at all.

Feasibility is not the blocker. The reasons to leave it are:

- **It does not advance the headline.** These are namespaced, process-scoped env
  vars, not PATH; with the PATH prepend proven terminal, collapsing them does not
  get us to "zero mutation". `direct-link.md` already calls the trade "cleaner,
  but still not zero mutation."
- **Added risk on the link hot path.** Each personality would have to recognize
  the new flags and *strip* them before forwarding to `zig cc` (an unrecognized
  `--aotanywhere-*` flag reaching zig fails the link) — new parse-and-strip
  surface in the most correctness-sensitive code in the repo.
- **Fallback still required.** The `zig`-on-PATH fallback (external zig, degraded
  restore) must survive, so the env read cannot simply be deleted.

Both the `clang` (macOS target) and `link` (win-x64 target) paths are exercisable
from a Linux/macOS host, so this is testable without a Windows host if it is ever
picked up — but it is deferred as marginal.

## Conclusion

The zero-PATH-mutation arc is complete to the extent the tooling allows: every
host but Windows runs with no PATH mutation, and the Windows-host prepend is
irreducible given the SDK's `where /Q` probe (proven by experiment, not
assumption). The only routes to removing it are upstream: a dotnet/runtime hook
to pass the Windows linker by absolute path, or to skip the probe — which folds
into the broader "override the link invocation" ask in ROADMAP #7. The env-channel
collapse remains available as optional, non-PATH cleanup.
