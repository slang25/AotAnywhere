//! clang_shim.zig - Wrapper that redirects clang invocations to 'zig cc',
//! adjusting arguments for native compilation and cross-compilation.
//!
//! This is a multi-call binary: Crosscompile.targets materializes the same
//! executable as both `clang` and `llvm-objcopy`, and it dispatches on the
//! name it was invoked as. The objcopy personality (objcopy_shim.zig) covers
//! the symbol stripping the ILC targets perform for Linux targets, so
//! StripSymbols works with no LLVM install.
//!
//! Crosscompile.targets compiles this on demand with the zig toolchain the
//! package already provides, so no prebuilt binaries need to ship and the
//! same logic runs on every host OS. The source must compile with the zig
//! version pinned by $(ZigVersion) in Crosscompile.targets.
//!
//! Environment variables:
//!   ZIG_SHIM_DEBUG                - print original and final argument lists
//!   AOTANYWHERE_APPLE_SYSROOT - sysroot with Apple framework/library
//!                                   stubs (.tbd files) for macOS targets
//!
//! Run the unit tests with: zig test clang_shim.zig

const std = @import("std");
const builtin = @import("builtin");
const objcopy_shim = @import("objcopy_shim.zig");

const host_is_macos = builtin.os.tag == .macos;

const Args = std.ArrayList([]const u8);

/// Set once at startup; when null (unit tests), messages fall back to stderr.
var g_io: ?std.Io = null;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    g_io = io;

    const argv = try init.minimal.args.toSlice(arena);
    const raw_args = if (argv.len > 0) argv[1..] else argv;
    const args = try arena.alloc([]const u8, raw_args.len);
    for (raw_args, args) |src, *dst| dst.* = src;

    const debug = nonEmpty(init.environ_map.get("ZIG_SHIM_DEBUG")) != null;
    if (debug) {
        say("[DEBUG] Original args:", .{});
        for (args) |arg| say("  '{s}'", .{arg});
    }

    if (argv.len > 0 and isObjcopyInvocation(argv[0]))
        objcopy_shim.run(arena, io, args);

    var out: Args = .empty;
    try out.appendSlice(arena, &.{ "zig", "cc" });

    if (isQueryInvocation(args)) {
        // Toolchain queries (the ILC targets probe `clang --version` on
        // macOS hosts) pass through with no injected flags, since callers
        // parse the output. zig 0.16's `zig cc` drops a stray zero-byte a.o
        // in the working directory even for pure queries, so these run with
        // the shim's own (intermediate output) directory as cwd instead of
        // the caller's project directory.
        try out.appendSlice(arena, args);
        runZigCcQuery(arena, io, out.items);
    }

    if (detectMacosTarget(args)) {
        if (host_is_macos) {
            say("[clang shim] Detected native macOS compilation.", .{});
            try processMacosNative(arena, &out, args, detectMacosSdk(arena, io));
        } else {
            say("[clang shim] Detected macOS cross-compilation target.", .{});
            const sysroot = nonEmpty(init.environ_map.get("AOTANYWHERE_APPLE_SYSROOT"));
            try processMacosCross(arena, &out, args, sysroot);
        }
        if (try padFilePath(arena, args)) |pad_path| {
            if (writePadFile(io, pad_path)) {
                try out.append(arena, pad_path);
            } else |err| {
                say("Warning: could not write {s}: {s}", .{ pad_path, @errorName(err) });
            }
        }
    } else {
        say("[clang shim] Detected Linux compilation target.", .{});
        try processLinux(arena, &out, args);
    }

    if (debug) {
        say("[DEBUG] Final command:", .{});
        for (out.items) |arg| say("  '{s}'", .{arg});
    }

    runZigCc(io, out.items);
}

/// True when the multi-call binary was invoked under an objcopy name
/// (llvm-objcopy, objcopy, llvm-objcopy.exe, any path or casing), in which
/// case it acts as an ELF strip tool instead of a clang wrapper.
fn isObjcopyInvocation(argv0: []const u8) bool {
    const base = if (std.mem.lastIndexOfAny(u8, argv0, "/\\")) |sep| argv0[sep + 1 ..] else argv0;
    if (base.len < "objcopy".len) return false;
    var i: usize = 0;
    while (i + "objcopy".len <= base.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(base[i..][0.."objcopy".len], "objcopy")) return true;
    }
    return false;
}

