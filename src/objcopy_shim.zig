//! objcopy_shim.zig - llvm-objcopy personality of the AotAnywhere shim.
//!
//! StripSymbols defaults to true for Linux Native AOT targets and the ILC
//! targets drive it through llvm-objcopy, which most machines do not have
//! installed. zig 0.16's own `zig objcopy` cannot write ELF at all (its
//! ELF-to-ELF branch is an unconditional `fatal("unimplemented")`), so this
//! file implements the minimal ELF surgery for exactly the invocations
//! Microsoft.NETCore.Native.targets issues:
//!
//!   llvm-objcopy --only-keep-debug <bin> <bin>.dbg
//!   llvm-objcopy --strip-debug --strip-unneeded <bin>
//!   llvm-objcopy --add-gnu-debuglink=<bin>.dbg <bin>
//!
//! Stripping keeps every SHF_ALLOC section byte-identical at its original
//! file offset (so the program headers stay valid without relayout), drops
//! all non-alloc sections (.symtab, .strtab, .debug_*, .comment, ...) and
//! rebuilds .shstrtab plus the section header table at the end of the file.
//! All strip flavors (--strip-debug, --strip-unneeded, --strip-all) map to
//! that one operation. --only-keep-debug copies the whole binary as the
//! debug sidecar: larger than llvm-objcopy's output, but a strict superset
//! of what debuggers need, and the --add-gnu-debuglink CRC is computed over
//! the sidecar as written, so the debuglink match holds.
//!
//! Only 64-bit little-endian ELF is supported - that covers every Linux
//! target .NET ships runtime packs for (x64 and arm64, glibc and musl).

const std = @import("std");
const Allocator = std.mem.Allocator;

// --- Command line ------------------------------------------------------------

const CliOptions = struct {
    strip: bool = false,
    only_keep_debug: bool = false,
    debuglink_path: ?[]const u8 = null,
    input: ?[]const u8 = null,
    output: ?[]const u8 = null,
};

/// Entry point when the shim is invoked as (llvm-)objcopy. Never returns;
/// exits 0 on success and 1 with a message on stderr otherwise.
pub fn run(arena: Allocator, io: std.Io, args: []const []const u8) noreturn {
    var opts: CliOptions = .{};

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (matchesAny(arg, &.{ "--strip-debug", "--strip-unneeded", "--strip-all", "-g" })) {
            opts.strip = true;
        } else if (std.mem.eql(u8, arg, "--only-keep-debug")) {
            opts.only_keep_debug = true;
        } else if (std.mem.startsWith(u8, arg, "--add-gnu-debuglink=")) {
            opts.debuglink_path = arg["--add-gnu-debuglink=".len..];
        } else if (std.mem.eql(u8, arg, "--add-gnu-debuglink")) {
            i += 1;
            if (i >= args.len) fatal(io, "--add-gnu-debuglink expects a file argument", .{});
            opts.debuglink_path = args[i];
        } else if (matchesAny(arg, &.{ "--version", "-V" })) {
            const stdout = std.Io.File.stdout();
            stdout.writeStreamingAll(io, "AotAnywhere llvm-objcopy shim (ELF64, .NET Native AOT strip support)\n") catch {};
            std.process.exit(0);
        } else if (arg.len > 1 and arg[0] == '-') {
            fatal(io, "unsupported option '{s}' (supported: --strip-debug, --strip-unneeded, --strip-all, --only-keep-debug, --add-gnu-debuglink=<file>, --version)", .{arg});
        } else if (opts.input == null) {
            opts.input = arg;
        } else if (opts.output == null) {
            opts.output = arg;
        } else {
            fatal(io, "too many positional arguments ('{s}')", .{arg});
        }
    }

    const input = opts.input orelse fatal(io, "no input file given", .{});
    if (opts.only_keep_debug and (opts.strip or opts.debuglink_path != null))
        fatal(io, "--only-keep-debug cannot be combined with stripping or --add-gnu-debuglink", .{});
    if (!opts.only_keep_debug and !opts.strip and opts.debuglink_path == null)
        fatal(io, "nothing to do (expected --strip-debug/--strip-unneeded, --only-keep-debug or --add-gnu-debuglink)", .{});

    const data = readFile(arena, io, input);

    if (opts.only_keep_debug) {
        // The sidecar is a full copy of the (unstripped) binary; validate it
        // parses so a garbage input fails here rather than in a debugger.
        checkParses(arena, io, input, data);
        if (opts.output) |out_path| {
            if (!std.mem.eql(u8, out_path, input)) writeFile(arena, io, out_path, data, input);
        }
        std.process.exit(0);
    }

    var debuglink: ?Debuglink = null;
    if (opts.debuglink_path) |path| {
        const contents = readFile(arena, io, path);
        debuglink = .{
            .basename = std.fs.path.basename(path),
            .crc = std.hash.Crc32.hash(contents),
        };
    }

    const rewritten = rewriteElf(arena, data, .{ .strip = opts.strip, .debuglink = debuglink }) catch |err| switch (err) {
        // No section header table means nothing to strip; only a debuglink
        // request has to fail, since it needs somewhere to hang the section.
        error.NoSections => if (debuglink == null) std.process.exit(0) else fatal(io, "'{s}' has no section headers", .{input}),
        else => fatalParse(io, input, err),
    };

    writeFile(arena, io, opts.output orelse input, rewritten, input);
    std.process.exit(0);
}

