//! link_shim.zig - link.exe personality of the AotAnywhere shim.
//!
//! When targeting Windows (win-x64, win-arm64) the ILC targets write an
//! MSVC-style response file and invoke `link @obj/.../link.rsp`. On
//! non-Windows hosts there is no MSVC, so Crosscompile.targets points
//! CppLinker at this personality instead. It expands the response file,
//! translates the MSVC linker options to their GNU-driver equivalents and
//! forwards the invocation to `zig cc -target <arch>-windows-gnu`, which
//! links with lld against the MinGW-w64 (UCRT) import libraries bundled
//! with zig.
//!
//! Two gaps between the MSVC-built NativeAOT runtime libraries and the
//! MinGW CRT are bridged on the fly:
//!
//!   - The objects carry /DEFAULTLIB directives for MSVC-only libraries
//!     (LIBCMT, OLDNAMES, libcpmt, uuid). Empty stub archives are written
//!     next to the response file so lld finds them; the MinGW CRT provides
//!     the actual C runtime.
//!   - A small glue source (compiled as part of the link) supplies the MSVC
//!     CRT symbols the MinGW CRT lacks: /GS stack-cookie support, the MSVC
//!     on-demand TLS init scheme, MSVC-mangled operator new/delete, and the
//!     arm64 out-of-line _Interlocked* helpers. See `glue_source` below.
//!
//! The target triple arrives as a `--target=<triple>` line that
//! Crosscompile.targets injects into the response file via LinkerArg.
//!
//! Run the unit tests with: zig test src/clang_shim.zig (this file is
//! covered through its import there) or directly: zig test src/link_shim.zig

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const Args = std.ArrayList([]const u8);

/// True when the multi-call binary was invoked under a link name (link,
/// link.exe, any path or casing). Matching is exact on the basename so
/// names like clang/llvm-objcopy can never trip it.
pub fn isLinkInvocation(argv0: []const u8) bool {
    var base = if (std.mem.lastIndexOfAny(u8, argv0, "/\\")) |sep| argv0[sep + 1 ..] else argv0;
    if (std.ascii.endsWithIgnoreCase(base, ".exe")) base = base[0 .. base.len - 4];
    return std.ascii.eqlIgnoreCase(base, "link");
}

/// Entry point when the shim is invoked as link. Never returns.
pub fn run(arena: Allocator, io: std.Io, args: []const []const u8, debug: bool) noreturn {
    const reader = IoFileReader{ .io = io };
    const tokens = expandResponseFiles(arena, reader, args, 0) catch |err|
        fatal(io, "cannot expand response files: {s}", .{@errorName(err)});

    var translation = translate(arena, tokens.items) catch |err|
        fatal(io, "cannot translate linker arguments: {s}", .{@errorName(err)});

    for (translation.warnings.items) |warning| say(io, "{s}", .{warning});
    if (!translation.saw_target)
        say(io, "Warning: no --target=<triple> argument was injected; linking for the host by mistake is likely.", .{});

    // The MSVC-glue support files live next to the response file (the native
    // intermediate directory), falling back to the output directory.
    const support_dir = tokens.rsp_dir orelse
        (if (translation.out_path) |out| std.fs.path.dirname(out) else null) orelse ".";

    applyMerges(arena, io, &translation, support_dir);
    const glue_path = writeSupportFiles(arena, io, support_dir) catch |err|
        fatal(io, "cannot write support files in '{s}': {s}", .{ support_dir, @errorName(err) });

    var argv: Args = .empty;
    argv.appendSlice(arena, &.{ "zig", "cc" }) catch |err| fatal(io, "out of memory: {s}", .{@errorName(err)});
    argv.appendSlice(arena, translation.args.items) catch |err| fatal(io, "out of memory: {s}", .{@errorName(err)});
    argv.append(arena, glue_path) catch |err| fatal(io, "out of memory: {s}", .{@errorName(err)});
    const stub_arg = std.fmt.allocPrint(arena, "-L{s}", .{
        std.fs.path.join(arena, &.{ support_dir, stub_dir_name }) catch |err|
            fatal(io, "out of memory: {s}", .{@errorName(err)}),
    }) catch |err| fatal(io, "out of memory: {s}", .{@errorName(err)});
    argv.append(arena, stub_arg) catch |err| fatal(io, "out of memory: {s}", .{@errorName(err)});

    if (debug) {
        say(io, "[DEBUG] Original args:", .{});
        for (args) |arg| say(io, "  '{s}'", .{arg});
        say(io, "[DEBUG] Final command:", .{});
        for (argv.items) |arg| say(io, "  '{s}'", .{arg});
    }

    execZigCc(io, argv.items);
}

// --- Response files ----------------------------------------------------------

/// Reads files through std.Io; tests substitute an in-memory reader.
const IoFileReader = struct {
    io: std.Io,

    fn read(self: IoFileReader, arena: Allocator, path: []const u8) ![]u8 {
        return std.Io.Dir.cwd().readFileAlloc(self.io, path, arena, .unlimited);
    }
};

const ExpandedTokens = struct {
    items: []const []const u8,
    /// Directory of the first response file, when one was used.
    rsp_dir: ?[]const u8,
};

/// Expands @file arguments into their tokenized contents. MSBuild writes the
/// response file as UTF-8 with a BOM, one or more space-separated (possibly
/// quoted) arguments per line.
fn expandResponseFiles(arena: Allocator, reader: anytype, args: []const []const u8, depth: usize) !ExpandedTokens {
    if (depth > 8) return error.ResponseFileRecursionTooDeep;

    var out: Args = .empty;
    var rsp_dir: ?[]const u8 = null;
    for (args) |arg| {
        if (arg.len > 1 and arg[0] == '@') {
            const path = arg[1..];
            var contents: []const u8 = try reader.read(arena, path);
            if (std.mem.startsWith(u8, contents, "\xEF\xBB\xBF")) {
                contents = contents[3..];
            } else if (std.mem.startsWith(u8, contents, "\xFF\xFE") or std.mem.startsWith(u8, contents, "\xFE\xFF")) {
                return error.Utf16ResponseFileUnsupported;
            }

            var line_tokens: Args = .empty;
            var lines = std.mem.splitScalar(u8, contents, '\n');
            while (lines.next()) |line| {
                try tokenizeLine(arena, std.mem.trimEnd(u8, line, "\r"), &line_tokens);
            }
            const inner = try expandResponseFiles(arena, reader, line_tokens.items, depth + 1);
            try out.appendSlice(arena, inner.items);
            if (rsp_dir == null) rsp_dir = std.fs.path.dirname(path) orelse ".";
            if (rsp_dir == null and inner.rsp_dir != null) rsp_dir = inner.rsp_dir;
        } else {
            try out.append(arena, arg);
        }
    }
    return .{ .items = out.items, .rsp_dir = rsp_dir };
}