/// True for invocations that only query the toolchain and produce no
/// compile or link output.
fn isQueryInvocation(args: []const []const u8) bool {
    if (args.len == 0) return true;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-###"))
            return true;
    }
    return false;
}

fn detectMacosTarget(args: []const []const u8) bool {
    for (args) |arg| {
        if (std.mem.indexOf(u8, arg, "-apple-darwin") != null or
            std.mem.indexOf(u8, arg, "-macos") != null or
            std.mem.indexOf(u8, arg, "-exported_symbols_list") != null or
            std.mem.eql(u8, arg, "-framework"))
            return true;
    }
    return false;
}

/// Swift overlay dylibs that .NET's Swift crypto bindings autolink through
/// LC_LINKER_OPTION load commands, which zig's linker does not process; the
/// shim passes them explicitly instead. -dead_strip_dylibs drops the ones
/// (and any other library) the binary ends up not referencing.
const swift_overlay_args = [_][]const u8{
    "-Wl,-dead_strip_dylibs", "-lswiftCoreFoundation", "-lswiftDarwin",
    "-lswiftDispatch",        "-lswiftIOKit",          "-lswiftObjectiveC",
    "-lswiftXPC",             "-lswift_Builtin_float", "-lswift_errno",
    "-lswift_math",           "-lswift_signal",        "-lswift_stdio",
    "-lswift_time",           "-lswiftsys_time",       "-lswiftunistd",
};

/// True for link invocations of a .NET Native AOT binary targeting macOS.
fn linksSwiftRuntime(args: []const []const u8) bool {
    return for (args) |arg| {
        if (std.mem.eql(u8, arg, "-lswiftCore")) break true;
    } else false;
}

/// Cross-compiling to macOS from a non-macOS host.
fn processMacosCross(gpa: std.mem.Allocator, out: *Args, args: []const []const u8, sysroot: ?[]const u8) !void {
    if (sysroot) |root| {
        // A sysroot with Apple framework/library stubs (.tbd files) was
        // provided, so we can link system libs and frameworks for real.
        say("Using Apple sysroot stubs: {s}", .{root});
        try out.append(gpa, try std.fmt.allocPrint(gpa, "-F{s}/System/Library/Frameworks", .{root}));
        try out.append(gpa, try std.fmt.allocPrint(gpa, "-L{s}/usr/lib", .{root}));
        for (args) |arg| {
            if (std.mem.eql(u8, arg, "-ld_classic")) // unsupported by zig's linker
                continue;
            if (std.mem.eql(u8, arg, "-L/usr/lib/swift")) {
                // Redirect absolute host paths into the sysroot.
                try out.append(gpa, try std.fmt.allocPrint(gpa, "-L{s}/usr/lib/swift", .{root}));
                continue;
            }
            try out.append(gpa, arg);
        }
        if (linksSwiftRuntime(args))
            try out.appendSlice(gpa, &swift_overlay_args);
        return;
    }

    say("Warning: Removing system libs/frameworks for cross-compilation.", .{});
    const dropped = [_][]const u8{
        "-ld_classic", "-lobjc",            "-lz",
        "-ldl",        "-lm",               "-licucore",
        "-lswiftCore", "-lswiftFoundation", "-L/usr/lib/swift",
    };
    var skip_next = false;
    for (args) |arg| {
        if (skip_next) {
            skip_next = false;
            continue;
        }
        if (matchesAny(arg, &dropped)) continue;
        if (std.mem.eql(u8, arg, "-framework")) {
            skip_next = true; // also consumes the framework name
            continue;
        }
        try out.append(gpa, arg);
    }
}

