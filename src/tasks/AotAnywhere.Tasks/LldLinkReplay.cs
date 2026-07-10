namespace AotAnywhere.Tasks;

/// Recovers lld-link's argv from `zig cc -v` output so the Windows link task
/// can re-run the link with /OPT:REF and /OPT:ICF appended. zig cc has no way
/// to pass COFF /OPT flags through (its -Wl parser rejects --icf and swallows
/// --gc-sections for COFF, and it always hands lld-link -DEBUG, whose default
/// is OPT:NOREF,NOICF), so the task replays the printed invocation via the
/// `zig lld-link` subcommand instead. Pure logic; the process runs live in
/// AotAnywhereWindowsLink.
public static class LldLinkReplay
{
    /// The `lld-link ...` argv line zig prints to stderr under -v.
    public static string? FindLldLinkLine(IEnumerable<string> stderrLines)
    {
        foreach (var line in stderrLines)
            if (line.StartsWith("lld-link ", StringComparison.Ordinal))
                return line;
        return null;
    }

    /// Splits the verbose line back into argv. zig joins the args with single
    /// spaces and NO quoting, so a space inside any path shatters the token
    /// stream - and a bad replay must never pass silently (lld-link without
    /// /OUT would derive an output name and leave the unoptimized binary in
    /// place). Two checks make the parse trustworthy or loudly wrong:
    ///   - every non-option token must name an existing file (a shattered
    ///     path fragment does not);
    ///   - exactly one -OUT: must resolve to the path the link was asked to
    ///     produce (a payload truncated at a space does not).
    /// Returns the argv without the leading "lld-link", or null with an error.
    public static List<string>? ParseArgv(string line, string expectedOutPath,
        Func<string, bool> fileExists, Func<string, string> fullPath, out string? error)
    {
        var tokens = line.Split(new[] { ' ' }, StringSplitOptions.RemoveEmptyEntries);
        if (tokens.Length == 0 || tokens[0] != "lld-link")
        {
            error = "the captured line does not start with 'lld-link'";
            return null;
        }

        var argv = new List<string>();
        string? outPayload = null;
        for (var i = 1; i < tokens.Length; i++)
        {
            var token = tokens[i];
            if (token[0] == '-')
            {
                if (token.StartsWith("-OUT:", StringComparison.Ordinal))
                {
                    if (outPayload != null) { error = "more than one -OUT: token"; return null; }
                    outPayload = token.Substring("-OUT:".Length);
                }
                argv.Add(token);
                continue;
            }
            if (!fileExists(token))
            {
                error = $"input '{token}' does not exist - a path with a space in it, or a zig verbose-output change";
                return null;
            }
            argv.Add(token);
        }

        if (outPayload == null)
        {
            error = "no -OUT: token";
            return null;
        }
        if (fullPath(outPayload) != fullPath(expectedOutPath))
        {
            error = $"-OUT:{outPayload} does not match the requested output '{expectedOutPath}' - a path with a space in it, or a zig verbose-output change";
            return null;
        }

        error = null;
        return argv;
    }
}
