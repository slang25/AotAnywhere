namespace AotAnywhere.MSBuild.Tests;

// _AotAnywhereSelectToolPackageRids (ToolPack.targets) answers the SDK's
// ComputeToolPackageRuntimeIdentifiersToPack extensibility point
// (dotnet/sdk#55250): which of the requested RIDs can this host pack? With
// this package referenced, all of them. The target is executed directly by
// name so the tests run on SDKs that predate the extensibility point.
public class ToolPackRidSelectionTests
{
    const string Target = "_AotAnywhereSelectToolPackageRids";
    const string Item = "ToolPackageRuntimeIdentifiersToPack";

    const string AllRids =
        "linux-x64;linux-arm64;linux-arm;linux-musl-x64;linux-musl-arm64;linux-musl-arm;osx-x64;osx-arm64;win-x64;win-arm64";

    static Dictionary<string, string> Globals(
        string toolPackageRids = "",
        string runtimeIdentifiers = "",
        string createRidSpecificToolPackages = "true",
        string runtimeIdentifier = "") =>
        new()
        {
            ["ToolPackageRuntimeIdentifiers"] = toolPackageRids,
            ["RuntimeIdentifiers"] = runtimeIdentifiers,
            ["CreateRidSpecificToolPackages"] = createRidSpecificToolPackages,
            ["RuntimeIdentifier"] = runtimeIdentifier,
        };

    [Test]
    public async Task EmitsEveryRequestedRid()
    {
        var run = Harness.Run(Target, Globals(toolPackageRids: AllRids), Harness.ToolPackHarness);
        await Assert.That(run.Success).IsTrue();
        await Assert.That(string.Join(";", run.Items(Item))).IsEqualTo(AllRids);
    }

    [Test]
    public async Task FallsBackToRuntimeIdentifiers()
    {
        var run = Harness.Run(
            Target,
            Globals(runtimeIdentifiers: "linux-x64;osx-arm64"),
            Harness.ToolPackHarness);
        await Assert.That(run.Items(Item)).IsEquivalentTo(new[] { "linux-x64", "osx-arm64" });
    }

    [Test]
    public async Task ToolPackageRidsWinOverRuntimeIdentifiers()
    {
        var run = Harness.Run(
            Target,
            Globals(toolPackageRids: "win-arm64", runtimeIdentifiers: "linux-x64;osx-arm64"),
            Harness.ToolPackHarness);
        await Assert.That(run.Items(Item)).IsEquivalentTo(new[] { "win-arm64" });
    }

    // Not a RID-specific tool pack (property empty or false): stay out of the way.
    [Test]
    [Arguments("")]
    [Arguments("false")]
    public async Task InactiveWithoutRidSpecificToolPackaging(string createRidSpecificToolPackages)
    {
        var run = Harness.Run(
            Target,
            Globals(toolPackageRids: AllRids, createRidSpecificToolPackages: createRidSpecificToolPackages),
            Harness.ToolPackHarness);
        await Assert.That(run.Items(Item)).IsEmpty();
    }

    // Inner RID-specific pack builds compute nothing; only the outer build selects.
    [Test]
    public async Task InactiveInInnerRidSpecificBuild()
    {
        var run = Harness.Run(
            Target,
            Globals(toolPackageRids: AllRids, runtimeIdentifier: "linux-x64"),
            Harness.ToolPackHarness);
        await Assert.That(run.Items(Item)).IsEmpty();
    }

    [Test]
    public async Task OptOutRestoresSdkDefaults()
    {
        var globals = Globals(toolPackageRids: AllRids);
        globals["AotAnywhereMultiRidToolPackaging"] = "false";
        var run = Harness.Run(Target, globals, Harness.ToolPackHarness);
        await Assert.That(run.Items(Item)).IsEmpty();
    }

    // A user's evaluation-time ToolPackageRuntimeIdentifiersToPack items are
    // authoritative; the target must not append to them.
    [Test]
    public async Task PredefinedItemsAreRespected()
    {
        var globals = Globals(toolPackageRids: AllRids);
        globals["TestPredefinedToolPackRids"] = "osx-arm64;win-arm64";
        var run = Harness.Run(Target, globals, Harness.ToolPackHarness);
        await Assert.That(run.Items(Item)).IsEquivalentTo(new[] { "osx-arm64", "win-arm64" });
    }
}
