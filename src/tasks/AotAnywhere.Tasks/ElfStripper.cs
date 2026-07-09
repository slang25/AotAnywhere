namespace AotAnywhere.Tasks;

/// The input had no section header table - nothing to strip. Callers treat a
/// plain strip as a no-op and a debuglink request as an error.
public sealed class ElfNoSectionsException : Exception
{
    public ElfNoSectionsException(string message) : base(message) { }
}

/// Malformed / unsupported ELF.
public sealed class ElfFormatException : Exception
{
    public ElfFormatException(string message) : base(message) { }
}

/// Minimal ELF symbol-strip surgery for exactly the operations the ILC targets
/// drive through llvm-objcopy on Linux targets (zig 0.16's own `zig objcopy`
/// cannot write ELF). Faithful port of objcopy_shim.zig's rewriteElf/parseElf:
///
///   --strip-debug/--strip-unneeded  -> Strip()
///   --only-keep-debug <bin> <bin>.dbg -> a full copy of the binary (the caller)
///   --add-gnu-debuglink=<sidecar> <bin> -> AddDebugLink()
///
/// Stripping keeps every SHF_ALLOC section byte-identical at its original file
/// offset (program headers stay valid without relayout), drops all non-alloc
/// sections, and rebuilds .shstrtab + the section header table at the end.
/// Little-endian ELF32 (armv7) and ELF64 (x64/arm64) are supported.
public static class ElfStripper
{
    const ulong SHF_ALLOC = 0x2;
    const uint SHT_NULL = 0;
    const uint SHT_PROGBITS = 1;
    const uint SHT_STRTAB = 3;
    const uint SHT_RELA = 4;
    const uint SHT_NOBITS = 8;
    const uint SHT_REL = 9;

    // zig-linked Native AOT binaries have ~30 sections; ELF extended numbering
    // (real count in shdr[0]) starts at 0xff00, which we reject.
    const int MaxSections = 0xff00;

    enum ElfClass { Elf32, Elf64 }

    static int EhSize(ElfClass c) => c == ElfClass.Elf32 ? 52 : 64;
    static int PhEntSize(ElfClass c) => c == ElfClass.Elf32 ? 32 : 56;
    static int ShEntSize(ElfClass c) => c == ElfClass.Elf32 ? 40 : 64;

    struct Shdr
    {
        public uint Name;
        public uint Type;
        public ulong Flags;
        public ulong Addr;
        public ulong Offset;
        public ulong Size;
        public uint Link;
        public uint Info;
        public ulong AddrAlign;
        public ulong EntSize;
    }

    sealed class Parsed
    {
        public ElfClass Class;
        public int ShStrNdx;
        public Shdr[] Sections = Array.Empty<Shdr>();
        public byte[] Data = Array.Empty<byte>();
        public ulong ShStrTabOffset;
        public ulong ShStrTabSize;
        public int PhEnd;
    }

    // --- Public operations ---------------------------------------------------

    /// Drops all non-alloc sections (symbols, .debug_*, .comment, ...).
    public static byte[] Strip(byte[] data) => RewriteElf(data, strip: true, debuglink: null);

    /// Appends a .gnu_debuglink section (replacing any existing one) pointing at
    /// `sidecarBasename` with the given CRC32 of the sidecar file.
    public static byte[] AddDebugLink(byte[] data, string sidecarBasename, uint sidecarCrc) =>
        RewriteElf(data, strip: false, debuglink: new DebugLink(sidecarBasename, sidecarCrc));

    /// Validates the image parses (so --only-keep-debug fails on garbage here
    /// rather than in a debugger). Tolerates a section-less image.
    public static void ValidateParses(byte[] data)
    {
        try { ParseElf(data); }
        catch (ElfNoSectionsException) { }
    }

    /// The gnu_debuglink CRC (standard reflected CRC-32, poly 0xEDB88320).
    public static uint Crc32(byte[] data)
    {
        var crc = 0xFFFFFFFFu;
        foreach (var b in data)
        {
            crc ^= b;
            for (var k = 0; k < 8; k++)
                crc = (crc >> 1) ^ (0xEDB88320u & (uint)(-(int)(crc & 1)));
        }
        return crc ^ 0xFFFFFFFFu;
    }

    readonly struct DebugLink
    {
        public readonly string Basename;
        public readonly uint Crc;
        public DebugLink(string basename, uint crc) { Basename = basename; Crc = crc; }
    }

    // --- Parse ---------------------------------------------------------------

