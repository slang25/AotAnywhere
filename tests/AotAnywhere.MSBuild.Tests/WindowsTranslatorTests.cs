using AotAnywhere.Tasks;

namespace AotAnywhere.MSBuild.Tests;

// Ports the link_shim.zig translate() tests to the managed MsvcArgTranslator -
// the MSVC link.exe -> zig cc rewriting that would move into the Windows link
// task. Pure logic; no MSBuild, no linking.
public class WindowsTranslatorTests
{
    static string Lines(IEnumerable<string> xs) => string.Join("\n", xs);

    [Test]
    public async Task TokenizesRspLinesWithQuotes()
    {
        // The SDK's Windows CustomLinkerArg items are rsp lines: quoted, and a
        // single item may carry several tokens.
        var tokens = MsvcArgTranslator.Tokenize(new[]
        {
            "\"obj/native/Hello.obj\"",
            "/NOLOGO /MANIFEST:NO",
            "/NATVIS:\"/path with spaces/NativeAOT.natvis\"",
            "  ",
        });

        await Assert.That(Lines(tokens)).IsEqualTo(Lines(new[]
        {
            "obj/native/Hello.obj",
            "/NOLOGO",
            "/MANIFEST:NO",
            "/NATVIS:/path with spaces/NativeAOT.natvis",
        }));
    }

    [Test]
    public async Task TranslatesIlcWindowsResponseFile()
    {
        // Condensed from a real net10 link.rsp, plus the injected --target line.
        var t = MsvcArgTranslator.Translate(new[]
        {
            "obj/native/Hello.obj",
            "/OUT:bin/native/Hello.exe",
            "/DEF:obj/native/Hello.def",
            "/Users/u/.nuget/packages/pack/sdk/bootstrapper.obj",
            "/Users/u/.nuget/packages/pack/sdk/Runtime.WorkstationGC.lib",
            "advapi32.lib",
            "kernel32.lib",
            "/NOLOGO",
            "/MANIFEST:NO",
            "/MERGE:.managedcode=.text",
            "/MERGE:hydrated=.bss",
            "/DEBUG",
            "/INCREMENTAL:NO",
            "/SUBSYSTEM:CONSOLE",
            "/ENTRY:wmainCRTStartup",
            "/NOEXP",
            "/NOIMPLIB",
            "/STACK:1572864",
            "/NATVIS:/Users/u/.nuget/packages/ilc/build/NativeAOT.natvis",
            "/IGNORE:4104",
            "/CETCOMPAT",
            "/NODEFAULTLIB:libucrt.lib",
            "/DEFAULTLIB:ucrt.lib",
            "/OPT:REF",
            "/OPT:ICF",
            "--target=x86_64-windows-gnu",
        });

        await Assert.That(Lines(t.Args)).IsEqualTo(Lines(new[]
        {
            "obj/native/Hello.obj",
            "-o",
            "bin/native/Hello.exe",
            "obj/native/Hello.def",
            "/Users/u/.nuget/packages/pack/sdk/bootstrapper.obj",
            "/Users/u/.nuget/packages/pack/sdk/Runtime.WorkstationGC.lib",
            "-ladvapi32",
            "-lkernel32",
            "-g",
            "-Wl,--subsystem,console",
            "-municode",
            "-Wl,--stack,1572864",
            "--target=x86_64-windows-gnu",
        }));

        await Assert.That(t.SawTarget).IsTrue();
        await Assert.That(t.OutPath).IsEqualTo("bin/native/Hello.exe");
        await Assert.That(t.Warnings.Count).IsEqualTo(0);

        // /OPT never reaches the zig cc args - it is honored by the second
        // lld-link pass the task runs.
        await Assert.That(t.OptRef).IsTrue();
        await Assert.That(t.OptIcf).IsTrue();

        await Assert.That(Lines(t.Merges.Select(m => $"{m.From}={m.To}")))
            .IsEqualTo(".managedcode=.text\nhydrated=.bss");
        await Assert.That(Lines(t.ObjectInputs))
            .IsEqualTo("obj/native/Hello.obj\n/Users/u/.nuget/packages/pack/sdk/bootstrapper.obj");
    }

    [Test]
    public async Task TranslatesDllIncludeEntryLibpath()
    {
        var t = MsvcArgTranslator.Translate(new[]
        {
            "/DLL", "/OUT:bin/native/Lib.dll", "/INCLUDE:MyExport",
            "/ENTRY:MyStartup", "/LIBPATH:/opt/libs", "/SUBSYSTEM:WINDOWS,6.0",
        });

        await Assert.That(Lines(t.Args)).IsEqualTo(Lines(new[]
        {
            "-shared", "-o", "bin/native/Lib.dll", "-Wl,-u,MyExport",
            "-Wl,--entry,MyStartup", "-L/opt/libs", "-Wl,--subsystem,windows",
        }));
        await Assert.That(t.Warnings.Count).IsEqualTo(0);
    }

    [Test]
    public async Task MainCrtStartupNeedsNoFlagAndDebugEmitsSingleG()
    {
        var t = MsvcArgTranslator.Translate(new[] { "/ENTRY:mainCRTStartup", "/DEBUG:FULL", "/DEBUG" });
        await Assert.That(Lines(t.Args)).IsEqualTo("-g");
    }

    [Test]
    public async Task OptParsesCommaListsLastMentionWinsAndEmitsNoArgs()
    {
        // /OPT:REF,ICF=2 - comma list, ICF iteration count; LBR is dropped.
        var t = MsvcArgTranslator.Translate(new[] { "/OPT:REF,ICF=2,LBR" });
        await Assert.That(t.OptRef).IsTrue();
        await Assert.That(t.OptIcf).IsTrue();
        await Assert.That(t.Args.Count).IsEqualTo(0);
        await Assert.That(t.Warnings.Count).IsEqualTo(0);

        // Last mention wins, as with link.exe.
        t = MsvcArgTranslator.Translate(new[] { "/OPT:REF", "/OPT:ICF", "/OPT:NOICF,NOREF" });
        await Assert.That(t.OptRef).IsFalse();
        await Assert.That(t.OptIcf).IsFalse();
    }

    [Test]
    public async Task UnknownOptionsWarnAndDropAbsolutePathsPassThrough()
    {
        var t = MsvcArgTranslator.Translate(new[]
        {
            "/PROFILE", "/DELAYLOAD:foo.dll", "/Users/u/objs/thing.obj",
            "relative/path.lib", "UPPER.LIB",
        });

        await Assert.That(Lines(t.Args))
            .IsEqualTo("/Users/u/objs/thing.obj\nrelative/path.lib\n-lupper");
        await Assert.That(t.Warnings.Count).IsEqualTo(2);
    }
}
