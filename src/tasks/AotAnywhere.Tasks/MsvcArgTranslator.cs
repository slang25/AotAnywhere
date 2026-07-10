using System.Text;

namespace AotAnywhere.Tasks;

/// Result of translating an MSVC link.exe command line to `zig cc` arguments.
/// Port of link_shim.zig's Translation.
public sealed class MsvcTranslation
{
    /// zig cc arguments, in input order.
    public List<string> Args { get; } = new();
    public List<string> Warnings { get; } = new();
    /// /MERGE:from=to requests, honored later by renaming COFF sections.
    public List<(string From, string To)> Merges { get; } = new();
    /// Loose object-file inputs - the rename candidates for the merges above.
    public List<string> ObjectInputs { get; } = new();
    public bool SawTarget { get; set; }
    public string? OutPath { get; set; }
    /// /OPT:REF and /OPT:ICF. zig cc cannot express them (its -Wl parser has
    /// no COFF /OPT mapping and it always hands lld-link -DEBUG, whose default
    /// is OPT:NOREF,NOICF), so the task honors them with a second lld-link
    /// pass instead of via Args.
    public bool OptRef { get; set; }
    public bool OptIcf { get; set; }
}

/// Translates MSVC link.exe arguments to `zig cc` arguments. Pure rewriting;
/// support-file emission, /MERGE surgery and the process launch live elsewhere.
/// Faithful port of link_shim.zig's translate() and helpers.
public static class MsvcArgTranslator
{
    /// MSVC options with no effect on / no equivalent in an lld MinGW link,
    /// dropped without a warning. Matched on the name alone or name + ':'.
    static readonly string[] SilentlyDropped =
    {
        "NOLOGO", "MANIFEST", "MANIFESTUAC", "MANIFESTFILE", "INCREMENTAL",
        "NOEXP", "NOIMPLIB", "IGNORE", "NATVIS", "SOURCELINK",
        "CETCOMPAT", "GUARD", "SAFESEH", "NODEFAULTLIB", "DEFAULTLIB",
        "MACHINE", "PDB", "PDBALTPATH", "BASE", "DYNAMICBASE",
        "NXCOMPAT", "HIGHENTROPYVA", "FIXED", "TSAWARE", "MAP",
        "VERBOSE", "WX", "TIME", "ERRORREPORT", "LARGEADDRESSAWARE",
        "RELEASE", "DEBUGTYPE",
    };

    /// Splits rsp-style lines into tokens. The SDK's Windows CustomLinkerArg
    /// items are effectively response-file lines - whitespace separates,
    /// double quotes group (also mid-token, as in /NATVIS:"path with spaces"),
    /// and a single item may carry several tokens ("/NOLOGO /MANIFEST:NO").
    /// Port of link_shim.zig's tokenizeLine. Must run before Translate.
    public static List<string> Tokenize(IEnumerable<string> lines)
    {
        var tokens = new List<string>();
        foreach (var line in lines) TokenizeLine(line, tokens);
        return tokens;
    }

    public static void TokenizeLine(string line, List<string> tokens)
    {
        var token = new StringBuilder();
        var inToken = false;
        var inQuotes = false;
        foreach (var c in line)
        {
            if (c == '"') { inQuotes = !inQuotes; inToken = true; continue; }
            if (!inQuotes && (c == ' ' || c == '\t'))
            {
                if (inToken) { tokens.Add(token.ToString()); token.Clear(); inToken = false; }
                continue;
            }
            token.Append(c);
            inToken = true;
        }
        if (inToken) tokens.Add(token.ToString());
    }

