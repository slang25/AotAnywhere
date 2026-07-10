using AotAnywhere.Tasks;

namespace AotAnywhere.MSBuild.Tests;

// The spaced-path aliasing that keeps zig's unquoted verbose link line
// reconstructible for the /OPT re-link pass. Pure decision logic; symlink
// creation is recorded, not performed.
public class LinkPathAliaserTests
{
    const string Scratch = "/tmp/scratch";

    static (LinkPathAliaser Aliaser, List<(string Target, string Link)> Links) Make()
    {
        var links = new List<(string, string)>();
        return (new LinkPathAliaser(Scratch, (t, l) => links.Add((t, l))), links);
    }

    [Test]
    public async Task AliasesSpacedPathsOneSymlinkPerDirectoryAndLeavesTheRestAlone()
    {
        var (aliaser, links) = Make();
        var argv = new List<string>
        {
            "cc",
            "/my repo/obj/Hello.obj",
            "/my repo/obj/Hello.def",
            "/clean/bootstrapper.obj",
            "-lkernel32",
            "-Wl,--subsystem,console",
            "-L/my libs/stub",
            "--target=x86_64-windows-gnu",
        };

        var ok = aliaser.TryRewriteArgv(argv, out var aliasedOut, out var error);

        await Assert.That(ok).IsTrue();
        await Assert.That(error).IsNull();
        await Assert.That(aliasedOut).IsNull(); // no -o in this argv
        // Two files from the same spaced dir share one alias; d1 is the -L dir.
        await Assert.That(argv[1]).IsEqualTo($"{Scratch}/d0/Hello.obj");
        await Assert.That(argv[2]).IsEqualTo($"{Scratch}/d0/Hello.def");
        await Assert.That(argv[3]).IsEqualTo("/clean/bootstrapper.obj");
        await Assert.That(argv[4]).IsEqualTo("-lkernel32");
        await Assert.That(argv[6]).IsEqualTo($"-L{Scratch}/d1");
        await Assert.That(links.Count).IsEqualTo(2);
        await Assert.That(links[0].Target).IsEqualTo("/my repo/obj");
        await Assert.That(links[1].Target).IsEqualTo("/my libs/stub");
    }

    [Test]
    public async Task AliasesTheOutputDirectoryAndReportsTheNewOutPath()
    {
        var (aliaser, _) = Make();
        var argv = new List<string> { "cc", "-o", "/my repo/bin/Hello.exe", "in.obj" };

        var ok = aliaser.TryRewriteArgv(argv, out var aliasedOut, out var error);

        await Assert.That(ok).IsTrue();
        await Assert.That(error).IsNull();
        await Assert.That(aliasedOut).IsEqualTo($"{Scratch}/d0/Hello.exe");
        await Assert.That(argv[2]).IsEqualTo($"{Scratch}/d0/Hello.exe");
    }

    [Test]
    public async Task SpacedOutputFileNameIsTheOneUnfixableShape()
    {
        // Linking under an alias name and renaming after would desync the PDB
        // name embedded in the image, so this must refuse.
        var (aliaser, _) = Make();
        var argv = new List<string> { "cc", "-o", "/bin/My App.exe", "in.obj" };

        var ok = aliaser.TryRewriteArgv(argv, out _, out var error);

        await Assert.That(ok).IsFalse();
        await Assert.That(error!).Contains("My App.exe");
    }

    [Test]
    public async Task SpacedInputFileNameGetsAFileLevelSymlinkKeepingTheExtension()
    {
        var (aliaser, links) = Make();
        var argv = new List<string> { "cc", "/objs/my app.obj" };

        var ok = aliaser.TryRewriteArgv(argv, out _, out var error);

        await Assert.That(ok).IsTrue();
        await Assert.That(error).IsNull();
        await Assert.That(argv[1]).IsEqualTo($"{Scratch}/f0.obj");
        await Assert.That(links[0].Target).IsEqualTo("/objs/my app.obj");
    }

    [Test]
    public async Task RelativeSpacedPathsAliasTheirAbsoluteDirectory()
    {
        // Symlink targets must be absolute - a relative target would resolve
        // against the scratch dir, not the build's working directory.
        var (aliaser, links) = Make();
        var argv = new List<string> { "cc", "my dir/in.obj" };

        var ok = aliaser.TryRewriteArgv(argv, out _, out var error);

        await Assert.That(ok).IsTrue();
        await Assert.That(error).IsNull();
        await Assert.That(argv[1]).IsEqualTo($"{Scratch}/d0/in.obj");
        await Assert.That(links[0].Target).IsEqualTo(Path.GetFullPath("my dir"));
    }

    [Test]
    public async Task DirAliasIsReusedAcrossArgvAndCacheDirRequests()
    {
        var (aliaser, links) = Make();
        var argv = new List<string> { "cc", "/space d/in.obj" };
        aliaser.TryRewriteArgv(argv, out _, out _);

        var cacheAlias = aliaser.DirAlias("/space d");

        await Assert.That(cacheAlias).IsEqualTo($"{Scratch}/d0");
        await Assert.That(links.Count).IsEqualTo(1);
    }
}