/// Splits one response file line into arguments: whitespace separates,
/// double quotes group (also mid-token, as in /NATVIS:"path with spaces").
fn tokenizeLine(arena: Allocator, line: []const u8, out: *Args) !void {
    var token: std.ArrayList(u8) = .empty;
    var in_token = false;
    var in_quotes = false;
    for (line) |c| {
        if (c == '"') {
            in_quotes = !in_quotes;
            in_token = true;
            continue;
        }
        if (!in_quotes and (c == ' ' or c == '\t')) {
            if (in_token) {
                try out.append(arena, try token.toOwnedSlice(arena));
                in_token = false;
            }
            continue;
        }
        try token.append(arena, c);
        in_token = true;
    }
    if (in_token) try out.append(arena, try token.toOwnedSlice(arena));
}

// --- Translation -------------------------------------------------------------

const Merge = struct {
    from: []const u8,
    to: []const u8,
};

const Translation = struct {
    /// zig cc arguments, in input order.
    args: Args = .empty,
    warnings: Args = .empty,
    out_path: ?[]const u8 = null,
    saw_target: bool = false,
    /// /MERGE:from=to requests, honored by renaming sections in the input
    /// objects (zig cc cannot pass /MERGE through to lld).
    merges: std.ArrayList(Merge) = .empty,
    /// Positional inputs that are loose object files (candidates for the
    /// section renames above; /MERGE sections only occur in ILC's output).
    object_inputs: Args = .empty,
};

/// MSVC options that have no effect on (or no equivalent in) an lld MinGW
/// link and are dropped without a warning. Matched on the option name alone
/// or the name followed by ':'.
const silently_dropped = [_][]const u8{
    "NOLOGO",      "MANIFEST",          "MANIFESTUAC", "MANIFESTFILE", "INCREMENTAL",
    "NOEXP",       "NOIMPLIB",          "IGNORE",      "NATVIS",       "SOURCELINK",
    "CETCOMPAT",   "GUARD",             "SAFESEH",     "NODEFAULTLIB", "DEFAULTLIB",
    "MACHINE",     "PDB",               "PDBALTPATH",  "BASE",         "DYNAMICBASE",
    "NXCOMPAT",    "HIGHENTROPYVA",     "FIXED",       "TSAWARE",      "MAP",
    "VERBOSE",     "WX",                "TIME",        "ERRORREPORT",  "LARGEADDRESSAWARE",
    "RELEASE",     "DEBUGTYPE",
};

/// Translates MSVC link.exe arguments to `zig cc` arguments. Pure argument
/// rewriting; support-file emission and process launch live in `run`.
fn translate(arena: Allocator, tokens: []const []const u8) !Translation {
    var t: Translation = .{};
    var debug_emitted = false;

    for (tokens) |token| {
        if (token.len == 0) continue;

        // The target triple line Crosscompile.targets injects via LinkerArg.
        if (std.mem.startsWith(u8, token, "--target=")) {
            try t.args.append(arena, token);
            t.saw_target = true;
            continue;
        }

        if (token[0] == '/' or token[0] == '-') {
            const opt = token[1..];
            if (optPayload(opt, "OUT")) |out| {
                try t.args.appendSlice(arena, &.{ "-o", out });
                t.out_path = out;
                continue;
            }
            if (optPayload(opt, "DEF")) |def| {
                // lld accepts a module-definition file as a regular input.
                try t.args.append(arena, def);
                continue;
            }
            if (std.ascii.eqlIgnoreCase(opt, "DLL")) {
                try t.args.append(arena, "-shared");
                continue;
            }
            if (optPayload(opt, "LIBPATH")) |dir| {
                try t.args.append(arena, try std.fmt.allocPrint(arena, "-L{s}", .{dir}));
                continue;
            }
            if (optPayload(opt, "SUBSYSTEM")) |subsystem| {
                // /SUBSYSTEM:CONSOLE[,major[.minor]] - version suffix dropped.
                const name = subsystem[0 .. std.mem.indexOfScalar(u8, subsystem, ',') orelse subsystem.len];
                const lower = try std.ascii.allocLowerString(arena, name);
                try t.args.append(arena, try std.fmt.allocPrint(arena, "-Wl,--subsystem,{s}", .{lower}));
                continue;
            }
            if (optPayload(opt, "ENTRY")) |entry| {
                if (std.ascii.eqlIgnoreCase(entry, "wmainCRTStartup")) {
                    // The MinGW CRT provides its own wmainCRTStartup (which
                    // calls the wmain the NativeAOT bootstrapper defines);
                    // -municode swaps it in.
                    try t.args.append(arena, "-municode");
                } else if (!std.ascii.eqlIgnoreCase(entry, "mainCRTStartup")) {
                    try t.args.append(arena, try std.fmt.allocPrint(arena, "-Wl,--entry,{s}", .{entry}));
                }
                continue;
            }
            if (optPayload(opt, "STACK")) |stack| {
                // /STACK:reserve[,commit] - lld sizes the commit itself.
                const reserve = stack[0 .. std.mem.indexOfScalar(u8, stack, ',') orelse stack.len];
                try t.args.append(arena, try std.fmt.allocPrint(arena, "-Wl,--stack,{s}", .{reserve}));
                continue;
            }
            if (optPayload(opt, "INCLUDE")) |symbol| {
                try t.args.append(arena, try std.fmt.allocPrint(arena, "-Wl,-u,{s}", .{symbol}));
                continue;
            }
            if (std.ascii.eqlIgnoreCase(opt, "DEBUG") or optPayload(opt, "DEBUG") != null) {
                if (!debug_emitted) try t.args.append(arena, "-g"); // lld writes <output-base>.pdb
                debug_emitted = true;
                continue;
            }
            if (optPayload(opt, "OPT")) |what| {
                if (std.ascii.eqlIgnoreCase(what, "REF"))
                    try t.args.append(arena, "-Wl,--gc-sections");
                continue; // ICF and friends: lld's defaults apply
            }
            if (optPayload(opt, "MERGE")) |spec| {
                // Honored via section renames in the input objects; see
                // applyMerges.
                if (std.mem.indexOfScalar(u8, spec, '=')) |eq| {
                    const from = spec[0..eq];
                    const to = spec[eq + 1 ..];
                    if (from.len > 0 and to.len > 0 and !std.mem.eql(u8, from, to))
                        try t.merges.append(arena, .{ .from = from, .to = to });
                }
                continue;
            }
            if (isDropped(opt)) continue;

            // Not a recognized option. MSVC options and absolute Unix paths
            // both start with '/': treat it as an option (warn and drop) only
            // when it looks like one - a leading alphabetic name followed by
            // ':' or nothing - and as an input path otherwise.
            if (token[0] == '/' and !looksLikeOption(opt)) {
                try appendInput(arena, &t, token);
                continue;
            }
            try t.warnings.append(arena, try std.fmt.allocPrint(arena, "[link shim] Warning: dropping unsupported linker option '{s}'.", .{token}));
            continue;
        }

        // Positional input. Bare import-library names (kernel32.lib) become
        // -l lookups into zig's bundled MinGW libs; anything with a path
        // stays a file input (the MSVC-built COFF archives link as-is).
        if (std.ascii.endsWithIgnoreCase(token, ".lib") and std.mem.indexOfAny(u8, token, "/\\") == null) {
            const base = token[0 .. token.len - ".lib".len];
            try t.args.append(arena, try std.fmt.allocPrint(arena, "-l{s}", .{try std.ascii.allocLowerString(arena, base)}));
            continue;
        }
        try appendInput(arena, &t, token);
    }

    return t;
}