fn checkParses(arena: Allocator, io: std.Io, path: []const u8, data: []const u8) void {
    _ = parseElf(arena, data) catch |err| switch (err) {
        error.NoSections => {},
        else => fatalParse(io, path, err),
    };
}

fn fatalParse(io: std.Io, path: []const u8, err: ParseError) noreturn {
    switch (err) {
        error.OutOfMemory => fatal(io, "out of memory", .{}),
        error.NotElf => fatal(io, "'{s}' is not an ELF file", .{path}),
        error.UnsupportedElf => fatal(io, "'{s}': only 64-bit little-endian ELF executables are supported", .{path}),
        error.Malformed => fatal(io, "'{s}': malformed ELF", .{path}),
        error.NoSections => fatal(io, "'{s}' has no section headers", .{path}),
    }
}

fn fatal(io: std.Io, comptime fmt: []const u8, args: anytype) noreturn {
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "llvm-objcopy (AotAnywhere shim): error: " ++ fmt ++ "\n", args) catch
        "llvm-objcopy (AotAnywhere shim): error\n";
    std.Io.File.stderr().writeStreamingAll(io, msg) catch {};
    std.process.exit(1);
}

fn matchesAny(arg: []const u8, candidates: []const []const u8) bool {
    for (candidates) |c| {
        if (std.mem.eql(u8, arg, c)) return true;
    }
    return false;
}

// --- File I/O ----------------------------------------------------------------

fn readFile(arena: Allocator, io: std.Io, path: []const u8) []u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited) catch |err|
        fatal(io, "cannot read '{s}': {s}", .{ path, @errorName(err) });
}

/// Writes `data` to `path` via a temp file + rename, so an interrupted run
/// never leaves a truncated binary behind for an incremental build to pick
/// up. The permissions of `mode_source` (the input binary) carry over, which
/// keeps the executable bit intact on in-place strips.
fn writeFile(arena: Allocator, io: std.Io, path: []const u8, data: []const u8, mode_source: []const u8) void {
    const cwd = std.Io.Dir.cwd();
    const source_stat = cwd.statFile(io, mode_source, .{}) catch |err|
        fatal(io, "cannot stat '{s}': {s}", .{ mode_source, @errorName(err) });

    const tmp_path = std.fmt.allocPrint(arena, "{s}.aotanywhere-tmp", .{path}) catch
        fatal(io, "out of memory", .{});

    writeAll(io, tmp_path, data) catch |err|
        fatal(io, "cannot write '{s}': {s}", .{ tmp_path, @errorName(err) });

    cwd.setFilePermissions(io, tmp_path, source_stat.permissions, .{}) catch |err|
        fatal(io, "cannot set permissions on '{s}': {s}", .{ tmp_path, @errorName(err) });
    cwd.rename(tmp_path, cwd, path, io) catch |err|
        fatal(io, "cannot rename '{s}' to '{s}': {s}", .{ tmp_path, path, @errorName(err) });
}