/// Native compilation on macOS.
fn processMacosNative(gpa: std.mem.Allocator, out: *Args, args: []const []const u8, sdk_path: ?[]const u8) !void {
    if (sdk_path) |sdk| {
        say("Using macOS SDK: {s}", .{sdk});
        try out.append(gpa, "-isysroot");
        try out.append(gpa, sdk);
        try out.append(gpa, try std.fmt.allocPrint(gpa, "-L{s}/usr/lib", .{sdk}));
        try out.append(gpa, try std.fmt.allocPrint(gpa, "-L{s}/usr/lib/swift", .{sdk}));
        try out.append(gpa, try std.fmt.allocPrint(gpa, "-F{s}/System/Library/Frameworks", .{sdk}));
    } else {
        std.debug.print("Warning: Could not determine macOS SDK path. Using fallbacks.\n", .{});
        try out.appendSlice(gpa, &.{ "-L/usr/lib", "-L/usr/lib/swift", "-F/System/Library/Frameworks" });
    }

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-ld_classic")) // unsupported by zig's linker
            continue;
        try out.append(gpa, arg);
    }
    if (linksSwiftRuntime(args))
        try out.appendSlice(gpa, &swift_overlay_args);
}

/// Compiling for Linux.
fn processLinux(gpa: std.mem.Allocator, out: *Args, args: []const []const u8) !void {
    // Works around the zig linker dropping necessary parts of the executable.
    try out.append(gpa, "-Wl,-u,__Module");

    for (args) |arg| {
        // zlib is not available with zig; -pie/-Wl,-e0x0 are unsupported.
        if (matchesAny(arg, &.{ "-lz", "-pie", "-Wl,-pie", "-Wl,-e0x0" })) continue;
        if (std.mem.eql(u8, arg, "--discard-all")) {
            try out.append(gpa, "--as-needed");
            continue;
        }
        // Works around a .NET 8 Preview 6 issue (removes single quotes).
        if (std.mem.eql(u8, arg, "'-Wl,-rpath,$ORIGIN'")) {
            try out.append(gpa, "-Wl,-rpath,$ORIGIN");
            continue;
        }
        try out.append(gpa, arg);
    }
}

const pad_file_name = "aotanywhere-gs-pad.c";
const pad_source =
    \\/* Generated by the AotAnywhere clang shim.
    \\   zig's linker keeps __DATA,__const inside the __DATA segment (ld64
    \\   migrates it to __DATA_CONST), and .NET's InitGSCookie() startup code
    \\   write-protects the whole 16 KiB page holding the GS cookie, which
    \\   lives in __const. Without padding, the start of __data shares that
    \\   page and the runtime crashes with SIGBUS on its next startup write.
    \\   The alignment below forces __data onto its own page. */
    \\__attribute__((used, section("__DATA,__data"), aligned(16384)))
    \\static volatile char aotanywhere_data_page_pad = 1;
    \\
;

/// Path for the padding source injected into macOS link invocations, placed
/// next to the linker output so it lands in the intermediate directory.
/// Returns null for non-link invocations (compile-only, --version, ...).
fn padFilePath(gpa: std.mem.Allocator, args: []const []const u8) !?[]const u8 {
    var output: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (matchesAny(arg, &.{ "-c", "-S", "-E", "-fsyntax-only", "--version" }))
            return null;
        if (std.mem.eql(u8, arg, "-o") and i + 1 < args.len) {
            output = args[i + 1];
            i += 1;
        }
    }
    const out_path = output orelse return null;
    const dir = std.fs.path.dirname(out_path) orelse return pad_file_name;
    return try std.fs.path.join(gpa, &.{ dir, pad_file_name });
}

fn writePadFile(io: std.Io, path: []const u8) !void {
    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, pad_source);
}

fn matchesAny(arg: []const u8, candidates: []const []const u8) bool {
    for (candidates) |c| {
        if (std.mem.eql(u8, arg, c)) return true;
    }
    return false;
}

/// Treats unset and empty environment variables the same.
fn nonEmpty(value: ?[]const u8) ?[]const u8 {
    const v = value orelse return null;
    return if (v.len == 0) null else v;
}

fn detectMacosSdk(gpa: std.mem.Allocator, io: std.Io) ?[]const u8 {
    const result = std.process.run(gpa, io, .{
        .argv = &.{ "xcrun", "--show-sdk-path" },
    }) catch return null;
    switch (result.term) {
        .exited => |code| if (code != 0) return null,
        else => return null,
    }
    const path = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (path.len == 0) return null;
    std.Io.Dir.accessAbsolute(io, path, .{}) catch return null;
    return path;
}

fn say(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
    if (g_io) |io| {
        std.Io.File.stdout().writeStreamingAll(io, msg) catch {};
    } else {
        std.debug.print("{s}", .{msg});
    }
}