/// Records a file input, remembering loose object files as candidates for
/// the /MERGE section renames.
fn appendInput(arena: Allocator, t: *Translation, token: []const u8) !void {
    if (std.ascii.endsWithIgnoreCase(token, ".obj") or std.ascii.endsWithIgnoreCase(token, ".o"))
        try t.object_inputs.append(arena, token);
    try t.args.append(arena, token);
}

/// "OUT:x" with name "OUT" gives "x"; case-insensitive; null when the
/// option name does not match or has no payload.
fn optPayload(opt: []const u8, comptime name: []const u8) ?[]const u8 {
    if (opt.len <= name.len + 1) return null;
    if (!std.ascii.eqlIgnoreCase(opt[0..name.len], name)) return null;
    if (opt[name.len] != ':') return null;
    return opt[name.len + 1 ..];
}

fn isDropped(opt: []const u8) bool {
    for (silently_dropped) |name| {
        if (std.ascii.eqlIgnoreCase(opt, name)) return true;
        if (opt.len > name.len and opt[name.len] == ':' and std.ascii.eqlIgnoreCase(opt[0..name.len], name)) return true;
    }
    return false;
}

/// Heuristic separating unknown MSVC options from absolute Unix paths:
/// an option is an alphabetic name, optionally followed by ':' and a
/// payload; a path has more separators or non-alphabetic components.
fn looksLikeOption(opt: []const u8) bool {
    const name_end = std.mem.indexOfScalar(u8, opt, ':') orelse opt.len;
    if (name_end == 0) return false;
    for (opt[0..name_end]) |c| {
        if (!std.ascii.isAlphabetic(c)) return false;
    }
    return true;
}

// --- /MERGE via COFF section renames -------------------------------------------

/// zig cc cannot pass /MERGE through to lld, so the shim implements the
/// option where it is actually needed: the merged sections (.managedcode,
/// hydrated) only occur in the ILC-produced objects. Renaming them
/// (from -> to, including $-grouped variants like .managedcode$I ->
/// .text$I) makes lld combine them into the target output section, which
/// is what link.exe's /MERGE produces. Input objects are never modified -
/// some live in the shared NuGet cache (bootstrapper.obj) - so any object
/// needing a rename is copied into the support directory and the linker
/// argument is redirected to the copy.
fn applyMerges(arena: Allocator, io: std.Io, t: *Translation, support_dir: []const u8) void {
    if (t.merges.items.len == 0) return;
    for (t.object_inputs.items, 0..) |path, index| {
        const data = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited) catch |err| {
            say(io, "[link shim] Warning: skipping /MERGE for '{s}': {s}", .{ path, @errorName(err) });
            continue;
        };
        var total: RenameResult = .{};
        for (t.merges.items) |merge| {
            const result = renameCoffSections(data, merge.from, merge.to);
            total.renamed += result.renamed;
            total.skipped_long += result.skipped_long;
            total.skipped_initialized += result.skipped_initialized;
        }
        if (total.skipped_long > 0)
            say(io, "[link shim] Warning: {d} section(s) in '{s}' not merged (target name over 8 chars).", .{ total.skipped_long, path });
        if (total.skipped_initialized > 0)
            say(io, "[link shim] Warning: {d} initialized section(s) in '{s}' not merged into .bss.", .{ total.skipped_initialized, path });
        if (total.renamed == 0) continue;

        // The index prefix keeps same-named objects from different
        // directories apart.
        const copy_name = std.fmt.allocPrint(arena, "aotanywhere-merged-{d}-{s}", .{ index, std.fs.path.basename(path) }) catch return;
        const copy_path = std.fs.path.join(arena, &.{ support_dir, copy_name }) catch return;
        writeFileReplacing(arena, io, copy_path, data) catch |err| {
            // The original stays in the link, just without the merge.
            say(io, "[link shim] Warning: could not write merged copy of '{s}': {s}", .{ path, @errorName(err) });
            continue;
        };
        for (t.args.items) |*arg| {
            if (std.mem.eql(u8, arg.*, path)) arg.* = copy_path;
        }
        say(io, "[link shim] /MERGE: renamed {d} section(s); linking {s} in place of {s}.", .{ total.renamed, copy_path, path });
    }
}