fn writeAll(io: std.Io, path: []const u8, data: []const u8) !void {
    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, data);
}

// --- ELF rewriting -----------------------------------------------------------

const SHF_ALLOC: u64 = 0x2;
const SHT_NULL: u32 = 0;
const SHT_PROGBITS: u32 = 1;
const SHT_STRTAB: u32 = 3;
const SHT_RELA: u32 = 4;
const SHT_NOBITS: u32 = 8;
const SHT_REL: u32 = 9;

/// Sanity bound; zig-linked Native AOT binaries have ~30 sections, and the
/// ELF extended-numbering scheme (real count in shdr[0]) starts at 0xff00.
const max_sections = 0xff00;

const Shdr = struct {
    name: u32,
    shtype: u32,
    flags: u64,
    addr: u64,
    offset: u64,
    size: u64,
    link: u32,
    info: u32,
    addralign: u64,
    entsize: u64,
};

const Parsed = struct {
    shoff: usize,
    shnum: u16,
    shstrndx: u16,
    /// Section headers, index 0 (the SHT_NULL entry) included.
    sections: []Shdr,
    /// Raw contents of the section-name string table.
    shstrtab: []const u8,
    /// File extent covered by the ELF header, program header table and all
    /// segment file data - bytes that must survive any rewrite untouched.
    ph_end: usize,
};

const ParseError = error{ OutOfMemory, NotElf, UnsupportedElf, Malformed, NoSections };

fn parseElf(gpa: Allocator, data: []const u8) ParseError!Parsed {
    if (data.len < 64 or !std.mem.eql(u8, data[0..4], "\x7fELF")) return error.NotElf;
    if (data[4] != 2 or data[5] != 1) return error.UnsupportedElf; // ELFCLASS64, ELFDATA2LSB

    const phoff = rd(u64, data, 32);
    const shoff = rd(u64, data, 40);
    const phentsize = rd(u16, data, 54);
    const phnum = rd(u16, data, 56);
    const shentsize = rd(u16, data, 58);
    const shnum = rd(u16, data, 60);
    const shstrndx = rd(u16, data, 62);

    if (shoff == 0 or shnum == 0) return error.NoSections;
    if (shnum >= max_sections or shstrndx >= max_sections) return error.UnsupportedElf; // extended numbering
    if (shentsize != 64) return error.Malformed;
    if (shstrndx >= shnum) return error.Malformed;

    const sh_end = std.math.add(u64, shoff, @as(u64, shnum) * 64) catch return error.Malformed;
    if (sh_end > data.len) return error.Malformed;

    var ph_end: u64 = 64; // ELF header
    if (phnum > 0) {
        if (phentsize != 56) return error.Malformed;
        const pht_end = std.math.add(u64, phoff, @as(u64, phnum) * 56) catch return error.Malformed;
        if (pht_end > data.len) return error.Malformed;
        ph_end = @max(ph_end, pht_end);
        var p: usize = 0;
        while (p < phnum) : (p += 1) {
            const base: usize = @intCast(phoff + p * 56);
            const p_offset = rd(u64, data, base + 8);
            const p_filesz = rd(u64, data, base + 32);
            const seg_end = std.math.add(u64, p_offset, p_filesz) catch return error.Malformed;
            if (seg_end > data.len) return error.Malformed;
            ph_end = @max(ph_end, seg_end);
        }
    }

    const sections = try gpa.alloc(Shdr, shnum);
    for (sections, 0..) |*s, idx| {
        const base: usize = @intCast(shoff + idx * 64);
        s.* = .{
            .name = rd(u32, data, base),
            .shtype = rd(u32, data, base + 4),
            .flags = rd(u64, data, base + 8),
            .addr = rd(u64, data, base + 16),
            .offset = rd(u64, data, base + 24),
            .size = rd(u64, data, base + 32),
            .link = rd(u32, data, base + 40),
            .info = rd(u32, data, base + 44),
            .addralign = rd(u64, data, base + 48),
            .entsize = rd(u64, data, base + 56),
        };
        if (idx > 0 and s.shtype != SHT_NOBITS and s.shtype != SHT_NULL) {
            const end = std.math.add(u64, s.offset, s.size) catch return error.Malformed;
            if (end > data.len) return error.Malformed;
        }
    }

    const strtab_hdr = sections[shstrndx];
    const shstrtab = if (strtab_hdr.shtype == SHT_STRTAB and strtab_hdr.offset + strtab_hdr.size <= data.len)
        data[@intCast(strtab_hdr.offset)..@intCast(strtab_hdr.offset + strtab_hdr.size)]
    else
        "";

    return .{
        .shoff = @intCast(shoff),
        .shnum = shnum,
        .shstrndx = shstrndx,
        .sections = sections,
        .shstrtab = shstrtab,
        .ph_end = @intCast(ph_end),
    };
}

