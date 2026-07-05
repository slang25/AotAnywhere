#!/usr/bin/env dotnet
// Generate the curated Apple .tbd stub sysroot shipped with AotAnywhere.
//
// .NET Native AOT binaries targeting macOS link against a handful of Apple
// system libraries and frameworks. When cross-compiling from Linux or Windows
// there is no Apple SDK, so the package ships minimal, self-authored .tbd
// linker stubs for exactly the symbols the .NET runtime packs reference.
//
// This script regenerates those stubs. It must run on macOS with Xcode (or the
// Command Line Tools) installed:
//
//   1. Downloads the .NET Native AOT runtime packs pinned in PackVersions for
//      osx-x64 and osx-arm64 from nuget.org (cached under eng/.cache/).
//   2. Collects the undefined symbols of every static library / object file in
//      each pack, minus the symbols the same pack defines itself.
//   3. Drops symbols that zig's bundled libSystem stub already resolves
//      (zig cc always links libSystem for macOS targets).
//   4. Attributes each remaining symbol to the Apple library that exports it,
//      using the local macOS SDK's .tbd files as the lookup table.
//   5. Writes minimal tbd-v4 stubs (only the referenced symbols, i.e. symbol
//      lists derived from the MIT-licensed .NET runtime packs - NOT copies of
//      Apple's export lists) to src/apple-sysroot/.
//
// Update PackVersions when new .NET releases ship, re-run, and commit the
// result. It is a .NET file-based app, so run it directly with:
//
//   dotnet run eng/generate-apple-sysroot.cs

using System.IO.Compression;
using System.Runtime.CompilerServices;
using System.Text;
using System.Text.RegularExpressions;

await Generator.RunAsync();

static partial class Generator
{
    static string ScriptPath([CallerFilePath] string path = "") => path;

    static readonly string RepoRoot =
        Path.GetDirectoryName(Path.GetDirectoryName(Path.GetFullPath(ScriptPath())))!;
    static readonly string CacheDir =
        Path.Combine(RepoRoot, "eng", ".cache", "apple-sysroot-packs");
    static readonly string OutputDir = Path.Combine(RepoRoot, "src", "apple-sysroot");

    private static readonly string[] Rids = ["osx-x64", "osx-arm64"];

    // The .NET versions whose runtime packs seed the symbol lists. Keep the
    // newest patch of every in-support major here (older patches only ever
    // reference fewer symbols).
    static readonly (string Family, string[] Versions)[] PackVersions =
    [
        // net8/net9: static libs live in runtime.<rid>.microsoft.dotnet.ilcompiler
        ("ilcompiler", ["8.0.28", "9.0.16"]),
        // net10+: static libs live in microsoft.netcore.app.runtime.nativeaot.<rid>
        ("nativeaot", ["10.0.9", "11.0.0-preview.5.26302.115"])
    ];

    // Stubs to generate, in symbol-attribution priority order (a symbol exported
    // by several libraries is assigned to the first match; CoreFoundation must
    // come before Foundation, which reexports parts of it).
    // (name, SDK tbd path relative to the SDK root, sysroot-relative output path)
    static readonly (string Name, string SdkRel, string OutRel)[] Libraries =
    [
        ("CoreFoundation", "System/Library/Frameworks/CoreFoundation.framework/CoreFoundation.tbd",
         "System/Library/Frameworks/CoreFoundation.framework/CoreFoundation.tbd"),
        ("Foundation", "System/Library/Frameworks/Foundation.framework/Foundation.tbd",
         "System/Library/Frameworks/Foundation.framework/Foundation.tbd"),
        ("Security", "System/Library/Frameworks/Security.framework/Security.tbd",
         "System/Library/Frameworks/Security.framework/Security.tbd"),
        ("GSS", "System/Library/Frameworks/GSS.framework/GSS.tbd",
         "System/Library/Frameworks/GSS.framework/GSS.tbd"),
        ("Network", "System/Library/Frameworks/Network.framework/Network.tbd",
         "System/Library/Frameworks/Network.framework/Network.tbd"),
        ("CryptoKit", "System/Library/Frameworks/CryptoKit.framework/CryptoKit.tbd",
         "System/Library/Frameworks/CryptoKit.framework/CryptoKit.tbd"),
        ("libobjc", "usr/lib/libobjc.tbd", "usr/lib/libobjc.tbd"),
        ("libicucore", "usr/lib/libicucore.tbd", "usr/lib/libicucore.tbd"),
        ("libz", "usr/lib/libz.tbd", "usr/lib/libz.tbd"),
        ("libswiftCore", "usr/lib/swift/libswiftCore.tbd", "usr/lib/swift/libswiftCore.tbd"),
        ("libswiftFoundation", "usr/lib/swift/libswiftFoundation.tbd", "usr/lib/swift/libswiftFoundation.tbd")
    ];

