using AotAnywhere.Tasks;

namespace AotAnywhere.MSBuild.Tests;

// The cache-dir resolution the /OPT re-link pass pins onto zig via
// ZIG_GLOBAL_CACHE_DIR/ZIG_LOCAL_CACHE_DIR. Both vars are always pinned:
// unpinned, zig cc roots its local cache at `.zig-cache` under the nearest
// ancestor directory holding a build.zig, so the glue object could surface in
// the printed lld-link line at a spaced path the aliasing never predicted
// (issue #67). Pure logic; the environment is injected.
public class ZigCacheDirsTests
{
    static Func<string, string?> Env(params (string Name, string Value)[] vars) =>
        name => vars.Where(v => v.Name == name).Select(v => v.Value).FirstOrDefault();

    [Test]
    public async Task ExplicitEnvVarsWinVerbatim()
    {
        var dirs = AotAnywhereWindowsLink.ResolveZigCacheDirs(Env(
            ("ZIG_GLOBAL_CACHE_DIR", "/g cache"),
            ("ZIG_LOCAL_CACHE_DIR", "/l cache"),
            ("HOME", "/home/u")));

        await Assert.That(dirs.Count).IsEqualTo(2);
        await Assert.That(dirs[0]).IsEqualTo(("ZIG_GLOBAL_CACHE_DIR", "/g cache"));
        await Assert.That(dirs[1]).IsEqualTo(("ZIG_LOCAL_CACHE_DIR", "/l cache"));
    }

    [Test]
    public async Task UnsetVarsResolveToXdgCacheHomeZig()
    {
        var dirs = AotAnywhereWindowsLink.ResolveZigCacheDirs(Env(
            ("XDG_CACHE_HOME", "/xdg"), ("HOME", "/home/u")));

        await Assert.That(dirs[0].Dir).IsEqualTo("/xdg/zig");
        await Assert.That(dirs[1].Dir).IsEqualTo("/xdg/zig");
    }

    [Test]
    public async Task UnsetVarsAndNoXdgResolveToHomeDotCacheZig()
    {
        var dirs = AotAnywhereWindowsLink.ResolveZigCacheDirs(Env(("HOME", "/home/u")));

        await Assert.That(dirs[0].Dir).IsEqualTo("/home/u/.cache/zig");
        await Assert.That(dirs[1].Dir).IsEqualTo("/home/u/.cache/zig");
    }

    [Test]
    public async Task LocalDefaultsToTheResolvedGlobalNotTheRawDefault()
    {
        // zig cc's own local fallback is the resolved global dir, so a global
        // override must carry the local cache with it.
        var dirs = AotAnywhereWindowsLink.ResolveZigCacheDirs(Env(
            ("ZIG_GLOBAL_CACHE_DIR", "/ci/zig-cache"), ("HOME", "/home/u")));

        await Assert.That(dirs[0].Dir).IsEqualTo("/ci/zig-cache");
        await Assert.That(dirs[1].Dir).IsEqualTo("/ci/zig-cache");
    }
}