fn sectionName(shstrtab: []const u8, name_off: u32) []const u8 {
    if (name_off >= shstrtab.len) return "";
    const rest = shstrtab[name_off..];
    return rest[0 .. std.mem.indexOfScalar(u8, rest, 0) orelse rest.len];
}

const Debuglink = struct {
    basename: []const u8,
    crc: u32,
};

const RewriteOptions = struct {
    /// Drop all non-SHF_ALLOC sections.
    strip: bool,
    /// Append a .gnu_debuglink section (replacing any existing one).
    debuglink: ?Debuglink = null,
};

/// Produces a new ELF image: the original bytes up to the end of the last
/// kept section's data are copied verbatim (alloc sections never move), then
/// the optional .gnu_debuglink payload, a rebuilt .shstrtab and a rebuilt
/// section header table are appended.
fn rewriteElf(gpa: Allocator, data: []const u8, opts: RewriteOptions) ParseError![]u8 {
    const parsed = try parseElf(gpa, data);
    const sections = parsed.sections;

    // Decide which sections survive. Alloc sections are what the program
    // headers map at runtime; everything else is symbols/debug info, except
    // .shstrtab (always rebuilt) and .gnu_debuglink (replaced when a new
    // link is being added).
    const keep = try gpa.alloc(bool, sections.len);
    keep[0] = true;
    for (sections[1..], 1..) |s, idx| {
        keep[idx] = if (opts.strip) (s.flags & SHF_ALLOC) != 0 else true;
        if (idx == parsed.shstrndx) keep[idx] = false;
        if (opts.debuglink != null and std.mem.eql(u8, sectionName(parsed.shstrtab, s.name), ".gnu_debuglink"))
            keep[idx] = false;
    }

    // Renumber: kept sections keep their relative order; dropped ones map to
    // 0 so dangling sh_link/sh_info references degrade to SHN_UNDEF.
    const index_map = try gpa.alloc(u32, sections.len);
    index_map[0] = 0;
    var next_index: u32 = 1;
    for (sections[1..], 1..) |_, idx| {
        if (keep[idx]) {
            index_map[idx] = next_index;
            next_index += 1;
        } else {
            index_map[idx] = 0;
        }
    }

    // Everything up to the last byte of kept section data (and all segment
    // data) is preserved verbatim. Dropped sections that happen to sit below
    // that point leave harmless dead bytes; in practice linkers place
    // symbols/debug info at the end of the file, so the tail truncates away.
    var data_end: usize = parsed.ph_end;
    for (sections[1..], 1..) |s, idx| {
        if (!keep[idx] or s.shtype == SHT_NOBITS) continue;
        data_end = @max(data_end, @as(usize, @intCast(s.offset + s.size)));
    }

    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(gpa, data[0..data_end]);

    // .gnu_debuglink payload: NUL-terminated basename padded to 4 bytes,
    // then the CRC32 of the sidecar file, little-endian.
    var debuglink_offset: u64 = 0;
    var debuglink_size: u64 = 0;
    if (opts.debuglink) |link| {
        try padTo(gpa, &out, 4);
        debuglink_offset = out.items.len;
        try out.appendSlice(gpa, link.basename);
        try out.append(gpa, 0);
        try padTo(gpa, &out, 4);
        var crc_bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &crc_bytes, link.crc, .little);
        try out.appendSlice(gpa, &crc_bytes);
        debuglink_size = out.items.len - debuglink_offset;
    }

    // Rebuilt section name table.
    var strtab: std.ArrayList(u8) = .empty;
    try strtab.append(gpa, 0);
    const new_names = try gpa.alloc(u32, sections.len);
    for (sections[1..], 1..) |s, idx| {
        if (keep[idx]) new_names[idx] = try addName(gpa, &strtab, sectionName(parsed.shstrtab, s.name));
    }
    const debuglink_name = if (opts.debuglink != null) try addName(gpa, &strtab, ".gnu_debuglink") else 0;
    const shstrtab_name = try addName(gpa, &strtab, ".shstrtab");
    const shstrtab_offset = out.items.len;
    try out.appendSlice(gpa, strtab.items);

    // Rebuilt section header table.
    try padTo(gpa, &out, 8);
    const shoff = out.items.len;
    try out.appendSlice(gpa, &([1]u8{0} ** 64)); // SHT_NULL entry
    for (sections[1..], 1..) |s, idx| {
        if (!keep[idx]) continue;
        const link = if (s.link < sections.len) index_map[s.link] else 0;
        // sh_info holds a section index only for relocation sections; for
        // symbol tables it is a symbol index and must pass through.
        const is_reloc = s.shtype == SHT_REL or s.shtype == SHT_RELA;
        const info = if (is_reloc and s.info != 0)
            (if (s.info < sections.len) index_map[s.info] else 0)
        else
            s.info;
        try appendShdr(gpa, &out, .{
            .name = new_names[idx],
            .shtype = s.shtype,
            .flags = s.flags,
            .addr = s.addr,
            .offset = s.offset,
            .size = s.size,
            .link = link,
            .info = info,
            .addralign = s.addralign,
            .entsize = s.entsize,
        });
    }
    if (opts.debuglink != null) {
        try appendShdr(gpa, &out, .{
            .name = debuglink_name,
            .shtype = SHT_PROGBITS,
            .flags = 0,
            .addr = 0,
            .offset = debuglink_offset,
            .size = debuglink_size,
            .link = 0,
            .info = 0,
            .addralign = 4,
            .entsize = 0,
        });
        next_index += 1;
    }
    const new_shstrndx: u16 = @intCast(next_index);
    try appendShdr(gpa, &out, .{
        .name = shstrtab_name,
        .shtype = SHT_STRTAB,
        .flags = 0,
        .addr = 0,
        .offset = shstrtab_offset,
        .size = strtab.items.len,
        .link = 0,
        .info = 0,
        .addralign = 1,
        .entsize = 0,
    });
    next_index += 1;

    wr(u64, out.items, 40, shoff); // e_shoff
    wr(u16, out.items, 60, next_index); // e_shnum
    wr(u16, out.items, 62, new_shstrndx); // e_shstrndx

    return out.toOwnedSlice(gpa);
}