fn runZigCc(io: std.Io, argv: []const []const u8) noreturn {
    if (std.process.can_replace) {
        // Replace the process image so zig's exit code (or signal) is
        // observed directly by the caller.
        const err = std.process.replace(io, .{ .argv = argv });
        reportSpawnError(err);
    } else run: {
        // Windows: spawn zig and forward its exit code. std builds a
        // correctly quoted command line, so arguments with spaces survive.
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

/// Runs a toolchain query as a child process with the shim's own directory
/// as cwd (see the query branch in main), forwarding output and exit code.
fn runZigCcQuery(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) noreturn {
    var cwd: std.process.Child.Cwd = .inherit;
    if (std.process.executablePathAlloc(io, gpa)) |self_path| {
        if (std.fs.path.dirname(self_path)) |dir| cwd = .{ .path = dir };
    } else |_| {}

    const result = std.process.run(gpa, io, .{ .argv = argv, .cwd = cwd }) catch |err| {
        reportSpawnError(err);
        std.process.exit(127);
    };
    std.Io.File.stdout().writeStreamingAll(io, result.stdout) catch {};
    std.Io.File.stderr().writeStreamingAll(io, result.stderr) catch {};
    switch (result.term) {
        .exited => |code| std.process.exit(code),
        else => std.process.exit(1),
    }
}

fn reportSpawnError(err: anyerror) void {
    if (err == error.FileNotFound) {
        std.debug.print("Error: zig is not on the PATH.\n", .{});
    } else {
        std.debug.print("Error: failed to run zig: {s}\n", .{@errorName(err)});
    }
}

// --- Tests -----------------------------------------------------------------

const testing = std.testing;

test {
    _ = objcopy_shim; // include the objcopy personality's tests
}

test "objcopy invocations are detected by executable name" {
    try testing.expect(isObjcopyInvocation("llvm-objcopy"));
    try testing.expect(isObjcopyInvocation("objcopy"));
    try testing.expect(isObjcopyInvocation("/usr/local/bin/llvm-objcopy"));
    try testing.expect(isObjcopyInvocation("C:\\tools\\llvm-objcopy.exe"));
    try testing.expect(isObjcopyInvocation("LLVM-OBJCOPY.EXE"));
    try testing.expect(!isObjcopyInvocation("clang"));
    try testing.expect(!isObjcopyInvocation("/usr/bin/clang"));
    try testing.expect(!isObjcopyInvocation("clang.exe"));
    // A directory containing "objcopy" must not trip the check.
    try testing.expect(!isObjcopyInvocation("/opt/llvm-objcopy-tools/clang"));
}

fn expectArgs(expected: []const []const u8, actual: []const []const u8) !void {
    try testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |e, a| try testing.expectEqualStrings(e, a);
}

test "query invocations pass through untouched" {
    try testing.expect(isQueryInvocation(&.{"--version"}));
    try testing.expect(isQueryInvocation(&.{ "-v", "--version" }));
    try testing.expect(isQueryInvocation(&.{}));
    try testing.expect(!isQueryInvocation(&.{ "-o", "hello", "main.o" }));
    try testing.expect(!isQueryInvocation(&.{ "-c", "-o", "main.o", "main.c" }));
}

test "target detection" {
    try testing.expect(detectMacosTarget(&.{ "-target", "arm64-apple-darwin" }));
    try testing.expect(detectMacosTarget(&.{"--target=aarch64-macos"}));
    try testing.expect(detectMacosTarget(&.{"--target=x86_64-macos"}));
    try testing.expect(detectMacosTarget(&.{ "-framework", "Foundation" }));
    try testing.expect(detectMacosTarget(&.{ "-Wl,-exported_symbols_list", "syms.txt" }));
    try testing.expect(!detectMacosTarget(&.{ "-o", "hello", "--target=x86_64-linux-gnu", "main.o" }));
}

test "linux filtering" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var out: Args = .empty;
    try processLinux(arena, &out, &.{
        "-o",       "out dir/hello", "--discard-all",        "-lz",    "-pie",
        "-Wl,-pie", "-Wl,-e0x0",     "'-Wl,-rpath,$ORIGIN'", "main.o",
    });
    try expectArgs(&.{
        "-Wl,-u,__Module", "-o", "out dir/hello", "--as-needed", "-Wl,-rpath,$ORIGIN", "main.o",
    }, out.items);
}

test "macos cross-compilation without sysroot drops system libs and frameworks" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var out: Args = .empty;
    try processMacosCross(arena, &out, &.{
        "--target=aarch64-macos", "-ld_classic",      "-lobjc",         "-lm",
        "-licucore",              "-framework",       "CoreFoundation", "-framework",
        "GSS",                    "-L/usr/lib/swift", "-o",             "hello",
        "main.o",
    }, null);
    try expectArgs(&.{ "--target=aarch64-macos", "-o", "hello", "main.o" }, out.items);
}