    static Parsed ParseElf(byte[] data)
    {
        if (data.Length < 52 || data[0] != 0x7f || data[1] != (byte)'E' || data[2] != (byte)'L' || data[3] != (byte)'F')
            throw new ElfFormatException("not an ELF file");

        var cls = data[4] switch
        {
            1 => ElfClass.Elf32,
            2 => ElfClass.Elf64,
            _ => throw new ElfFormatException("only ELF32 or ELF64 supported"),
        };
        if (data[5] != 1) throw new ElfFormatException("only little-endian ELF supported");
        if (data.Length < EhSize(cls)) throw new ElfFormatException("not an ELF file");
        if (cls == ElfClass.Elf32 && (ulong)data.Length > uint.MaxValue) throw new ElfFormatException("malformed ELF");

        var shoff = cls == ElfClass.Elf32 ? Rd32(data, 32) : Rd64(data, 40);
        var ehOff = cls == ElfClass.Elf32 ? 40 : 52; // e_phentsize sits here
        var phoff = cls == ElfClass.Elf32 ? Rd32(data, 28) : Rd64(data, 32);
        var phentsize = Rd16(data, ehOff + 2);
        var phnum = Rd16(data, ehOff + 4);
        var shentsize = Rd16(data, ehOff + 6);
        var shnum = Rd16(data, ehOff + 8);
        var shstrndx = Rd16(data, ehOff + 10);

        if (shoff == 0 || shnum == 0) throw new ElfNoSectionsException("no section headers");
        if (shnum >= MaxSections || shstrndx >= MaxSections) throw new ElfFormatException("extended numbering unsupported");
        if (shentsize != ShEntSize(cls)) throw new ElfFormatException("malformed ELF");
        if (shstrndx >= shnum) throw new ElfFormatException("malformed ELF");

        var shEnd = shoff + (ulong)shnum * (ulong)ShEntSize(cls);
        if (shEnd > (ulong)data.Length) throw new ElfFormatException("malformed ELF");

        ulong phEnd = (ulong)EhSize(cls);
        if (phnum > 0)
        {
            if (phentsize != PhEntSize(cls)) throw new ElfFormatException("malformed ELF");
            var phtEnd = phoff + (ulong)phnum * (ulong)PhEntSize(cls);
            if (phtEnd > (ulong)data.Length) throw new ElfFormatException("malformed ELF");
            phEnd = Math.Max(phEnd, phtEnd);
            for (var p = 0; p < phnum; p++)
            {
                var b = (int)(phoff + (ulong)p * (ulong)PhEntSize(cls));
                var pOffset = cls == ElfClass.Elf32 ? Rd32(data, b + 4) : Rd64(data, b + 8);
                var pFilesz = cls == ElfClass.Elf32 ? Rd32(data, b + 16) : Rd64(data, b + 32);
                var segEnd = pOffset + pFilesz;
                if (segEnd > (ulong)data.Length) throw new ElfFormatException("malformed ELF");
                phEnd = Math.Max(phEnd, segEnd);
            }
        }

        var sections = new Shdr[shnum];
        for (var idx = 0; idx < shnum; idx++)
        {
            var b = (int)(shoff + (ulong)idx * (ulong)ShEntSize(cls));
            Shdr s;
            if (cls == ElfClass.Elf32)
                s = new Shdr
                {
                    Name = Rd32(data, b), Type = Rd32(data, b + 4), Flags = Rd32(data, b + 8),
                    Addr = Rd32(data, b + 12), Offset = Rd32(data, b + 16), Size = Rd32(data, b + 20),
                    Link = Rd32(data, b + 24), Info = Rd32(data, b + 28), AddrAlign = Rd32(data, b + 32),
                    EntSize = Rd32(data, b + 36),
                };
            else
                s = new Shdr
                {
                    Name = Rd32(data, b), Type = Rd32(data, b + 4), Flags = Rd64(data, b + 8),
                    Addr = Rd64(data, b + 16), Offset = Rd64(data, b + 24), Size = Rd64(data, b + 32),
                    Link = Rd32(data, b + 40), Info = Rd32(data, b + 44), AddrAlign = Rd64(data, b + 48),
                    EntSize = Rd64(data, b + 56),
                };
            if (idx > 0 && s.Type != SHT_NOBITS && s.Type != SHT_NULL && s.Offset + s.Size > (ulong)data.Length)
                throw new ElfFormatException("malformed ELF");
            sections[idx] = s;
        }

        var strtab = sections[shstrndx];
        var haveStrtab = strtab.Type == SHT_STRTAB && strtab.Offset + strtab.Size <= (ulong)data.Length;

        return new Parsed
        {
            Class = cls,
            ShStrNdx = shstrndx,
            Sections = sections,
            Data = data,
            ShStrTabOffset = haveStrtab ? strtab.Offset : 0,
            ShStrTabSize = haveStrtab ? strtab.Size : 0,
            PhEnd = (int)phEnd,
        };
    }