fn addName(gpa: Allocator, strtab: *std.ArrayList(u8), name: []const u8) !u32 {
    const offset: u32 = @intCast(strtab.items.len);
    try strtab.appendSlice(gpa, name);
    try strtab.append(gpa, 0);
    return offset;
}

fn padTo(gpa: Allocator, out: *std.ArrayList(u8), alignment: usize) !void {
    while (out.items.len % alignment != 0) try out.append(gpa, 0);
}

fn appendShdr(gpa: Allocator, out: *std.ArrayList(u8), s: Shdr) !void {
    var buf: [64]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], s.name, .little);
    std.mem.writeInt(u32, buf[4..8], s.shtype, .little);
    std.mem.writeInt(u64, buf[8..16], s.flags, .little);
    std.mem.writeInt(u64, buf[16..24], s.addr, .little);
    std.mem.writeInt(u64, buf[24..32], s.offset, .little);
    std.mem.writeInt(u64, buf[32..40], s.size, .little);
    std.mem.writeInt(u32, buf[40..44], s.link, .little);
    std.mem.writeInt(u32, buf[44..48], s.info, .little);
    std.mem.writeInt(u64, buf[48..56], s.addralign, .little);
    std.mem.writeInt(u64, buf[56..64], s.entsize, .little);
    try out.appendSlice(gpa, &buf);
}