const RenameResult = struct {
    renamed: u32 = 0,
    /// Sections whose renamed name would not fit the 8-byte inline field
    /// (adding string-table entries would mean relayouting the file).
    skipped_long: u32 = 0,
    /// Initialized sections that /MERGE wanted in .bss; renaming those
    /// would silently grow the uninitialized image, so they stay put.
    skipped_initialized: u32 = 0,
};

const IMAGE_SCN_CNT_UNINITIALIZED_DATA: u32 = 0x80;

/// Renames COFF sections named `from` (or `from$suffix`) to `to` (keeping
/// the suffix) directly in the object image. Malformed or non-object
/// inputs (import-library members, resources) are left untouched.
fn renameCoffSections(data: []u8, from: []const u8, to: []const u8) RenameResult {
    var result: RenameResult = .{};
    if (data.len < 20) return result;
    const machine = rd16(data, 0);
    if (machine == 0 or machine == 0xffff) return result; // anonymous/import object
    const section_count = rd16(data, 2);
    const symtab_offset = rd32(data, 8);
    const symbol_count = rd32(data, 12);
    const opt_header_size = rd16(data, 16);
    const strtab_offset: usize = if (symtab_offset != 0) symtab_offset + @as(usize, symbol_count) * 18 else 0;

    var i: usize = 0;
    while (i < section_count) : (i += 1) {
        const header = 20 + @as(usize, opt_header_size) + i * 40;
        if (header + 40 > data.len) return result;
        const name = coffSectionName(data, header, strtab_offset) orelse continue;

        var suffix: []const u8 = "";
        if (!std.mem.eql(u8, name, from)) {
            if (name.len <= from.len or !std.mem.startsWith(u8, name, from) or name[from.len] != '$') continue;
            suffix = name[from.len..];
        }

        if (to.len + suffix.len > 8) {
            result.skipped_long += 1;
            continue;
        }
        const characteristics = rd32(data, header + 36);
        if (std.mem.eql(u8, to, ".bss") and characteristics & IMAGE_SCN_CNT_UNINITIALIZED_DATA == 0) {
            result.skipped_initialized += 1;
            continue;
        }

        @memset(data[header..][0..8], 0);
        std.mem.copyForwards(u8, data[header..][0..to.len], to);
        std.mem.copyForwards(u8, data[header + to.len ..][0..suffix.len], suffix);
        result.renamed += 1;
    }
    return result;
}

/// Resolves a section header's name: inline (nul-padded, up to 8 bytes) or
/// a "/nnn" decimal offset into the string table. Null when unparseable.
fn coffSectionName(data: []const u8, header: usize, strtab_offset: usize) ?[]const u8 {
    const raw = data[header..][0..8];
    if (raw[0] == '/') {
        const digits = std.mem.sliceTo(raw[1..], 0);
        const offset = std.fmt.parseInt(u32, digits, 10) catch return null;
        if (strtab_offset == 0) return null;
        const start = strtab_offset + offset;
        if (start >= data.len) return null;
        const rest = data[start..];
        return rest[0 .. std.mem.indexOfScalar(u8, rest, 0) orelse return null];
    }
    return std.mem.sliceTo(raw, 0);
}

fn rd16(data: []const u8, offset: usize) u16 {
    return std.mem.readInt(u16, data[offset..][0..2], .little);
}

fn rd32(data: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, data[offset..][0..4], .little);
}

/// Writes via a temp file + rename so an interrupted run never leaves a
/// truncated object behind for an incremental build to pick up.
fn writeFileReplacing(arena: Allocator, io: std.Io, path: []const u8, data: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    const tmp_path = try std.fmt.allocPrint(arena, "{s}.aotanywhere-tmp", .{path});
    {
        const file = try cwd.createFile(io, tmp_path, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, data);
    }
    try cwd.rename(tmp_path, cwd, path, io);
}

// --- Support files -----------------------------------------------------------

const glue_file_name = "aotanywhere-msvc-glue.c";
const stub_dir_name = "aotanywhere-msvc-stub-libs";

/// The MSVC objects carry /DEFAULTLIB directives for these MSVC-only
/// libraries. Empty archives satisfy the directive; the MinGW CRT and the
/// glue source provide the symbols instead. (lld's MinGW driver searches
/// the lib<name>.a spelling, preserving the directive's case.)
const stub_lib_names = [_][]const u8{ "libLIBCMT.a", "libOLDNAMES.a", "liblibcpmt.a", "libuuid.a" };
const empty_archive = "!<arch>\n";

/// Writes the glue source and the stub archive directory into support_dir;
/// returns the glue source path to add to the link.
fn writeSupportFiles(arena: Allocator, io: std.Io, support_dir: []const u8) ![]const u8 {
    const cwd = std.Io.Dir.cwd();

    const stub_dir = try std.fs.path.join(arena, &.{ support_dir, stub_dir_name });
    try cwd.createDirPath(io, stub_dir);
    for (stub_lib_names) |name| {
        const path = try std.fs.path.join(arena, &.{ stub_dir, name });
        const file = try cwd.createFile(io, path, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, empty_archive);
    }

    const glue_path = try std.fs.path.join(arena, &.{ support_dir, glue_file_name });
    const glue = try cwd.createFile(io, glue_path, .{});
    defer glue.close(io);
    try glue.writeStreamingAll(io, glue_source);
    return glue_path;
}

// --- Process launch ----------------------------------------------------------

fn say(io: std.Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
    std.Io.File.stdout().writeStreamingAll(io, msg) catch {};
}

fn fatal(io: std.Io, comptime fmt: []const u8, args: anytype) noreturn {
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "link (AotAnywhere shim): error: " ++ fmt ++ "\n", args) catch
        "link (AotAnywhere shim): error\n";
    std.Io.File.stderr().writeStreamingAll(io, msg) catch {};
    std.process.exit(1);
}