    static string SectionName(Parsed p, uint nameOff)
    {
        if (nameOff >= p.ShStrTabSize) return "";
        var start = (int)(p.ShStrTabOffset + nameOff);
        var end = start;
        var limit = (int)(p.ShStrTabOffset + p.ShStrTabSize);
        while (end < limit && p.Data[end] != 0) end++;
        return System.Text.Encoding.ASCII.GetString(p.Data, start, end - start);
    }

    // --- Rewrite -------------------------------------------------------------

    static byte[] RewriteElf(byte[] data, bool strip, DebugLink? debuglink)
    {
        var p = ParseElf(data);
        var cls = p.Class;
        var sections = p.Sections;
        var n = sections.Length;

        // Which sections survive: alloc sections (mapped at run time), except
        // .shstrtab (always rebuilt) and any .gnu_debuglink being replaced.
        var keep = new bool[n];
        keep[0] = true;
        for (var i = 1; i < n; i++)
        {
            keep[i] = strip ? (sections[i].Flags & SHF_ALLOC) != 0 : true;
            if (i == p.ShStrNdx) keep[i] = false;
            if (debuglink != null && SectionName(p, sections[i].Name) == ".gnu_debuglink") keep[i] = false;
        }

        // Renumber: kept sections keep order; dropped map to 0 so dangling
        // sh_link/sh_info degrade to SHN_UNDEF.
        var indexMap = new uint[n];
        uint nextIndex = 1;
        for (var i = 1; i < n; i++)
            indexMap[i] = keep[i] ? nextIndex++ : 0u;

        // Preserve everything up to the last kept section's data (and all
        // segment data) verbatim; the symbol/debug tail truncates away.
        var dataEnd = (ulong)p.PhEnd;
        for (var i = 1; i < n; i++)
        {
            if (!keep[i] || sections[i].Type == SHT_NOBITS) continue;
            dataEnd = Math.Max(dataEnd, sections[i].Offset + sections[i].Size);
        }

        var outBuf = new List<byte>((int)dataEnd + 4096);
        // Bulk-copy the preserved prefix; AddRange takes the ICollection fast
        // path (a single Array.Copy) rather than a per-byte Add loop.
        outBuf.AddRange(new ArraySegment<byte>(data, 0, (int)dataEnd));

        // .gnu_debuglink payload: NUL-terminated basename padded to 4, then the
        // little-endian CRC32.
        ulong debuglinkOffset = 0, debuglinkSize = 0;
        if (debuglink is { } dl)
        {
            PadTo(outBuf, 4);
            debuglinkOffset = (ulong)outBuf.Count;
            outBuf.AddRange(System.Text.Encoding.ASCII.GetBytes(dl.Basename));
            outBuf.Add(0);
            PadTo(outBuf, 4);
            outBuf.Add((byte)dl.Crc);
            outBuf.Add((byte)(dl.Crc >> 8));
            outBuf.Add((byte)(dl.Crc >> 16));
            outBuf.Add((byte)(dl.Crc >> 24));
            debuglinkSize = (ulong)outBuf.Count - debuglinkOffset;
        }

        // Rebuilt section-name table.
        var strtab = new List<byte> { 0 };
        var newNames = new uint[n];
        for (var i = 1; i < n; i++)
            if (keep[i]) newNames[i] = AddName(strtab, SectionName(p, sections[i].Name));
        var debuglinkName = debuglink != null ? AddName(strtab, ".gnu_debuglink") : 0u;
        var shstrtabName = AddName(strtab, ".shstrtab");
        var shstrtabOffset = (ulong)outBuf.Count;
        outBuf.AddRange(strtab);

        // Rebuilt section header table.
        PadTo(outBuf, 8);
        var shoff = (ulong)outBuf.Count;
        for (var k = 0; k < ShEntSize(cls); k++) outBuf.Add(0); // SHT_NULL entry
        for (var i = 1; i < n; i++)
        {
            if (!keep[i]) continue;
            var s = sections[i];
            var link = s.Link < (uint)n ? indexMap[s.Link] : 0u;
            var isReloc = s.Type == SHT_REL || s.Type == SHT_RELA;
            var info = isReloc && s.Info != 0 ? (s.Info < (uint)n ? indexMap[s.Info] : 0u) : s.Info;
            AppendShdr(outBuf, cls, new Shdr
            {
                Name = newNames[i], Type = s.Type, Flags = s.Flags, Addr = s.Addr, Offset = s.Offset,
                Size = s.Size, Link = link, Info = info, AddrAlign = s.AddrAlign, EntSize = s.EntSize,
            });
        }
        if (debuglink != null)
        {
            AppendShdr(outBuf, cls, new Shdr
            {
                Name = debuglinkName, Type = SHT_PROGBITS, Offset = debuglinkOffset, Size = debuglinkSize, AddrAlign = 4,
            });
            nextIndex++;
        }
        var newShStrNdx = (ushort)nextIndex;
        AppendShdr(outBuf, cls, new Shdr
        {
            Name = shstrtabName, Type = SHT_STRTAB, Offset = shstrtabOffset, Size = (ulong)strtab.Count, AddrAlign = 1,
        });
        nextIndex++;

        var result = outBuf.ToArray();
        if (cls == ElfClass.Elf32)
        {
            Wr32(result, 32, Cast32(shoff)); // e_shoff
            Wr16(result, 48, (ushort)nextIndex); // e_shnum
            Wr16(result, 50, newShStrNdx); // e_shstrndx
        }
        else
        {
            Wr64(result, 40, shoff);
            Wr16(result, 60, (ushort)nextIndex);
            Wr16(result, 62, newShStrNdx);
        }
        return result;
    }