    [GeneratedRegex(@"\.(a|o)$")]
    static partial Regex NativeMember { get; }

    static readonly HttpClient Http = new();

    // --- shelling out ------------------------------------------------------

    static string Run(params string[] argv)
    {
        var (code, stdout, stderr) = Capture(argv);
        if (code != 0)
            throw new Exception($"command failed ({code}): {string.Join(' ', argv)}\n{stderr}");
        return stdout;
    }

    static (int Code, string Stdout, string Stderr) Capture(string[] argv)
    {
        var psi = new System.Diagnostics.ProcessStartInfo
        {
            FileName = argv[0],
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
        };
        for (int i = 1; i < argv.Length; i++)
        {
            psi.ArgumentList.Add(argv[i]);
        }
        using var p = System.Diagnostics.Process.Start(psi)!;
        string stdout = p.StandardOutput.ReadToEnd();
        string stderr = p.StandardError.ReadToEnd();
        p.WaitForExit();
        return (p.ExitCode, stdout, stderr);
    }

    static string SdkPath() => Run("xcrun", "--show-sdk-path").Trim();

    static string ZigLibSystemTbd()
    {
        // Locate the libSystem stub bundled with the zig on PATH.
        string outp = Run("zig", "env");
        var m = Regex.Match(outp, "\\.lib_dir = \"([^\"]+)\"");   // zig 0.15+ zon output
        if (!m.Success)
            m = Regex.Match(outp, "\"lib_dir\":\\s*\"([^\"]+)\""); // older json output
        if (!m.Success)
            Fail("error: could not parse `zig env` output to find lib_dir");
        string libcDir = Path.Combine(m.Groups[1].Value, "libc", "darwin");
        foreach (var name in new[] { "libSystem.tbd", "libSystem.B.tbd" })
        {
            string p = Path.Combine(libcDir, name);
            if (File.Exists(p))
                return p;
        }
        Fail($"error: no libSystem stub found in {libcDir}");
        return null!;
    }

    // (pack-id, version, arch) triples with their nuget.org download URL.
    static IEnumerable<(string Pack, string Version, string Rid, string Url)> PackUrls()
    {
        foreach (var (family, versions) in PackVersions)
            foreach (var version in versions)
                foreach (var rid in Rids)
                {
                    string pack = family == "ilcompiler"
                        ? $"runtime.{rid}.microsoft.dotnet.ilcompiler"
                        : $"microsoft.netcore.app.runtime.nativeaot.{rid}";
                    string url = $"https://api.nuget.org/v3-flatcontainer/{pack}/{version}/{pack}.{version}.nupkg";
                    yield return (pack, version, rid, url);
                }
    }

    // Download a pack (cached) and extract its .a/.o members. Returns a dir.
    static async Task<string> FetchNativeMembersAsync(string pack, string version, string url)
    {
        string dest = Path.Combine(CacheDir, $"{pack}.{version}");
        if (Directory.Exists(dest) && Directory.EnumerateFileSystemEntries(dest).Any())
            return dest;
        Console.WriteLine($"  downloading {pack} {version} ...");
        byte[] data = await Http.GetByteArrayAsync(url);
        Directory.CreateDirectory(dest);
        await using var zf = new ZipArchive(new MemoryStream(data), ZipArchiveMode.Read);
        foreach (var entry in zf.Entries)
        {
            var parts = entry.FullName.Split('/');
            if (NativeMember.IsMatch(entry.FullName) &&
                (parts[0] is "sdk" or "framework" || entry.FullName.Contains("/native/")))
            {
                string target = Path.Combine(dest, parts[^1]);
                await using var src = await entry.OpenAsync();
                await using var outp = File.Create(target);
                await src.CopyToAsync(outp);
            }
        }
        return dest;
    }

    // Union of `nm <flag>` symbol names over all .a/.o files in directory.
    static HashSet<string> NmSymbols(string directory, string flag)
    {
        var symbols = new HashSet<string>();
        foreach (var name in Directory.GetFileSystemEntries(directory)
                     .Select(Path.GetFileName)
                     .OrderBy(n => n, StringComparer.Ordinal))
        {
            if (!NativeMember.IsMatch(name!))
                continue;
            var (_, stdout, _) = Capture(["xcrun", "nm", flag, "-j", Path.Combine(directory, name!)]);
            foreach (var raw in stdout.Split('\n'))
            {
                var line = raw.Trim();
                if (line.Length != 0 && !line.EndsWith(":"))
                    symbols.Add(line);
            }
        }
        return symbols;
    }

    // --- tbd parsing (attribution lookup only) -----------------------------

    static readonly string[] ListKeys =
    [
        "symbols", "objc-classes", "objc-eh-types", "objc-ivars",
        "weak-symbols", "thread-local-symbols"
    ];
    static readonly Regex ListRe = new(
        "^\\s+(" + string.Join("|", ListKeys) + "):\\s*\\[(.*?)\\]",
        RegexOptions.Singleline | RegexOptions.Multiline);

