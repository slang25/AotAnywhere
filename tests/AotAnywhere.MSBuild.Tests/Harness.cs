using Microsoft.Build.Evaluation;
using Microsoft.Build.Execution;
using Microsoft.Build.Framework;

namespace AotAnywhere.MSBuild.Tests;

// Loads Harness.proj (which imports the package's real targets) through the
// MSBuild API, so tests can assert on evaluated properties and on the results
// of running individual targets with injected inputs. No zig, no ILCompiler
// restore, no linking - pure MSBuild evaluation/execution.
internal static class Harness
{
    static readonly string RepoRoot = FindRepoRoot();
    static readonly string SrcDir =
        Path.Combine(RepoRoot, "src") + Path.DirectorySeparatorChar;
    static readonly string HarnessProj =
        Path.Combine(RepoRoot, "tests", "AotAnywhere.MSBuild.Tests", "harness", "Harness.proj");
    public const string ToolPackHarness = "ToolPackHarness.proj";

    static string ProjPath(string? proj) =>
        proj is null ? HarnessProj
                     : Path.Combine(Path.GetDirectoryName(HarnessProj)!, proj);

    static string FindRepoRoot()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir is not null &&
               !File.Exists(Path.Combine(dir.FullName, "src", "Crosscompile.targets")))
            dir = dir.Parent;
        return dir?.FullName
            ?? throw new InvalidOperationException("could not locate the repo root (src/Crosscompile.targets)");
    }

    static Dictionary<string, string> Globals(IDictionary<string, string> globals) =>
        new(globals) { ["AotAnywhereSrcDir"] = SrcDir };

    // Evaluation only: the returned Project exposes file-scope properties
    // (activation flags, host detection) without running any target.
    public static Project Evaluate(IDictionary<string, string> globals)
    {
        var collection = new ProjectCollection(Globals(globals));
        return collection.LoadProject(HarnessProj);
    }

    public static string EvalProp(IDictionary<string, string> globals, string name) =>
        Evaluate(globals).GetPropertyValue(name);

    // ProjectInstance.Build drives the process-wide default BuildManager, which
    // rejects concurrent builds; TUnit runs tests in parallel, so serialize the
    // execution path. Evaluation (Evaluate/EvalProp) needs no lock.
    static readonly object BuildLock = new();

    // Executes a single target and returns its results (properties/items it set).
    // `proj` selects an alternate harness project (e.g. ToolPackHarness).
    public static RunResult Run(string target, IDictionary<string, string> globals, string? proj = null)
    {
        lock (BuildLock)
        {
            var collection = new ProjectCollection(Globals(globals));
            var instance = collection.LoadProject(ProjPath(proj)).CreateProjectInstance();
            var logger = new ErrorLogger();
            var success = instance.Build(new[] { target }, new ILogger[] { logger });
            return new RunResult(success, instance, logger.Errors);
        }
    }
}

internal sealed record RunResult(bool Success, ProjectInstance Instance, IReadOnlyList<string> Errors)
{
    public string Prop(string name) => Instance.GetPropertyValue(name);

    public string[] Items(string name) =>
        Instance.GetItems(name).Select(i => i.EvaluatedInclude).ToArray();

    public string ErrorText => Errors.Count == 0 ? "(no errors)" : string.Join("; ", Errors);
}

file sealed class ErrorLogger : ILogger
{
    public readonly List<string> Errors = new();
    public LoggerVerbosity Verbosity { get; set; } = LoggerVerbosity.Quiet;
    public string? Parameters { get; set; }

    public void Initialize(IEventSource eventSource) =>
        eventSource.ErrorRaised += (_, e) => Errors.Add(e.Message);

    public void Shutdown() { }
}