fn rd(comptime T: type, data: []const u8, offset: usize) T {
    return std.mem.readInt(T, data[offset..][0..@divExact(@typeInfo(T).int.bits, 8)], .little);
}

fn wr(comptime T: type, data: []u8, offset: usize, value: anytype) void {
    std.mem.writeInt(T, data[offset..][0..@divExact(@typeInfo(T).int.bits, 8)], @intCast(value), .little);
}

// --- Tests -------------------------------------------------------------------

const testing = std.testing;

test "crc32 matches the gnu_debuglink polynomial" {
    // .gnu_debuglink uses the standard IEEE 802.3 CRC-32 (same as gzip);
    // guard against the default std.hash.Crc32 ever changing polynomial.
    try testing.expectEqual(@as(u32, 0xCBF43926), std.hash.Crc32.hash("123456789"));
}

const SHT_SYMTAB: u32 = 2;
const SHT_DYNSYM: u32 = 11;

const TestSection = struct {
    name: []const u8,
    shtype: u32,
    flags: u64 = 0,
    data: []const u8 = "",
    link: u32 = 0,
    info: u32 = 0,
};

/// Builds an ELF64 LE image with the given sections; a SHT_NULL entry is
/// prepended and a .shstrtab appended, so section i lands at index i+1.
fn buildTestElf(gpa: Allocator, test_sections: []const TestSection) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(gpa, &([1]u8{0} ** 64));
    out.items[0] = 0x7f;
    out.items[1] = 'E';
    out.items[2] = 'L';
    out.items[3] = 'F';
    out.items[4] = 2; // ELFCLASS64
    out.items[5] = 1; // ELFDATA2LSB
    out.items[6] = 1; // EV_CURRENT
    wr(u16, out.items, 16, 3); // e_type = ET_DYN
    wr(u16, out.items, 18, 62); // e_machine = EM_X86_64
    wr(u32, out.items, 20, 1); // e_version
    wr(u16, out.items, 52, 64); // e_ehsize
    wr(u16, out.items, 58, 64); // e_shentsize

    const offsets = try gpa.alloc(u64, test_sections.len);
    for (test_sections, offsets) |s, *offset| {
        offset.* = out.items.len;
        try out.appendSlice(gpa, s.data);
    }

    var strtab: std.ArrayList(u8) = .empty;
    try strtab.append(gpa, 0);
    const names = try gpa.alloc(u32, test_sections.len);
    for (test_sections, names) |s, *name| name.* = try addName(gpa, &strtab, s.name);
    const shstrtab_name = try addName(gpa, &strtab, ".shstrtab");
    const shstrtab_offset = out.items.len;
    try out.appendSlice(gpa, strtab.items);

    try padTo(gpa, &out, 8);
    const shoff = out.items.len;
    try out.appendSlice(gpa, &([1]u8{0} ** 64));
    for (test_sections, 0..) |s, idx| {
        try appendShdr(gpa, &out, .{
            .name = names[idx],
            .shtype = s.shtype,
            .flags = s.flags,
            .addr = 0,
            .offset = offsets[idx],
            .size = s.data.len,
            .link = s.link,
            .info = s.info,
            .addralign = 1,
            .entsize = 0,
        });
    }
    try appendShdr(gpa, &out, .{
        .name = shstrtab_name,
        .shtype = SHT_STRTAB,
        .flags = 0,
        .addr = 0,
        .offset = shstrtab_offset,
        .size = strtab.items.len,
        .link = 0,
        .info = 0,
        .addralign = 1,
        .entsize = 0,
    });

    wr(u64, out.items, 40, shoff);
    wr(u16, out.items, 60, test_sections.len + 2);
    wr(u16, out.items, 62, test_sections.len + 1);
    return out.toOwnedSlice(gpa);
}