    [GeneratedRegex("^install-name:\\s*'?([^'\n]+)'?", RegexOptions.Multiline)]
    static partial Regex InstallNameRe { get; }

    sealed class TbdInfo
    {
        public string? InstallName;
        // exported symbol name -> kind ('symbols', 'weak-symbols', ...)
        public readonly Dictionary<string, string> Exports = new();

        // Kind under which `symbol` is exported, or null.
        public string? Lookup(string symbol)
        {
            if (Exports.TryGetValue(symbol, out var kind))
                return kind;
            foreach (var (prefix, key) in new[]
                     {
                         ("_OBJC_CLASS_$_", "objc-classes"),
                         ("_OBJC_METACLASS_$_", "objc-classes"),
                         ("_OBJC_EHTYPE_$_", "objc-eh-types"),
                         ("_OBJC_IVAR_$_", "objc-ivars"),
                     })
            {
                if (symbol.StartsWith(prefix))
                {
                    string name = symbol.Substring(prefix.Length);
                    if (Exports.TryGetValue(name, out var k) && k == key)
                        return key;
                }
            }
            return null;
        }
    }

    // Union of exports over every YAML document in an Apple/zig .tbd file.
    //
    // Sub-libraries of an umbrella (e.g. Security's inlined sub-dylibs, or
    // libSystem's libsystem_* members) appear as extra documents; attributing
    // their symbols to the umbrella is exactly what a normal link does.
    static TbdInfo ParseTbd(string path)
    {
        var info = new TbdInfo();
        string text = File.ReadAllText(path);
        var m = InstallNameRe.Match(text); // first document = the umbrella itself
        if (m.Success)
            info.InstallName = m.Groups[1].Value.Trim();
        foreach (Match match in ListRe.Matches(text))
        {
            string key = match.Groups[1].Value;
            string body = match.Groups[2].Value;
            foreach (var rawEntry in body.Replace("\n", " ").Split(','))
            {
                string entry = rawEntry.Trim().Trim('\'', '"');
                if (entry.Length != 0)
                    info.Exports.TryAdd(entry, key);
            }
        }
        return info;
    }

    // --- tbd emission ------------------------------------------------------

    static readonly Regex PlainSymbol = new("^[A-Za-z0-9_.]+$");

    static string YamlSymbol(string name) =>
        PlainSymbol.IsMatch(name) ? name : $"'{name}'";

    static string FormatList(string key, IEnumerable<string> names)
    {
        var sorted = names.OrderBy(n => n, StringComparer.Ordinal).ToList();
        string prefix = $"    {key}:".PadRight(22);
        string indent = new string(' ', 24);
        string line = prefix + "[ ";
        var outLines = new List<string>();
        for (int i = 0; i < sorted.Count; i++)
        {
            string token = YamlSymbol(sorted[i]) + (i < sorted.Count - 1 ? "," : " ]");
            if (line.Length + token.Length > 100)
            {
                outLines.Add(line.TrimEnd());
                line = indent + token + " ";
            }
            else
            {
                line += token + " ";
            }
        }
        outLines.Add(line.TrimEnd());
        return string.Join("\n", outLines);
    }

    static void WriteTbd(string path, string installName, Dictionary<string, HashSet<string>> buckets)
    {
        var sections = new List<string>();
        foreach (var key in ListKeys)
        {
            if (!buckets.TryGetValue(key, out var names) || names.Count == 0)
                continue;
            IEnumerable<string> emit = names;
            if (key is "objc-classes" or "objc-eh-types" or "objc-ivars")
            {
                string[] prefixes = key switch
                {
                    "objc-classes" => ["_OBJC_CLASS_$_", "_OBJC_METACLASS_$_"],
                    "objc-eh-types" => ["_OBJC_EHTYPE_$_"],
                    _ => ["_OBJC_IVAR_$_"],
                };
                emit = names
                    .Where(n => prefixes.Any(n.StartsWith))
                    .Select(n => n.Split("$_", 2)[1])
                    .Distinct();
            }
            sections.Add(FormatList(key, emit));
        }
        // A stub with no exports is still useful: it satisfies -l/-framework
        // lookups for libraries whose symbols are bound at runtime (dlsym).
        string exports = "";
        if (sections.Count != 0)
        {
            string body = string.Join("\n", sections);
            exports = "exports:\n  - targets:         [ x86_64-macos, arm64-macos ]\n" + body + "\n";
        }
        string content =
            "--- !tapi-tbd\n" +
            "tbd-version:     4\n" +
            "targets:         [ x86_64-macos, arm64-macos ]\n" +
            $"install-name:    '{installName}'\n" +
            exports +
            "...\n";
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllText(path, content, new UTF8Encoding(false));
    }