    static uint AddName(List<byte> strtab, string name)
    {
        var offset = (uint)strtab.Count;
        strtab.AddRange(System.Text.Encoding.ASCII.GetBytes(name));
        strtab.Add(0);
        return offset;
    }

    static void PadTo(List<byte> outBuf, int alignment)
    {
        while (outBuf.Count % alignment != 0) outBuf.Add(0);
    }

    static void AppendShdr(List<byte> outBuf, ElfClass cls, Shdr s)
    {
        if (cls == ElfClass.Elf32)
        {
            Add32(outBuf, s.Name); Add32(outBuf, s.Type); Add32(outBuf, Cast32(s.Flags)); Add32(outBuf, Cast32(s.Addr));
            Add32(outBuf, Cast32(s.Offset)); Add32(outBuf, Cast32(s.Size)); Add32(outBuf, s.Link); Add32(outBuf, s.Info);
            Add32(outBuf, Cast32(s.AddrAlign)); Add32(outBuf, Cast32(s.EntSize));
        }
        else
        {
            Add32(outBuf, s.Name); Add32(outBuf, s.Type); Add64(outBuf, s.Flags); Add64(outBuf, s.Addr);
            Add64(outBuf, s.Offset); Add64(outBuf, s.Size); Add32(outBuf, s.Link); Add32(outBuf, s.Info);
            Add64(outBuf, s.AddrAlign); Add64(outBuf, s.EntSize);
        }
    }

    static uint Cast32(ulong v) => v <= uint.MaxValue ? (uint)v : throw new ElfFormatException("malformed ELF");

    static ushort Rd16(byte[] d, int o) => (ushort)(d[o] | (d[o + 1] << 8));
    static uint Rd32(byte[] d, int o) => (uint)(d[o] | (d[o + 1] << 8) | (d[o + 2] << 16) | (d[o + 3] << 24));
    static ulong Rd64(byte[] d, int o) => Rd32(d, o) | ((ulong)Rd32(d, o + 4) << 32);

    static void Wr16(byte[] d, int o, ushort v) { d[o] = (byte)v; d[o + 1] = (byte)(v >> 8); }
    static void Wr32(byte[] d, int o, uint v) { d[o] = (byte)v; d[o + 1] = (byte)(v >> 8); d[o + 2] = (byte)(v >> 16); d[o + 3] = (byte)(v >> 24); }
    static void Wr64(byte[] d, int o, ulong v) { Wr32(d, o, (uint)v); Wr32(d, o + 4, (uint)(v >> 32)); }

    static void Add32(List<byte> b, uint v) { b.Add((byte)v); b.Add((byte)(v >> 8)); b.Add((byte)(v >> 16)); b.Add((byte)(v >> 24)); }
    static void Add64(List<byte> b, ulong v) { Add32(b, (uint)v); Add32(b, (uint)(v >> 32)); }
}
