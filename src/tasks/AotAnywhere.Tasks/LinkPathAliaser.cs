namespace AotAnywhere.Tasks;

/// Rewrites link arguments whose paths contain spaces to go through space-free
/// symlink aliases under a scratch directory. The lld-link argv zig prints
/// under -v is space-joined with no quoting (see LldLinkReplay), so a space in
/// any path would make the /OPT re-link pass unreconstructible; aliasing the
/// paths keeps zig's printed line faithful, because zig echoes the paths it
/// was given verbatim (no realpath). Only reachable on non-Windows hosts,
/// where symlinks are dependable. Pure decision logic; symlink creation is
/// injected.
public sealed class LinkPathAliaser
{
    readonly string _scratchDir;
    readonly Action<string, string> _symlink; // (targetPath, linkPath)
    readonly Dictionary<string, string> _dirAliases = new(StringComparer.Ordinal);
    int _next;

    public LinkPathAliaser(string scratchDir, Action<string, string> symlink)
    {
        _scratchDir = scratchDir;
        _symlink = symlink;
    }

    public static bool HasSpace(string s) => s.IndexOf(' ') >= 0;

    /// Rewrites the zig cc argv in place. aliasedOut is the rewritten -o path
    /// when the output moved behind an alias (the -OUT: the replay must then
    /// expect), null when it did not. False with an error only for the one
    /// unfixable shape: a space in the output file NAME itself - the name is
    /// echoed into the PDB reference embedded in the image, so linking under
    /// an alias name and renaming afterwards would desync them.
    public bool TryRewriteArgv(IList<string> argv, out string? aliasedOut, out string? error)
    {
        aliasedOut = null;
        error = null;

        for (var i = 0; i < argv.Count; i++)
        {
            var arg = argv[i];

            if (arg == "-o" && i + 1 < argv.Count)
            {
                var outPath = argv[++i];
                if (!HasSpace(outPath)) continue;
                var name = Path.GetFileName(outPath);
                if (HasSpace(name))
                {
                    error = $"the output file name '{name}' itself contains a space";
                    return false;
                }
                argv[i] = aliasedOut = Path.Combine(DirAlias(ParentDir(outPath)), name);
                continue;
            }

            if (arg.StartsWith("-L", StringComparison.Ordinal))
            {
                var dir = arg.Substring(2);
                if (HasSpace(dir)) argv[i] = "-L" + DirAlias(dir);
                continue;
            }

            if (arg.Length == 0 || arg[0] == '-') continue; // non-path option
            if (!HasSpace(arg)) continue;

            // A positional input (object, archive, .def, the glue source).
            // Inputs are only read, so a file-level symlink is safe when the
            // file name itself carries the space.
            var fileName = Path.GetFileName(arg);
            argv[i] = HasSpace(fileName)
                ? FileAlias(arg)
                : Path.Combine(DirAlias(ParentDir(arg)), fileName);
        }

        return true;
    }

    /// One symlink per distinct directory: scratch/dN -> dir. Also used for
    /// zig's cache directories (their contents appear in the printed line).
    public string DirAlias(string dir)
    {
        var target = Path.GetFullPath(dir.Length == 0 ? "." : dir);
        if (_dirAliases.TryGetValue(target, out var alias)) return alias;
        alias = Path.Combine(_scratchDir, "d" + _next++);
        _symlink(target, alias);
        _dirAliases[target] = alias;
        return alias;
    }

    /// A file whose own name has a space gets a file-level symlink that keeps
    /// the extension (lld dispatches .def/.lib inputs on it).
    string FileAlias(string path)
    {
        var extension = Path.GetExtension(path).Replace(" ", "");
        var alias = Path.Combine(_scratchDir, "f" + _next++ + extension);
        _symlink(Path.GetFullPath(path), alias);
        return alias;
    }

    static string ParentDir(string path) => Path.GetDirectoryName(path) ?? "";
}