fn execZigCc(io: std.Io, argv: []const []const u8) noreturn {
    if (std.process.can_replace) {
        // Replace the process image so zig's exit code (or signal) is
        // observed directly by the caller.
        const err = std.process.replace(io, .{ .argv = argv });
        reportSpawnError(err);
    } else run: {
        // Windows: spawn zig and forward its exit code.
        var child = std.process.spawn(io, .{ .argv = argv }) catch |err| {
            reportSpawnError(err);
            break :run;
        };
        const term = child.wait(io) catch |err| {
            reportSpawnError(err);
            break :run;
        };
        switch (term) {
            .exited => |code| std.process.exit(code),
            else => std.process.exit(1),
        }
    }
    std.process.exit(127);
}

fn reportSpawnError(err: anyerror) void {
    if (err == error.FileNotFound) {
        std.debug.print("Error: zig is not on the PATH.\n", .{});
    } else {
        std.debug.print("Error: failed to run zig: {s}\n", .{@errorName(err)});
    }
}

// --- MSVC glue ---------------------------------------------------------------

/// Compiled into every Windows link (zig cc compiles it alongside the
/// objects). Bridges what the MSVC-built NativeAOT runtime libraries expect
/// from the MSVC CRT onto the MinGW CRT. Verified against the .NET 8 and
/// .NET 10 runtime packs for win-x64 and win-arm64.
const glue_source =
    \\/* Generated by the AotAnywhere link shim.
    \\   Glue for linking MSVC-built NativeAOT runtime libs with the MinGW CRT. */
    \\#include <stdlib.h>
    \\#include <stdint.h>
    \\
    \\/* MSVC /GS stack cookie support (normally in LIBCMT). Starts at MSVC's
    \\   default value and is randomized by an initializer below. */
    \\uintptr_t __security_cookie = 0x00002B992DDFA232ULL;
    \\uintptr_t __security_cookie_complement = ~0x00002B992DDFA232ULL;
    \\
    \\void __security_check_cookie(uintptr_t cookie)
    \\{
    \\    if (cookie != __security_cookie)
    \\        __builtin_trap();
    \\}
    \\
    \\/* Randomize the cookie like MSVC's __security_init_cookie. Registered in
    \\   .CRT$XCAA - the first C++-init slot, which the MinGW CRT runs via
    \\   _initterm(__xc_a, __xc_z) before any MSVC-built initializer and before
    \\   wmain - so no /GS-protected frame is ever live across the change.
    \\   RtlGenRandom's exported name is SystemFunction036 (advapi32, already
    \\   linked). MSVC keeps the top 16 bits clear on 64-bit so the cookie can
    \\   never alias a canonical pointer. */
    \\int __stdcall SystemFunction036(void *, unsigned long);
    \\
    \\static void aa_init_security_cookie(void)
    \\{
    \\    uintptr_t cookie = 0;
    \\    if (!SystemFunction036(&cookie, sizeof cookie)) {
    \\        cookie = (uintptr_t)&cookie;
    \\        cookie ^= (uintptr_t)__builtin_readcyclecounter();
    \\    }
    \\    cookie &= (uintptr_t)0x0000FFFFFFFFFFFFULL;
    \\    if (cookie == 0 || cookie == 0x00002B992DDFA232ULL)
    \\        cookie = 0x00002B992DDFA232ULL ^ (uintptr_t)&cookie;
    \\    __security_cookie = cookie;
    \\    __security_cookie_complement = ~cookie;
    \\}
    \\
    \\typedef void (*aa_initializer)(void);
    \\__attribute__((section(".CRT$XCAA"), used))
    \\static aa_initializer aa_init_security_cookie_entry = aa_init_security_cookie;
    \\
    \\/* SEH personality for /GS frames, referenced from unwind data. The real one
    \\   validates the cookie during unwind; continuing the search preserves EH
    \\   semantics. EXCEPTION_DISPOSITION ExceptionContinueSearch == 1. */
    \\int __GSHandlerCheck(void *rec, void *frame, void *ctx, void *disp)
    \\{
    \\    (void)rec; (void)frame; (void)ctx; (void)disp;
    \\    return 1;
    \\}
    \\
    \\/* MSVC marker symbol pulled in by objects using floating point. */
    \\int _fltused = 0x9875;
    \\
    \\/* MSVC ISA dispatch level (normally set by CRT startup). 0 selects the
    \\   baseline paths in MSVC-compiled dispatch code, which is always safe. */
    \\int __isa_available = 0;
    \\
    \\/* MSVC stack range check failure (emitted for large local arrays). */
    \\__attribute__((noreturn)) void __report_rangecheckfailure(void)
    \\{
    \\    __builtin_trap();
    \\}
    \\
    \\/* MSVC 2019+ on-demand TLS init scheme (/Zc:tlsGuards). The guard is itself
    \\   thread-local; initializing it to 1 marks TLS as "already initialized" in
    \\   every thread, so the on-demand path never runs. The NativeAOT runtime's
    \\   thread-locals have no dynamic initializers, so nothing is lost. */
    \\__thread char __tls_guard = 1;
    \\
    \\void __dyn_tls_on_demand_init(void)
    \\{
    \\}
    \\
    \\#if defined(__x86_64__)
    \\/* Control Flow Guard dispatch fallback: mingw's cfguard support object takes
    \\   the address of this dummy, but zig's mingw bundle does not provide it.
    \\   When no CFG-aware loader rewrites the pointer, dispatch jumps to the
    \\   target address (x64: rax, arm64: x15). */
    \\__attribute__((naked)) void __guard_dispatch_icall_dummy(void)
    \\{
    \\    __asm__("jmpq *%rax");
    \\}
    \\#elif defined(__aarch64__)
    \\__attribute__((naked)) void __guard_dispatch_icall_dummy(void)
    \\{
    \\    __asm__("br x15");
    \\}
    \\#endif
    \\
    \\#if defined(__aarch64__)
    \\/* MSVC arm64 emits out-of-line calls for these Interlocked helpers (x64
    \\   always inlines them). They interoperate with inlined ldaxp/stlxp
    \\   sequences elsewhere, so they must be genuinely lock-free; on aarch64
    \\   the __atomic builtins compile to inline exclusive-pair loops. */
    \\long _InterlockedAnd(volatile long *p, long v) { return __atomic_fetch_and(p, v, __ATOMIC_SEQ_CST); }
    \\long _InterlockedOr(volatile long *p, long v) { return __atomic_fetch_or(p, v, __ATOMIC_SEQ_CST); }
    \\long _InterlockedXor(volatile long *p, long v) { return __atomic_fetch_xor(p, v, __ATOMIC_SEQ_CST); }
    \\long _InterlockedExchange(volatile long *p, long v) { return __atomic_exchange_n(p, v, __ATOMIC_SEQ_CST); }
    \\long _InterlockedExchangeAdd(volatile long *p, long v) { return __atomic_fetch_add(p, v, __ATOMIC_SEQ_CST); }
    \\long _InterlockedIncrement(volatile long *p) { return __atomic_add_fetch(p, 1, __ATOMIC_SEQ_CST); }
    \\long _InterlockedDecrement(volatile long *p) { return __atomic_sub_fetch(p, 1, __ATOMIC_SEQ_CST); }
    \\long _InterlockedCompareExchange(volatile long *p, long exch, long cmp)
    \\{
    \\    __atomic_compare_exchange_n(p, &cmp, exch, 0, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST);
    \\    return cmp;
    \\}
    \\long long _InterlockedExchange64(volatile long long *p, long long v) { return __atomic_exchange_n(p, v, __ATOMIC_SEQ_CST); }
    \\long long _InterlockedExchangeAdd64(volatile long long *p, long long v) { return __atomic_fetch_add(p, v, __ATOMIC_SEQ_CST); }
    \\long long _InterlockedAnd64(volatile long long *p, long long v) { return __atomic_fetch_and(p, v, __ATOMIC_SEQ_CST); }
    \\long long _InterlockedOr64(volatile long long *p, long long v) { return __atomic_fetch_or(p, v, __ATOMIC_SEQ_CST); }
    \\long long _InterlockedIncrement64(volatile long long *p) { return __atomic_add_fetch(p, 1, __ATOMIC_SEQ_CST); }
    \\long long _InterlockedDecrement64(volatile long long *p) { return __atomic_sub_fetch(p, 1, __ATOMIC_SEQ_CST); }
    \\long long _InterlockedCompareExchange64(volatile long long *p, long long exch, long long cmp)
    \\{
    \\    __atomic_compare_exchange_n(p, &cmp, exch, 0, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST);
    \\    return cmp;
    \\}
    \\void *_InterlockedExchangePointer(void *volatile *p, void *v) { return __atomic_exchange_n(p, v, __ATOMIC_SEQ_CST); }
    \\void *_InterlockedCompareExchangePointer(void *volatile *p, void *exch, void *cmp)
    \\{
    \\    __atomic_compare_exchange_n(p, &cmp, exch, 0, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST);
    \\    return cmp;
    \\}
    \\
    \\unsigned char _InterlockedCompareExchange128(volatile long long *dst,
    \\    long long exch_high, long long exch_low, long long *comparand)
    \\{
    \\    unsigned __int128 cmp = ((unsigned __int128)(unsigned long long)comparand[1] << 64)
    \\                          | (unsigned long long)comparand[0];
    \\    unsigned __int128 exch = ((unsigned __int128)(unsigned long long)exch_high << 64)
    \\                           | (unsigned long long)exch_low;
    \\    unsigned __int128 old = cmp;
    \\    int ok = __atomic_compare_exchange_n((unsigned __int128 *)dst, &old, exch, 0,
    \\                                         __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST);
    \\    comparand[0] = (long long)(unsigned long long)old;
    \\    comparand[1] = (long long)(unsigned long long)(old >> 64);
    \\    return (unsigned char)ok;
    \\}
    \\
    \\/* MSVC arm64 /GS prologue/epilogue helpers (crt/arm64/secpushpop.asm): the
    \\   callee allocates a 16-byte slot holding (sp - __security_cookie) and the
    \\   caller relies on that exact sp adjustment. x16/x17 are the only scratch
    \\   registers safe here. */
    \\__asm__(
    \\    "  .text\n"
    \\    "  .globl __security_push_cookie\n"
    \\    "__security_push_cookie:\n"
    \\    "  sub  sp, sp, #16\n"
    \\    "  adrp x17, __security_cookie\n"
    \\    "  ldr  x17, [x17, :lo12:__security_cookie]\n"
    \\    "  sub  x17, sp, x17\n"
    \\    "  str  x17, [sp, #8]\n"
    \\    "  ret\n"
    \\    "  .globl __security_pop_cookie\n"
    \\    "__security_pop_cookie:\n"
    \\    "  adrp x17, __security_cookie\n"
    \\    "  ldr  x16, [sp, #8]\n"
    \\    "  ldr  x17, [x17, :lo12:__security_cookie]\n"
    \\    "  sub  x16, sp, x16\n"
    \\    "  cmp  x16, x17\n"
    \\    "  b.ne 1f\n"
    \\    "  add  sp, sp, #16\n"
    \\    "  ret\n"
    \\    "1:\n"
    \\    "  brk  #0xF001\n");
    \\#endif
    \\
    \\/* MSVC-mangled C++ operator new/delete and std::nothrow (normally from the
    \\   MSVC C++ runtime), backed by the MinGW CRT heap. */
    \\void *aa_msvc_new(size_t) __asm__("??2@YAPEAX_K@Z");
    \\void *aa_msvc_new(size_t n) { void *p = malloc(n); if (!p) __builtin_trap(); return p; }
    \\
    \\void *aa_msvc_new_nothrow(size_t, const void *) __asm__("??2@YAPEAX_KAEBUnothrow_t@std@@@Z");
    \\void *aa_msvc_new_nothrow(size_t n, const void *nt) { (void)nt; return malloc(n); }
    \\
    \\void *aa_msvc_new_arr(size_t) __asm__("??_U@YAPEAX_K@Z");
    \\void *aa_msvc_new_arr(size_t n) { void *p = malloc(n); if (!p) __builtin_trap(); return p; }
    \\
    \\void *aa_msvc_new_arr_nothrow(size_t, const void *) __asm__("??_U@YAPEAX_KAEBUnothrow_t@std@@@Z");
    \\void *aa_msvc_new_arr_nothrow(size_t n, const void *nt) { (void)nt; return malloc(n); }
    \\
    \\void aa_msvc_delete(void *) __asm__("??3@YAXPEAX@Z");
    \\void aa_msvc_delete(void *p) { free(p); }
    \\
    \\void aa_msvc_delete_sized(void *, size_t) __asm__("??3@YAXPEAX_K@Z");
    \\void aa_msvc_delete_sized(void *p, size_t n) { (void)n; free(p); }
    \\
    \\void aa_msvc_delete_arr(void *) __asm__("??_V@YAXPEAX@Z");
    \\void aa_msvc_delete_arr(void *p) { free(p); }
    \\
    \\void aa_msvc_delete_arr_sized(void *, size_t) __asm__("??_V@YAXPEAX_K@Z");
    \\void aa_msvc_delete_arr_sized(void *p, size_t n) { (void)n; free(p); }
    \\
    \\const char aa_msvc_nothrow __asm__("?nothrow@std@@3Unothrow_t@1@B") = 0;
    \\