fn findSection(parsed: Parsed, name: []const u8) ?Shdr {
    for (parsed.sections[1..]) |s| {
        if (std.mem.eql(u8, sectionName(parsed.shstrtab, s.name), name)) return s;
    }
    return null;
}

/// Sections mimicking a linked executable: alloc text/dynamic symbol table,
/// non-alloc debug info and symbol table. Table indices: .text=1, .dynstr=2,
/// .dynsym=3, .debug_info=4, .symtab=5, .strtab=6, .shstrtab=7.
const test_layout = [_]TestSection{
    .{ .name = ".text", .shtype = SHT_PROGBITS, .flags = SHF_ALLOC | 0x4, .data = &([1]u8{0xAA} ** 16) },
    .{ .name = ".dynstr", .shtype = SHT_STRTAB, .flags = SHF_ALLOC, .data = "\x00libfoo\x00" },
    .{ .name = ".dynsym", .shtype = SHT_DYNSYM, .flags = SHF_ALLOC, .data = &([1]u8{0} ** 24), .link = 2, .info = 1 },
    .{ .name = ".debug_info", .shtype = SHT_PROGBITS, .data = "debug!" },
    .{ .name = ".symtab", .shtype = SHT_SYMTAB, .data = &([1]u8{0} ** 48), .link = 6, .info = 2 },
    .{ .name = ".strtab", .shtype = SHT_STRTAB, .data = "\x00main\x00" },
};

test "strip keeps alloc sections in place and drops the rest" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const original = try buildTestElf(arena, &test_layout);
    const original_parsed = try parseElf(arena, original);
    const original_text = findSection(original_parsed, ".text").?;

    const stripped = try rewriteElf(arena, original, .{ .strip = true });
    try testing.expect(stripped.len < original.len);

    const parsed = try parseElf(arena, stripped);
    // null + .text + .dynstr + .dynsym + rebuilt .shstrtab
    try testing.expectEqual(@as(u16, 5), parsed.shnum);
    try testing.expectEqual(@as(u16, 4), parsed.shstrndx);
    try testing.expectEqual(null, findSection(parsed, ".symtab"));
    try testing.expectEqual(null, findSection(parsed, ".strtab"));
    try testing.expectEqual(null, findSection(parsed, ".debug_info"));

    // Alloc section contents must not have moved a byte.
    const text = findSection(parsed, ".text").?;
    try testing.expectEqual(original_text.offset, text.offset);
    try testing.expectEqualSlices(
        u8,
        original[@intCast(original_text.offset)..@intCast(original_text.offset + original_text.size)],
        stripped[@intCast(text.offset)..@intCast(text.offset + text.size)],
    );

    // .dynsym's sh_link must be renumbered to .dynstr's new index (2), and
    // its sh_info (a symbol index, not a section index) left alone.
    const dynsym = findSection(parsed, ".dynsym").?;
    try testing.expectEqual(@as(u32, 2), dynsym.link);
    try testing.expectEqual(@as(u32, 1), dynsym.info);
}

