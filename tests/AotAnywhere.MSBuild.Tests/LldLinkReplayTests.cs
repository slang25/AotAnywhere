using AotAnywhere.Tasks;

namespace AotAnywhere.MSBuild.Tests;

// The `zig cc -v` lld-link line recovery behind the /OPT:REF,/OPT:ICF re-link
// pass. The line is space-joined with no quoting, so the parser must either
// reconstruct the argv faithfully or refuse loudly - never hand lld-link a
// shattered token stream. Pure logic; file existence is injected.
public class LldLinkReplayTests
{
    // Condensed from a real `zig cc -v` line for a win-x64 Hello link.
    const string Line =
        "lld-link -lldmingw -ERRORLIMIT:0 -NOLOGO -DEBUG -PDB:bin/native/Hello.pdb " +
        "-MLLVM:-float-abi=hard -STACK:16777216 -MACHINE:X64 -OUT:bin/native/Hello.exe " +
        "-IMPLIB:bin/native/glue.lib -LIBPATH:obj/native/stub-libs " +
        "obj/native/Hello.obj /cache/o/abc/crt2.obj /cache/o/def/libmingw32.lib";

    static readonly string[] Files =
    {
        "obj/native/Hello.obj", "/cache/o/abc/crt2.obj", "/cache/o/def/libmingw32.lib",
    };

    static Func<string, bool> Exists(params string[] extra) =>
        p => Files.Contains(p) || extra.Contains(p);

    // The task resolves relative paths against the (shared) process cwd; the
    // tests just need a pure normalizer.
    static string FullPath(string p) => p.StartsWith("/") ? p : "/cwd/" + p;

    [Test]
    public async Task FindsTheLldLinkLineAmongVerboseOutput()
    {
        var line = LldLinkReplay.FindLldLinkLine(new[]
        {
            "\"/tools/zig\" -cc1 -triple x86_64-unknown-windows-gnu glue.c",
            Line,
            "other stderr chatter",
        });
        await Assert.That(line).IsEqualTo(Line);
        await Assert.That(LldLinkReplay.FindLldLinkLine(new[] { "no link line" })).IsNull();
    }

    [Test]
    public async Task ParsesAFaithfulLineDroppingTheDriverToken()
    {
        var argv = LldLinkReplay.ParseArgv(Line, "bin/native/Hello.exe", Exists(), FullPath, out var error);

        await Assert.That(error).IsNull();
        await Assert.That(argv![0]).IsEqualTo("-lldmingw");
        await Assert.That(argv.Contains("lld-link")).IsFalse();
        await Assert.That(argv.Contains("-OUT:bin/native/Hello.exe")).IsTrue();
        await Assert.That(argv.Last()).IsEqualTo("/cache/o/def/libmingw32.lib");
    }

    [Test]
    public async Task ShatteredInputPathIsRefused()
    {
        // "obj/my app/Hello.obj" printed unquoted splits into two tokens; the
        // fragment does not exist and must fail the parse, not the link.
        var line = "lld-link -OUT:bin/Hello.exe obj/my app/Hello.obj";
        var argv = LldLinkReplay.ParseArgv(line, "bin/Hello.exe", Exists(), FullPath, out var error);

        await Assert.That(argv).IsNull();
        await Assert.That(error!).Contains("obj/my");
    }

    [Test]
    public async Task ShatteredOutPathIsRefused()
    {
        // A space in the -OUT: payload truncates it; the leftover fragment
        // even names a real file, so only the -OUT check catches this one.
        var line = "lld-link -OUT:bin/my app.exe obj/native/Hello.obj";
        var argv = LldLinkReplay.ParseArgv(line, "bin/my app.exe", Exists("app.exe"), FullPath, out var error);

        await Assert.That(argv).IsNull();
        await Assert.That(error!).Contains("does not match the requested output");
    }

    [Test]
    public async Task MissingOutOrForeignLineIsRefused()
    {
        var argv = LldLinkReplay.ParseArgv("lld-link -lldmingw obj/native/Hello.obj",
            "bin/Hello.exe", Exists(), FullPath, out var error);
        await Assert.That(argv).IsNull();
        await Assert.That(error!).Contains("no -OUT:");

        argv = LldLinkReplay.ParseArgv("ld.lld -o a.out", "a.out", Exists(), FullPath, out error);
        await Assert.That(argv).IsNull();
        await Assert.That(error!).Contains("does not start with 'lld-link'");
    }

    [Test]
    public async Task RelativeAndAbsoluteOutSpellingsMatchViaFullPath()
    {
        // zig echoing an absolutized -OUT: for a relative -o must still match.
        var line = "lld-link -OUT:/cwd/bin/Hello.exe obj/native/Hello.obj";
        var argv = LldLinkReplay.ParseArgv(line, "bin/Hello.exe", Exists(), FullPath, out var error);

        await Assert.That(error).IsNull();
        await Assert.That(argv).IsNotNull();
    }
}