test "macos cross-compilation with sysroot links against stubs" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var out: Args = .empty;
    try processMacosCross(arena, &out, &.{
        "--target=aarch64-macos", "-ld_classic", "-L/usr/lib/swift", "-framework",
        "Security",               "-o",          "hello",            "main.o",
    }, "/opt/applesdk");
    try expectArgs(&.{
        "-F/opt/applesdk/System/Library/Frameworks",
        "-L/opt/applesdk/usr/lib",
        "--target=aarch64-macos",
        "-L/opt/applesdk/usr/lib/swift",
        "-framework",
        "Security",
        "-o",
        "hello",
        "main.o",
    }, out.items);
}

test "macos native adds SDK paths and drops -ld_classic" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var out: Args = .empty;
    try processMacosNative(arena, &out, &.{
        "-target", "arm64-apple-darwin", "-ld_classic", "-framework", "Foundation",
        "-o",      "hello",              "main.o",
    }, "/sdkroot");
    try expectArgs(&.{
        "-isysroot",
        "/sdkroot",
        "-L/sdkroot/usr/lib",
        "-L/sdkroot/usr/lib/swift",
        "-F/sdkroot/System/Library/Frameworks",
        "-target",
        "arm64-apple-darwin",
        "-framework",
        "Foundation",
        "-o",
        "hello",
        "main.o",
    }, out.items);
}

test "swift overlay libs are added when the swift runtime is linked" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var out: Args = .empty;
    try processMacosCross(arena, &out, &.{
        "--target=aarch64-macos", "-lswiftCore", "-o", "hello", "main.o",
    }, "/opt/applesdk");
    try expectArgs(&(.{
        "-F/opt/applesdk/System/Library/Frameworks",
        "-L/opt/applesdk/usr/lib",
        "--target=aarch64-macos",
        "-lswiftCore",
        "-o",
        "hello",
        "main.o",
    } ++ swift_overlay_args), out.items);

    var native: Args = .empty;
    try processMacosNative(arena, &native, &.{ "-lswiftCore", "-o", "hello", "main.o" }, "/sdkroot");
    try expectArgs(&(.{
        "-isysroot",                            "/sdkroot",
        "-L/sdkroot/usr/lib",                   "-L/sdkroot/usr/lib/swift",
        "-F/sdkroot/System/Library/Frameworks", "-lswiftCore",
        "-o",                                   "hello",
        "main.o",
    } ++ swift_overlay_args), native.items);
}

test "pad file path is derived from the link output" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const sep = std.fs.path.sep_str;
    try testing.expectEqualStrings(
        "obj" ++ sep ++ "native" ++ sep ++ "aotanywhere-gs-pad.c",
        (try padFilePath(arena, &.{ "--target=aarch64-macos", "-o", "obj/native/Hello", "main.o" })).?,
    );
    try testing.expectEqualStrings(
        "aotanywhere-gs-pad.c",
        (try padFilePath(arena, &.{ "-o", "Hello", "main.o" })).?,
    );
    // Compile-only and query invocations must not get a pad file.
    try testing.expectEqual(null, try padFilePath(arena, &.{ "-c", "-o", "main.o", "main.c" }));
    try testing.expectEqual(null, try padFilePath(arena, &.{"--version"}));
    try testing.expectEqual(null, try padFilePath(arena, &.{ "-framework", "Foundation" }));
}

test "macos native falls back when no SDK is found" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var out: Args = .empty;
    try processMacosNative(arena, &out, &.{ "-o", "hello", "main.o" }, null);
    try expectArgs(&.{
        "-L/usr/lib", "-L/usr/lib/swift", "-F/System/Library/Frameworks", "-o", "hello", "main.o",
    }, out.items);
}
