using System.Diagnostics;
using System.Text;
using Microsoft.Build.Framework;
using MSBuildTask = Microsoft.Build.Utilities.Task;

namespace AotAnywhere.Tasks;

/// Links a NativeAOT Windows target from a non-Windows host by translating the
/// MSVC link.exe arguments to `zig cc -target <arch>-windows-gnu` and running
/// zig. Replaces the link.exe-impersonating personality of link_shim.zig: the
/// package's targets invoke this directly (BeforeTargets="LinkNative") instead
/// of routing $(CppLinker) through a PATH shim.
///
/// Pure logic lives in MsvcArgTranslator (option translation) and
/// CoffSectionRenamer (/MERGE); this task is the orchestration - support-file
/// emission, /MERGE object copies, process launch, and MSBuild logging.
public sealed class AotAnywhereWindowsLink : MSBuildTask
{
    /// The MSVC-style link tokens: the object, /OUT, /DEF etc. framing the SDK
    /// would have written to link.rsp, plus @(LinkerArg) (which carries the
    /// injected --target=<triple>).
    [Required] public ITaskItem[] MsvcArgs { get; set; } = System.Array.Empty<ITaskItem>();

    /// Absolute path to zig (or bare "zig"); $(_AotAnywhereZigExe).
    [Required] public string ZigExe { get; set; } = "";

    /// Directory for the stub archives and /MERGE object copies (the native
    /// intermediate output path).
    [Required] public string SupportDir { get; set; } = "";

    /// Path to the shipped MSVC glue source, compiled into the link.
    [Required] public string GlueSource { get; set; } = "";

    /// Whether to honor /OPT:REF and /OPT:ICF with the second lld-link pass.
    /// $(AotAnywhereWindowsLinkOptimize) != 'false'; with it off, /OPT is
    /// dropped and the binary is ~15% larger (matching lld's OPT:NOREF,NOICF
    /// defaults). The opt-out is an escape hatch for the guards around
    /// replaying zig's verbose link line (see RelinkWithOptFlags).
    public bool Optimize { get; set; } = true;

    static readonly string[] StubLibNames = { "libLIBCMT.a", "libOLDNAMES.a", "liblibcpmt.a", "libuuid.a" };
    const string StubDirName = "aotanywhere-msvc-stub-libs";
    const string OptOutHint = "Set AotAnywhereWindowsLinkOptimize=false to link without /OPT:REF,/OPT:ICF (larger binary).";

    /// Environment overrides for the zig processes (the cache pins and
    /// redirects AliasSpacedPaths sets up).
    readonly Dictionary<string, string> _zigEnv = new();

    public override bool Execute()
    {
        // Each item is an rsp-style line (quoted, possibly several tokens), not
        // a bare argument - tokenize exactly as the shim tokenizes link.rsp.
        var tokens = MsvcArgTranslator.Tokenize(MsvcArgs.Select(i => i.ItemSpec));
        var translation = MsvcArgTranslator.Translate(tokens);

        foreach (var warning in translation.Warnings)
            Log.LogWarning(warning);
        if (!translation.SawTarget)
            Log.LogWarning("AotAnywhere: no --target=<triple> was injected; linking for the host by mistake is likely.");

        Directory.CreateDirectory(SupportDir);
        ApplyMerges(translation);
        var stubDir = WriteStubArchives();

        var argv = new List<string> { "cc" };
        argv.AddRange(translation.Args);
        argv.Add(GlueSource);
        argv.Add("-L" + stubDir);

        // /OPT:REF and /OPT:ICF need a second lld-link pass (see LldLinkReplay);
        // -v makes zig print the lld-link argv the pass replays.
        var wantOpt = Optimize && (translation.OptRef || translation.OptIcf);
        if (wantOpt) argv.Add("-v");

        string? scratchDir = null;
        try
        {
            if (wantOpt && !AliasSpacedPaths(argv, translation, ref scratchDir)) return false;

            var stderrLines = wantOpt ? new List<string>() : null;
            if (!RunZig(argv, stderrLines)) return false;
            if (wantOpt && !RelinkWithOptFlags(translation, stderrLines!)) return false;
            return !Log.HasLoggedErrors;
        }
        finally
        {
            if (scratchDir != null)
                try { Directory.Delete(scratchDir, recursive: true); } catch { /* scratch litter only */ }
        }
    }