;

// --- Tests -------------------------------------------------------------------

const testing = std.testing;

test "link invocations are detected by executable name" {
    try testing.expect(isLinkInvocation("link"));
    try testing.expect(isLinkInvocation("link.exe"));
    try testing.expect(isLinkInvocation("LINK.EXE"));
    try testing.expect(isLinkInvocation("/usr/local/bin/link"));
    try testing.expect(isLinkInvocation("C:\\tools\\link.exe"));
    try testing.expect(!isLinkInvocation("clang"));
    try testing.expect(!isLinkInvocation("llvm-objcopy"));
    try testing.expect(!isLinkInvocation("ld.lld"));
    // A directory containing "link" must not trip the check.
    try testing.expect(!isLinkInvocation("/opt/link/clang"));
    try testing.expect(!isLinkInvocation("golink"));
}

fn expectArgs(expected: []const []const u8, actual: []const []const u8) !void {
    try testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |e, a| try testing.expectEqualStrings(e, a);
}

test "response file lines tokenize with quotes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var out: Args = .empty;
    try tokenizeLine(arena, "\"obj/native/Hello.obj\"", &out);
    try tokenizeLine(arena, "/NOLOGO /MANIFEST:NO", &out);
    try tokenizeLine(arena, "/NATVIS:\"/path with spaces/NativeAOT.natvis\"", &out);
    try tokenizeLine(arena, "  ", &out);
    try expectArgs(&.{
        "obj/native/Hello.obj",
        "/NOLOGO",
        "/MANIFEST:NO",
        "/NATVIS:/path with spaces/NativeAOT.natvis",
    }, out.items);
}