    public static MsvcTranslation Translate(IReadOnlyList<string> tokens)
    {
        var t = new MsvcTranslation();
        var debugEmitted = false;

        foreach (var token in tokens)
        {
            if (token.Length == 0) continue;

            // The target triple line Crosscompile.targets injects via LinkerArg.
            if (token.StartsWith("--target=", StringComparison.Ordinal))
            {
                t.Args.Add(token);
                t.SawTarget = true;
                continue;
            }

            if (token[0] == '/' || token[0] == '-')
            {
                var opt = token.Substring(1);
                string? p;

                if ((p = OptPayload(opt, "OUT")) != null) { t.Args.Add("-o"); t.Args.Add(p); t.OutPath = p; continue; }
                if ((p = OptPayload(opt, "DEF")) != null) { t.Args.Add(p); continue; } // lld takes a .def as a plain input
                if (EqI(opt, "DLL")) { t.Args.Add("-shared"); continue; }
                if ((p = OptPayload(opt, "LIBPATH")) != null) { t.Args.Add("-L" + p); continue; }
                if ((p = OptPayload(opt, "SUBSYSTEM")) != null)
                {
                    // /SUBSYSTEM:CONSOLE[,major[.minor]] - version suffix dropped.
                    var name = p.Split(',')[0].ToLowerInvariant();
                    t.Args.Add("-Wl,--subsystem," + name);
                    continue;
                }
                if ((p = OptPayload(opt, "ENTRY")) != null)
                {
                    if (EqI(p, "wmainCRTStartup"))
                        t.Args.Add("-municode"); // MinGW CRT's wmainCRTStartup calls the bootstrapper's wmain
                    else if (!EqI(p, "mainCRTStartup"))
                        t.Args.Add("-Wl,--entry," + p);
                    continue;
                }
                if ((p = OptPayload(opt, "STACK")) != null)
                {
                    // /STACK:reserve[,commit] - lld sizes the commit itself.
                    var reserve = p.Split(',')[0];
                    t.Args.Add("-Wl,--stack," + reserve);
                    continue;
                }
                if ((p = OptPayload(opt, "INCLUDE")) != null) { t.Args.Add("-Wl,-u," + p); continue; }
                if (EqI(opt, "DEBUG") || OptPayload(opt, "DEBUG") != null)
                {
                    if (!debugEmitted) t.Args.Add("-g"); // lld writes <output-base>.pdb
                    debugEmitted = true;
                    continue;
                }
                if ((p = OptPayload(opt, "OPT")) != null)
                {
                    // /OPT:REF,ICF=2,... - a comma list; last mention wins,
                    // as with link.exe. LBR/NOLBR (arm thunk sorting) has no
                    // lld-link equivalent and is dropped.
                    foreach (var item in p.Split(','))
                    {
                        if (EqI(item, "REF")) t.OptRef = true;
                        else if (EqI(item, "NOREF")) t.OptRef = false;
                        else if (EqI(item, "ICF") || item.StartsWith("ICF=", StringComparison.OrdinalIgnoreCase)) t.OptIcf = true;
                        else if (EqI(item, "NOICF")) t.OptIcf = false;
                    }
                    continue;
                }
                if ((p = OptPayload(opt, "MERGE")) != null)
                {
                    var eq = p.IndexOf('=');
                    if (eq > 0)
                    {
                        var from = p.Substring(0, eq);
                        var to = p.Substring(eq + 1);
                        if (from.Length > 0 && to.Length > 0 && from != to)
                            t.Merges.Add((from, to));
                    }
                    continue;
                }
                if (IsDropped(opt)) continue;

                // Not a recognized option. MSVC options and absolute Unix paths
                // both start with '/': treat as an option (warn + drop) only
                // when it looks like one, otherwise as an input path.
                if (token[0] == '/' && !LooksLikeOption(opt)) { AppendInput(t, token); continue; }

                t.Warnings.Add($"[AotAnywhere link] Warning: dropping unsupported linker option '{token}'.");
                continue;
            }

            // Positional input. Bare import-library names (kernel32.lib) become
            // -l lookups into zig's bundled MinGW libs; anything with a path
            // stays a file input (the MSVC-built COFF archives link as-is).
            if (EndsWithI(token, ".lib") && token.IndexOfAny(new[] { '/', '\\' }) < 0)
            {
                var name = token.Substring(0, token.Length - ".lib".Length).ToLowerInvariant();
                t.Args.Add("-l" + name);
                continue;
            }

            AppendInput(t, token);
        }

        return t;
    }

    static void AppendInput(MsvcTranslation t, string token)
    {
        if (EndsWithI(token, ".obj") || EndsWithI(token, ".o"))
            t.ObjectInputs.Add(token);
        t.Args.Add(token);
    }

    /// "OUT:x" with name "OUT" gives "x"; case-insensitive; null when the name
    /// does not match or there is no payload.
    static string? OptPayload(string opt, string name)
    {
        if (opt.Length <= name.Length + 1) return null;
        if (!opt.Substring(0, name.Length).Equals(name, StringComparison.OrdinalIgnoreCase)) return null;
        if (opt[name.Length] != ':') return null;
        return opt.Substring(name.Length + 1);
    }

    static bool IsDropped(string opt)
    {
        foreach (var name in SilentlyDropped)
        {
            if (opt.Equals(name, StringComparison.OrdinalIgnoreCase)) return true;
            if (opt.Length > name.Length && opt[name.Length] == ':' &&
                opt.Substring(0, name.Length).Equals(name, StringComparison.OrdinalIgnoreCase))
                return true;
        }
        return false;
    }

    /// Heuristic separating unknown MSVC options from absolute Unix paths: an
    /// option is an alphabetic name, optionally followed by ':' and a payload;
    /// a path has more separators or non-alphabetic components.
    static bool LooksLikeOption(string opt)
    {
        var nameEnd = opt.IndexOf(':');
        if (nameEnd < 0) nameEnd = opt.Length;
        if (nameEnd == 0) return false;
        for (var i = 0; i < nameEnd; i++)
        {
            var c = opt[i];
            if (!((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z'))) return false;
        }
        return true;
    }

    static bool EqI(string a, string b) => a.Equals(b, StringComparison.OrdinalIgnoreCase);
    static bool EndsWithI(string s, string suffix) => s.EndsWith(suffix, StringComparison.OrdinalIgnoreCase);
}