    // --- driver ------------------------------------------------------------

    public static async Task RunAsync()
    {
        string sdk = SdkPath();
        Console.WriteLine($"SDK: {sdk}");
        string zigTbd = ZigLibSystemTbd();
        Console.WriteLine($"zig libSystem stub: {zigTbd}");

        var libsystem = ParseTbd(zigTbd);
        var sdkLibsystem = ParseTbd(Path.Combine(sdk, "usr/lib/libSystem.B.tbd"));
        var libs = new List<(string Name, string OutRel, TbdInfo Tbd)>();
        foreach (var (name, sdkRel, outRel) in Libraries)
        {
            var tbd = ParseTbd(Path.Combine(sdk, sdkRel));
            if (tbd.InstallName is null)
                Fail($"error: could not parse install-name from {sdkRel}");
            libs.Add((name, outRel, tbd));
        }

        // needed = union over packs of (undefined - defined-within-the-same-pack)
        var needed = new HashSet<string>();
        Console.WriteLine("Collecting undefined symbols from runtime packs:");
        foreach (var (pack, version, rid, url) in PackUrls())
        {
            string directory = await FetchNativeMembersAsync(pack, version, url);
            var undefined = NmSymbols(directory, "-u");
            var defined = NmSymbols(directory, "-U");
            var external = new HashSet<string>(undefined);
            external.ExceptWith(defined);
            Console.WriteLine($"  {pack} {version}: {external.Count} external references");
            needed.UnionWith(external);
        }

        // Swift objects in the packs autolink overlay dylibs via undefined
        // __swift_FORCE_LOAD_$_<lib> symbols; generate a stub for each such lib.
        const string forceLoad = "__swift_FORCE_LOAD_$_";
        foreach (var symbol in needed.Where(s => s.StartsWith(forceLoad))
                     .OrderBy(s => s, StringComparer.Ordinal))
        {
            string lib = "lib" + symbol.Substring(forceLoad.Length);
            string rel = $"usr/lib/swift/{lib}.tbd";
            if (libs.Any(l => l.Name == lib))
                continue;
            string sdkTbd = Path.Combine(sdk, rel);
            if (!File.Exists(sdkTbd))
            {
                Console.WriteLine($"WARNING: no SDK tbd for autolinked swift library {lib}; skipping");
                continue;
            }
            libs.Add((lib, rel, ParseTbd(sdkTbd)));
        }

        var resolvedByLibsystem = needed.Where(s => libsystem.Lookup(s) is not null).ToHashSet();
        needed.ExceptWith(resolvedByLibsystem);
        var missingFromZig = needed.Where(s => sdkLibsystem.Lookup(s) is not null).ToHashSet();
        needed.ExceptWith(missingFromZig); // libSystem-owned either way; a stub can't help

        // lib -> kind -> set of syms
        var assigned = libs.ToDictionary(l => l.Name, _ => new Dictionary<string, HashSet<string>>());
        var leftovers = new List<string>();
        foreach (var symbol in needed.OrderBy(s => s, StringComparer.Ordinal))
        {
            bool matched = false;
            foreach (var (name, _, tbd) in libs)
            {
                var kind = tbd.Lookup(symbol);
                if (kind is not null)
                {
                    if (!assigned[name].TryGetValue(kind, out var set))
                        assigned[name][kind] = set = [];
                    set.Add(symbol);
                    matched = true;
                    break;
                }
            }
            if (!matched)
                leftovers.Add(symbol);
        }

        Console.WriteLine($"\n{resolvedByLibsystem.Count} symbols resolved by zig's libSystem stub");
        foreach (var (name, outRel, tbd) in libs)
        {
            var buckets = assigned[name];
            int total = buckets.Values.Sum(v => v.Count);
            string outPath = Path.Combine(OutputDir, outRel);
            WriteTbd(outPath, tbd.InstallName!, buckets);
            Console.WriteLine($"{name}: {total} symbols -> {Path.GetRelativePath(RepoRoot, outPath)}");
        }

        if (missingFromZig.Count != 0)
        {
            Console.WriteLine("\nWARNING: needed by the packs, exported by the SDK's libSystem, but " +
                "missing from zig's libSystem stub (link will fail until zig updates):");
            foreach (var s in missingFromZig.OrderBy(s => s, StringComparer.Ordinal))
                Console.WriteLine($"  {s}");
        }
        if (leftovers.Count != 0)
        {
            Console.WriteLine($"\n{leftovers.Count} symbols not attributed to any stub " +
                "(expected: ilc-generated symbols the app object provides):");
            foreach (var s in leftovers)
                Console.WriteLine($"  {s}");
        }
    }

    static void Fail(string message)
    {
        Console.Error.WriteLine(message);
        Environment.Exit(1);
    }
}