const FakeReader = struct {
    path: []const u8,
    contents: []const u8,

    fn read(self: FakeReader, arena: Allocator, path: []const u8) ![]u8 {
        if (!std.mem.eql(u8, path, self.path)) return error.FileNotFound;
        return arena.dupe(u8, self.contents);
    }
};

test "response files expand with BOM and CRLF" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const reader = FakeReader{
        .path = "obj/native/link.rsp",
        .contents = "\xEF\xBB\xBF\"Hello.obj\"\r\n/OUT:\"bin/Hello.exe\"\r\n/NOLOGO /NOEXP\r\n",
    };
    const expanded = try expandResponseFiles(arena, reader, &.{"@obj/native/link.rsp"}, 0);
    try expectArgs(&.{ "Hello.obj", "/OUT:bin/Hello.exe", "/NOLOGO", "/NOEXP" }, expanded.items);
    try testing.expectEqualStrings("obj/native", expanded.rsp_dir.?);

    const utf16 = FakeReader{ .path = "a.rsp", .contents = "\xFF\xFEx" };
    try testing.expectError(error.Utf16ResponseFileUnsupported, expandResponseFiles(arena, utf16, &.{"@a.rsp"}, 0));
}

test "translates the ILC windows link response file" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Condensed from a real net10 link.rsp, plus the injected --target line.
    const t = try translate(arena, &.{
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

    try expectArgs(&.{
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
        "-Wl,--gc-sections",
        "--target=x86_64-windows-gnu",
    }, t.args.items);
    try testing.expect(t.saw_target);
    try testing.expectEqualStrings("bin/native/Hello.exe", t.out_path.?);
    try testing.expectEqual(@as(usize, 0), t.warnings.items.len);

    // The /MERGE requests are collected for object surgery, and the ILC
    // object was recognized as a rename candidate.
    try testing.expectEqual(@as(usize, 2), t.merges.items.len);
    try testing.expectEqualStrings(".managedcode", t.merges.items[0].from);
    try testing.expectEqualStrings(".text", t.merges.items[0].to);
    try testing.expectEqualStrings("hydrated", t.merges.items[1].from);
    try testing.expectEqualStrings(".bss", t.merges.items[1].to);
    try expectArgs(&.{ "obj/native/Hello.obj", "/Users/u/.nuget/packages/pack/sdk/bootstrapper.obj" }, t.object_inputs.items);
}

test "translates DLL, INCLUDE, custom entry and libpath" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const t = try translate(arena, &.{
        "/DLL",
        "/OUT:bin/native/Lib.dll",
        "/INCLUDE:MyExport",
        "/ENTRY:MyStartup",
        "/LIBPATH:/opt/libs",
        "/SUBSYSTEM:WINDOWS,6.0",
    });
    try expectArgs(&.{
        "-shared",
        "-o",
        "bin/native/Lib.dll",
        "-Wl,-u,MyExport",
        "-Wl,--entry,MyStartup",
        "-L/opt/libs",
        "-Wl,--subsystem,windows",
    }, t.args.items);
    try testing.expectEqual(@as(usize, 0), t.warnings.items.len);
}