    /// The verbose line the /OPT re-link replays is space-joined with no
    /// quoting, so paths containing spaces must not reach zig as-is. zig
    /// echoes the paths it was given verbatim, so routing every spaced path
    /// (arguments, and zig's cache directories via its cache env vars)
    /// through space-free symlink aliases keeps the line reconstructible.
    bool AliasSpacedPaths(List<string> argv, MsvcTranslation t, ref string? scratchDir)
    {
        // Pin both cache env vars rather than predict zig's own resolution:
        // with no override, zig cc roots its local cache at `.zig-cache` under
        // the nearest ancestor directory holding a build.zig (else the global
        // dir), and that discovery cannot be reproduced here. Unpinned, a
        // build.zig ancestor under a spaced path would put the glue object at
        // a spaced local-cache path this method never saw (issue #67).
        var cacheDirs = ResolveZigCacheDirs(Environment.GetEnvironmentVariable);
        foreach (var (variable, dir) in cacheDirs) _zigEnv[variable] = dir;

        var spacedCacheDirs = cacheDirs.Where(c => LinkPathAliaser.HasSpace(c.Dir)).ToList();
        if (spacedCacheDirs.Count == 0 && !argv.Any(LinkPathAliaser.HasSpace)) return true;

        // Hosts are non-Windows only; /tmp is the space-free fallback when the
        // temp dir itself is spaced (TMPDIR override).
        var tempRoot = Path.GetTempPath();
        if (LinkPathAliaser.HasSpace(tempRoot)) tempRoot = "/tmp";
        scratchDir = Path.Combine(tempRoot, "aotanywhere-link-" + Guid.NewGuid().ToString("N").Substring(0, 12));

        try
        {
            Directory.CreateDirectory(scratchDir);
            var aliaser = new LinkPathAliaser(scratchDir, CreateSymlink);

            if (!aliaser.TryRewriteArgv(argv, out var aliasedOut, out var error))
            {
                Log.LogError($"AotAnywhere: cannot alias the link paths for the /OPT re-link: {error}. {OptOutHint}");
                return false;
            }
            if (aliasedOut != null) t.OutPath = aliasedOut; // what -OUT: will now say

            foreach (var (variable, dir) in spacedCacheDirs)
            {
                Directory.CreateDirectory(dir); // symlink to a real dir, not a dangling one
                _zigEnv[variable] = aliaser.DirAlias(dir);
            }
        }
        catch (Exception e)
        {
            Log.LogError($"AotAnywhere: cannot alias the link paths for the /OPT re-link: {e.Message}. {OptOutHint}");
            return false;
        }

        Log.LogMessage(MessageImportance.Normal,
            $"AotAnywhere: paths with spaces aliased under '{scratchDir}' so the /OPT re-link can replay zig's link line.");
        return true;
    }

    /// zig's cache directories surface in the printed line too: the compiled
    /// glue object lands in the local cache, crt2.obj and the MinGW import
    /// libraries in the global one. Resolves both to what the caller then
    /// pins via the env vars. Global: the explicit env var, else
    /// XDG_CACHE_HOME/zig, else HOME/.cache/zig. Local: the explicit env
    /// var, else the resolved global dir - which is what zig cc itself does
    /// outside a build.zig tree (its ancestor build.zig discovery is
    /// deliberately overridden - see AliasSpacedPaths).
    public static List<(string Variable, string Dir)> ResolveZigCacheDirs(Func<string, string?> getEnv)
    {
        var xdg = getEnv("XDG_CACHE_HOME");
        var defaultDir = Path.Combine(
            string.IsNullOrEmpty(xdg)
                ? Path.Combine(getEnv("HOME") ?? ".", ".cache")
                : xdg,
            "zig");

        // netstandard2.0's IsNullOrEmpty has no nullability annotation; the
        // patterns keep the flow analysis (and so the build) warning-free.
        var globalDir = getEnv("ZIG_GLOBAL_CACHE_DIR") is { Length: > 0 } g ? g : defaultDir;
        var localDir = getEnv("ZIG_LOCAL_CACHE_DIR") is { Length: > 0 } l ? l : globalDir;

        return new List<(string Variable, string Dir)>
        {
            ("ZIG_GLOBAL_CACHE_DIR", globalDir),
            ("ZIG_LOCAL_CACHE_DIR", localDir),
        };
    }