test "strip is idempotent" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const original = try buildTestElf(arena, &test_layout);
    const once = try rewriteElf(arena, original, .{ .strip = true });
    const twice = try rewriteElf(arena, once, .{ .strip = true });
    try testing.expectEqualSlices(u8, once, twice);
}

test "add-gnu-debuglink appends name, padding and crc" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const original = try buildTestElf(arena, &test_layout);
    const stripped = try rewriteElf(arena, original, .{ .strip = true });
    const linked = try rewriteElf(arena, stripped, .{
        .strip = false,
        .debuglink = .{ .basename = "Hello.dbg", .crc = 0xCBF43926 },
    });

    const parsed = try parseElf(arena, linked);
    // stripped sections + .gnu_debuglink + rebuilt .shstrtab
    try testing.expectEqual(@as(u16, 6), parsed.shnum);
    const debuglink = findSection(parsed, ".gnu_debuglink").?;
    // "Hello.dbg\0" padded to 12, then 4 bytes of CRC.
    try testing.expectEqual(@as(u64, 16), debuglink.size);
    const contents = linked[@intCast(debuglink.offset)..@intCast(debuglink.offset + debuglink.size)];
    try testing.expectEqualSlices(u8, "Hello.dbg\x00\x00\x00", contents[0..12]);
    try testing.expectEqualSlices(u8, "\x26\x39\xf4\xcb", contents[12..16]);
}

test "add-gnu-debuglink replaces an existing debuglink" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const original = try buildTestElf(arena, &test_layout);
    const first = try rewriteElf(arena, original, .{
        .strip = true,
        .debuglink = .{ .basename = "old.dbg", .crc = 1 },
    });
    const second = try rewriteElf(arena, first, .{
        .strip = false,
        .debuglink = .{ .basename = "new.dbg", .crc = 2 },
    });

    const parsed = try parseElf(arena, second);
    var count: usize = 0;
    for (parsed.sections[1..]) |s| {
        if (std.mem.eql(u8, sectionName(parsed.shstrtab, s.name), ".gnu_debuglink")) count += 1;
    }
    try testing.expectEqual(@as(usize, 1), count);
    const debuglink = findSection(parsed, ".gnu_debuglink").?;
    const contents = second[@intCast(debuglink.offset)..@intCast(debuglink.offset + debuglink.size)];
    try testing.expectEqualSlices(u8, "new.dbg\x00", contents[0..8]);
}

test "strip combined with debuglink in one pass" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const original = try buildTestElf(arena, &test_layout);
    const result = try rewriteElf(arena, original, .{
        .strip = true,
        .debuglink = .{ .basename = "a.dbg", .crc = 0 },
    });
    const parsed = try parseElf(arena, result);
    try testing.expectEqual(@as(u16, 6), parsed.shnum);
    try testing.expectEqual(null, findSection(parsed, ".symtab"));
    try testing.expect(findSection(parsed, ".gnu_debuglink") != null);
}

test "rejects non-ELF and unsupported ELF inputs" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expectError(error.NotElf, parseElf(arena, "not an elf file, not even close"));

    const elf32 = try arena.dupe(u8, try buildTestElf(arena, &test_layout));
    elf32[4] = 1; // ELFCLASS32
    try testing.expectError(error.UnsupportedElf, parseElf(arena, elf32));

    const big_endian = try arena.dupe(u8, try buildTestElf(arena, &test_layout));
    big_endian[5] = 2; // ELFDATA2MSB
    try testing.expectError(error.UnsupportedElf, parseElf(arena, big_endian));

    const no_sections = try arena.dupe(u8, try buildTestElf(arena, &test_layout));
    wr(u16, no_sections, 60, 0); // e_shnum = 0
    try testing.expectError(error.NoSections, parseElf(arena, no_sections));

    const truncated_shdrs = try arena.dupe(u8, try buildTestElf(arena, &test_layout));
    wr(u64, truncated_shdrs, 40, truncated_shdrs.len - 32); // e_shoff past the end
    try testing.expectError(error.Malformed, parseElf(arena, truncated_shdrs));
}