test "mainCRTStartup entry needs no flag and DEBUG variants emit one -g" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const t = try translate(arena, &.{ "/ENTRY:mainCRTStartup", "/DEBUG:FULL", "/DEBUG" });
    try expectArgs(&.{"-g"}, t.args.items);
}

test "unknown options warn and drop, absolute paths pass through" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const t = try translate(arena, &.{
        "/PROFILE",
        "/DELAYLOAD:foo.dll",
        "/Users/u/objs/thing.obj",
        "relative/path.lib",
        "UPPER.LIB",
    });
    try expectArgs(&.{
        "/Users/u/objs/thing.obj",
        "relative/path.lib",
        "-lupper",
    }, t.args.items);
    try testing.expectEqual(@as(usize, 2), t.warnings.items.len);
}

/// Builds a minimal COFF object image: header, three section headers
/// (.text inline, .managedcode$I via the string table, hydrated inline and
/// uninitialized), no symbols, and a string table.
fn buildTestCoff(arena: Allocator, hydrated_initialized: bool) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    const zeros = [1]u8{0} ** 40;

    try out.appendSlice(arena, &zeros[0..20].*); // file header
    std.mem.writeInt(u16, out.items[0..2], 0x8664, .little); // machine: amd64
    std.mem.writeInt(u16, out.items[2..4], 3, .little); // section count

    const strtab_data = "\x00\x00\x00\x00.managedcode$I\x00"; // size fixed up below
    const strtab_offset = 20 + 3 * 40;
    std.mem.writeInt(u32, out.items[8..12], strtab_offset, .little); // symbol table (empty) sits at the string table
    std.mem.writeInt(u32, out.items[12..16], 0, .little); // symbol count

    // Section 1: .text, initialized code.
    try out.appendSlice(arena, &zeros);
    var header = out.items[20..];
    std.mem.copyForwards(u8, header[0..5], ".text");
    std.mem.writeInt(u32, header[36..40], 0x60000020, .little);

    // Section 2: .managedcode$I via string-table reference "/4".
    try out.appendSlice(arena, &zeros);
    header = out.items[20 + 40 ..];
    std.mem.copyForwards(u8, header[0..2], "/4");
    std.mem.writeInt(u32, header[36..40], 0x60000020, .little);

    // Section 3: hydrated, exactly 8 name bytes, uninitialized by default.
    try out.appendSlice(arena, &zeros);
    header = out.items[20 + 80 ..];
    std.mem.copyForwards(u8, header[0..8], "hydrated");
    const hydrated_chars: u32 = if (hydrated_initialized) 0xc0000040 else 0xc0000080;
    std.mem.writeInt(u32, header[36..40], hydrated_chars, .little);

    try out.appendSlice(arena, strtab_data);
    std.mem.writeInt(u32, out.items[strtab_offset..][0..4], strtab_data.len, .little);
    return out.items;
}

test "MERGE renames grouped and exact-length sections in place" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const coff = try buildTestCoff(arena, false);

    const managed = renameCoffSections(coff, ".managedcode", ".text");
    try testing.expectEqual(@as(u32, 1), managed.renamed);
    try testing.expectEqualStrings(".text$I", coffSectionName(coff, 20 + 40, 20 + 3 * 40).?);

    const hydrated = renameCoffSections(coff, "hydrated", ".bss");
    try testing.expectEqual(@as(u32, 1), hydrated.renamed);
    try testing.expectEqualStrings(".bss", coffSectionName(coff, 20 + 80, 20 + 3 * 40).?);

    // Untouched section keeps its name; a second pass finds nothing.
    try testing.expectEqualStrings(".text", coffSectionName(coff, 20, 20 + 3 * 40).?);
    try testing.expectEqual(@as(u32, 0), renameCoffSections(coff, ".managedcode", ".text").renamed);
    try testing.expectEqual(@as(u32, 0), renameCoffSections(coff, "hydrated", ".bss").renamed);
}

test "MERGE refuses unsafe or unrepresentable renames" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Initialized data must not silently move into .bss.
    const initialized = try buildTestCoff(arena, true);
    const bss = renameCoffSections(initialized, "hydrated", ".bss");
    try testing.expectEqual(@as(u32, 0), bss.renamed);
    try testing.expectEqual(@as(u32, 1), bss.skipped_initialized);
    try testing.expectEqualStrings("hydrated", coffSectionName(initialized, 20 + 80, 20 + 3 * 40).?);

    // A renamed name that does not fit 8 bytes inline is skipped.
    const coff = try buildTestCoff(arena, false);
    const long = renameCoffSections(coff, ".managedcode", ".mycode");
    try testing.expectEqual(@as(u32, 0), long.renamed);
    try testing.expectEqual(@as(u32, 1), long.skipped_long); // ".mycode$I" is 9 bytes

    // Non-object inputs (import members, garbage) are left untouched.
    var import_member = [_]u8{0} ** 24;
    std.mem.writeInt(u16, import_member[0..2], 0, .little);
    std.mem.writeInt(u16, import_member[2..4], 0xffff, .little);
    try testing.expectEqual(@as(u32, 0), renameCoffSections(&import_member, ".managedcode", ".text").renamed);
    var garbage = [_]u8{ 1, 2, 3 };
    try testing.expectEqual(@as(u32, 0), renameCoffSections(&garbage, "a", "b").renamed);
}

test "option payload parsing is case-insensitive" {
    try testing.expectEqualStrings("x", optPayload("out:x", "OUT").?);
    try testing.expectEqualStrings("x", optPayload("OUT:x", "OUT").?);
    try testing.expectEqual(null, optPayload("OUT:", "OUT"));
    try testing.expectEqual(null, optPayload("OUTX:x", "OUT"));
    try testing.expect(isDropped("nologo"));
    try testing.expect(isDropped("IGNORE:4104"));
    try testing.expect(!isDropped("IGNOREX"));
    try testing.expect(looksLikeOption("PROFILE"));
    try testing.expect(looksLikeOption("DELAYLOAD:foo.dll"));
    try testing.expect(!looksLikeOption("Users/u/x.obj"));
    try testing.expect(!looksLikeOption("tmp/x"));
}