    static void CreateSymlink(string target, string linkPath)
    {
        if (symlink(target, linkPath) != 0)
            throw new IOException($"symlink('{target}', '{linkPath}') failed (errno {System.Runtime.InteropServices.Marshal.GetLastWin32Error()})");
    }

    // This task only runs on non-Windows hosts (on Windows the SDK's MSVC link
    // applies), so libc is always there.
    [System.Runtime.InteropServices.DllImport("libc", SetLastError = true)]
    static extern int symlink(string target, string linkPath);

    /// The zig cc link above produced a correct but unoptimized binary (zig
    /// always hands lld-link -DEBUG, so lld defaults to OPT:NOREF,NOICF and
    /// there is no zig flag to override it). Re-run the exact lld-link
    /// invocation zig printed - via zig's lld-link subcommand, so it is the
    /// same linker - with the /OPT flags appended, overwriting the binary and
    /// PDB in place. No fallback: if the replay cannot be trusted, fail the
    /// link rather than silently ship the ~15% larger binary.
    bool RelinkWithOptFlags(MsvcTranslation t, List<string> stderrLines)
    {
        var flags = (t.OptRef ? " /OPT:REF" : "") + (t.OptIcf ? " /OPT:ICF" : "");

        var line = LldLinkReplay.FindLldLinkLine(stderrLines);
        if (line == null)
        {
            Log.LogError($"AotAnywhere: zig cc -v did not print an lld-link invocation, so{flags} cannot be applied (zig verbose-output change?). {OptOutHint}");
            return false;
        }

        var lldArgv = LldLinkReplay.ParseArgv(line, t.OutPath ?? "", File.Exists, Path.GetFullPath, out var error);
        if (lldArgv == null)
        {
            Log.LogError($"AotAnywhere: cannot replay the lld-link invocation to apply{flags}: {error}. {OptOutHint}");
            return false;
        }

        var argv = new List<string> { "lld-link" };
        argv.AddRange(lldArgv);
        if (t.OptRef) argv.Add("-OPT:REF");
        if (t.OptIcf) argv.Add("-OPT:ICF");

        Log.LogMessage(MessageImportance.Normal, $"AotAnywhere: re-linking with{flags} (zig cc cannot pass COFF /OPT flags through).");
        return RunZig(argv, null);
    }

    /// Honors /MERGE by renaming COFF sections in the input objects. Inputs are
    /// never modified in place (some live in the shared NuGet cache), so any
    /// object that actually gets a rename is copied into SupportDir and its
    /// linker argument redirected to the copy. Port of link_shim.zig applyMerges.
    void ApplyMerges(MsvcTranslation t)
    {
        if (t.Merges.Count == 0) return;

        for (var index = 0; index < t.ObjectInputs.Count; index++)
        {
            var path = t.ObjectInputs[index];
            byte[] data;
            try { data = File.ReadAllBytes(path); }
            catch (Exception e) { Log.LogWarning($"AotAnywhere /MERGE: skipping '{path}': {e.Message}"); continue; }

            var total = new RenameResult();
            foreach (var (from, to) in t.Merges)
            {
                var r = CoffSectionRenamer.RenameSections(data, from, to);
                total.Renamed += r.Renamed;
                total.SkippedLong += r.SkippedLong;
                total.SkippedInitialized += r.SkippedInitialized;
            }

            if (total.SkippedLong > 0)
                Log.LogWarning($"AotAnywhere /MERGE: {total.SkippedLong} section(s) in '{path}' not merged (target name over 8 chars).");
            if (total.SkippedInitialized > 0)
                Log.LogWarning($"AotAnywhere /MERGE: {total.SkippedInitialized} initialized section(s) in '{path}' not merged into .bss.");
            if (total.Renamed == 0) continue;

            // The index prefix keeps same-named objects from different dirs apart.
            var copyPath = Path.Combine(SupportDir, $"aotanywhere-merged-{index}-{Path.GetFileName(path)}");
            try { WriteReplacing(copyPath, data); }
            catch (Exception e) { Log.LogWarning($"AotAnywhere /MERGE: could not write merged copy of '{path}': {e.Message}"); continue; }

            for (var i = 0; i < t.Args.Count; i++)
                if (t.Args[i] == path) t.Args[i] = copyPath;
            Log.LogMessage(MessageImportance.Normal,
                $"AotAnywhere /MERGE: renamed {total.Renamed} section(s); linking {copyPath} in place of {path}.");
        }
    }

    /// Writes via a temp file + rename so an interrupted run never leaves a
    /// truncated object for an incremental build to pick up.
    static void WriteReplacing(string path, byte[] data)
    {
        var tmp = path + ".aotanywhere-tmp";
        File.WriteAllBytes(tmp, data);
        if (File.Exists(path)) File.Delete(path);
        File.Move(tmp, path);
    }

    /// The MSVC objects carry /DEFAULTLIB directives for MSVC-only libraries;
    /// empty archives satisfy the directive while the MinGW CRT and the glue
    /// provide the symbols. Returns the stub directory to add as -L.
    string WriteStubArchives()
    {
        var stubDir = Path.Combine(SupportDir, StubDirName);
        Directory.CreateDirectory(stubDir);
        foreach (var name in StubLibNames)
            File.WriteAllText(Path.Combine(stubDir, name), "!<arch>\n");
        return stubDir;
    }

    /// stderrCapture also collects stderr for the caller (the -v verbose argv
    /// lines); the huge cc1/lld-link argv lines it exists to catch are logged
    /// Low so real diagnostics keep standing out.
    bool RunZig(List<string> argv, List<string>? stderrCapture)
    {
        var sb = new StringBuilder();
        foreach (var arg in argv) AppendArgument(sb, arg);
        var arguments = sb.ToString();

        Log.LogMessage(MessageImportance.Normal, $"AotAnywhere: {ZigExe} {arguments}");

        var psi = new ProcessStartInfo
        {
            FileName = ZigExe,
            Arguments = arguments,
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        foreach (var pair in _zigEnv) psi.Environment[pair.Key] = pair.Value;

        try
        {
            using var p = new Process { StartInfo = psi };
            p.OutputDataReceived += (_, e) => { if (e.Data != null) Log.LogMessage(MessageImportance.Normal, e.Data); };
            p.ErrorDataReceived += (_, e) =>
            {
                if (e.Data == null) return;
                stderrCapture?.Add(e.Data);
                var verboseArgv = stderrCapture != null &&
                    (e.Data.StartsWith("lld-link ", StringComparison.Ordinal) || e.Data.Contains(" -cc1 "));
                Log.LogMessage(verboseArgv ? MessageImportance.Low : MessageImportance.High, e.Data);
            };
            p.Start();
            p.BeginOutputReadLine();
            p.BeginErrorReadLine();
            p.WaitForExit();
            if (p.ExitCode != 0)
            {
                Log.LogError($"AotAnywhere: zig cc failed with exit code {p.ExitCode}.");
                return false;
            }
            return true;
        }
        catch (Exception e)
        {
            Log.LogError($"AotAnywhere: could not run zig ('{ZigExe}'): {e.Message}");
            return false;
        }
    }

    /// Quotes a single argument for ProcessStartInfo.Arguments the way the CRT
    /// (and .NET's own PasteArguments) expects, so args with spaces survive.
    static void AppendArgument(StringBuilder sb, string arg)
    {
        if (sb.Length != 0) sb.Append(' ');
        if (arg.Length != 0 && arg.IndexOfAny(new[] { ' ', '\t', '\n', '\v', '"' }) < 0)
        {
            sb.Append(arg);
            return;
        }
        sb.Append('"');
        var idx = 0;
        while (idx < arg.Length)
        {
            var c = arg[idx++];
            if (c == '\\')
            {
                var backslashes = 1;
                while (idx < arg.Length && arg[idx] == '\\') { idx++; backslashes++; }
                if (idx == arg.Length) sb.Append('\\', backslashes * 2);
                else if (arg[idx] == '"') { sb.Append('\\', backslashes * 2 + 1); sb.Append('"'); idx++; }
                else sb.Append('\\', backslashes);
            }
            else if (c == '"') { sb.Append('\\'); sb.Append('"'); }
            else sb.Append(c);
        }
        sb.Append('"');
    }
}
