#!/usr/bin/env python3
"""Generate the curated Apple .tbd stub sysroot shipped with PublishAotCross.

.NET Native AOT binaries targeting macOS link against a handful of Apple
system libraries and frameworks. When cross-compiling from Linux or Windows
there is no Apple SDK, so the package ships minimal, self-authored .tbd
linker stubs for exactly the symbols the .NET runtime packs reference.

This script regenerates those stubs. It must run on macOS with Xcode (or the
Command Line Tools) installed:

  1. Downloads the .NET Native AOT runtime packs pinned in PACK_VERSIONS for
     osx-x64 and osx-arm64 from nuget.org (cached under eng/.cache/).
  2. Collects the undefined symbols of every static library / object file in
     each pack, minus the symbols the same pack defines itself.
  3. Drops symbols that zig's bundled libSystem stub already resolves
     (zig cc always links libSystem for macOS targets).
  4. Attributes each remaining symbol to the Apple library that exports it,
     using the local macOS SDK's .tbd files as the lookup table.
  5. Writes minimal tbd-v4 stubs (only the referenced symbols, i.e. symbol
     lists derived from the MIT-licensed .NET runtime packs - NOT copies of
     Apple's export lists) to src/apple-sysroot/.

Update PACK_VERSIONS when new .NET releases ship, re-run, and commit the
result:

  python3 eng/generate-apple-sysroot.py
"""

import io
import os
import re
import subprocess
import sys
import urllib.request
import zipfile

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CACHE_DIR = os.path.join(REPO_ROOT, "eng", ".cache", "apple-sysroot-packs")
OUTPUT_DIR = os.path.join(REPO_ROOT, "src", "apple-sysroot")

RIDS = ["osx-x64", "osx-arm64"]

# The .NET versions whose runtime packs seed the symbol lists. Keep the
# newest patch of every in-support major here (older patches only ever
# reference fewer symbols).
PACK_VERSIONS = {
    # net8/net9: static libs live in runtime.<rid>.microsoft.dotnet.ilcompiler
    "ilcompiler": ["8.0.28", "9.0.16"],
    # net10+: static libs live in microsoft.netcore.app.runtime.nativeaot.<rid>
    "nativeaot": ["10.0.9", "11.0.0-preview.5.26302.115"],
}

# Stubs to generate, in symbol-attribution priority order (a symbol exported
# by several libraries is assigned to the first match; CoreFoundation must
# come before Foundation, which reexports parts of it).
LIBRARIES = [
    # (name, SDK tbd path relative to the SDK root, sysroot-relative output path)
    ("CoreFoundation", "System/Library/Frameworks/CoreFoundation.framework/CoreFoundation.tbd",
     "System/Library/Frameworks/CoreFoundation.framework/CoreFoundation.tbd"),
    ("Foundation", "System/Library/Frameworks/Foundation.framework/Foundation.tbd",
     "System/Library/Frameworks/Foundation.framework/Foundation.tbd"),
    ("Security", "System/Library/Frameworks/Security.framework/Security.tbd",
     "System/Library/Frameworks/Security.framework/Security.tbd"),
    ("GSS", "System/Library/Frameworks/GSS.framework/GSS.tbd",
     "System/Library/Frameworks/GSS.framework/GSS.tbd"),
    ("Network", "System/Library/Frameworks/Network.framework/Network.tbd",
     "System/Library/Frameworks/Network.framework/Network.tbd"),
    ("CryptoKit", "System/Library/Frameworks/CryptoKit.framework/CryptoKit.tbd",
     "System/Library/Frameworks/CryptoKit.framework/CryptoKit.tbd"),
    ("libobjc", "usr/lib/libobjc.tbd", "usr/lib/libobjc.tbd"),
    ("libicucore", "usr/lib/libicucore.tbd", "usr/lib/libicucore.tbd"),
    ("libz", "usr/lib/libz.tbd", "usr/lib/libz.tbd"),
    ("libswiftCore", "usr/lib/swift/libswiftCore.tbd", "usr/lib/swift/libswiftCore.tbd"),
    ("libswiftFoundation", "usr/lib/swift/libswiftFoundation.tbd", "usr/lib/swift/libswiftFoundation.tbd"),
]

NATIVE_MEMBER = re.compile(r"\.(a|o)$")


def run(argv):
    return subprocess.run(argv, check=True, capture_output=True, text=True).stdout


def sdk_path():
    return run(["xcrun", "--show-sdk-path"]).strip()


def zig_libsystem_tbd():
    """Locate the libSystem stub bundled with the zig on PATH."""
    out = run(["zig", "env"])
    m = re.search(r'\.lib_dir = "([^"]+)"', out)  # zig 0.15+ zon output
    if not m:
        m = re.search(r'"lib_dir":\s*"([^"]+)"', out)  # older json output
    if not m:
        sys.exit("error: could not parse `zig env` output to find lib_dir")
    libc_dir = os.path.join(m.group(1), "libc", "darwin")
    for name in ("libSystem.tbd", "libSystem.B.tbd"):
        p = os.path.join(libc_dir, name)
        if os.path.exists(p):
            return p
    sys.exit(f"error: no libSystem stub found in {libc_dir}")


def pack_urls():
    """(pack-id, version, arch) triples with their nuget.org download URL."""
    for family, versions in PACK_VERSIONS.items():
        for version in versions:
            for rid in RIDS:
                pack = (f"runtime.{rid}.microsoft.dotnet.ilcompiler" if family == "ilcompiler"
                        else f"microsoft.netcore.app.runtime.nativeaot.{rid}")
                url = f"https://api.nuget.org/v3-flatcontainer/{pack}/{version}/{pack}.{version}.nupkg"
                yield pack, version, rid, url


def fetch_native_members(pack, version, url):
    """Download a pack (cached) and extract its .a/.o members. Returns a dir."""
    dest = os.path.join(CACHE_DIR, f"{pack}.{version}")
    if os.path.isdir(dest) and os.listdir(dest):
        return dest
    print(f"  downloading {pack} {version} ...")
    data = urllib.request.urlopen(url).read()
    os.makedirs(dest, exist_ok=True)
    with zipfile.ZipFile(io.BytesIO(data)) as zf:
        for info in zf.infolist():
            parts = info.filename.split("/")
            if NATIVE_MEMBER.search(info.filename) and (
                    parts[0] in ("sdk", "framework") or "/native/" in info.filename):
                target = os.path.join(dest, os.path.basename(info.filename))
                with zf.open(info) as src, open(target, "wb") as out:
                    out.write(src.read())
    return dest


def nm_symbols(directory, flag):
    """Union of `nm <flag>` symbol names over all .a/.o files in directory."""
    symbols = set()
    for name in sorted(os.listdir(directory)):
        if not NATIVE_MEMBER.search(name):
            continue
        out = subprocess.run(["xcrun", "nm", flag, "-j", os.path.join(directory, name)],
                             capture_output=True, text=True).stdout
        for line in out.splitlines():
            line = line.strip()
            if line and not line.endswith(":"):
                symbols.add(line)
    return symbols


# --- tbd parsing (attribution lookup only) ----------------------------------

LIST_KEYS = ("symbols", "objc-classes", "objc-eh-types", "objc-ivars",
             "weak-symbols", "thread-local-symbols")
LIST_RE = re.compile(
    r"^\s+(" + "|".join(LIST_KEYS) + r"):\s*\[(.*?)\]", re.S | re.M)
INSTALL_NAME_RE = re.compile(r"^install-name:\s*'?([^'\n]+)'?", re.M)


class TbdInfo:
    def __init__(self):
        self.install_name = None
        # exported symbol name -> kind ('symbols', 'weak-symbols', ...)
        self.exports = {}

    def lookup(self, symbol):
        """Kind under which `symbol` is exported, or None."""
        if symbol in self.exports:
            return self.exports[symbol]
        for prefix, key in (("_OBJC_CLASS_$_", "objc-classes"),
                            ("_OBJC_METACLASS_$_", "objc-classes"),
                            ("_OBJC_EHTYPE_$_", "objc-eh-types"),
                            ("_OBJC_IVAR_$_", "objc-ivars")):
            if symbol.startswith(prefix):
                name = symbol[len(prefix):]
                if self.exports.get(name) == key:
                    return key
        return None


def parse_tbd(path):
    """Union of exports over every YAML document in an Apple/zig .tbd file.

    Sub-libraries of an umbrella (e.g. Security's inlined sub-dylibs, or
    libSystem's libsystem_* members) appear as extra documents; attributing
    their symbols to the umbrella is exactly what a normal link does.
    """
    info = TbdInfo()
    with open(path) as f:
        text = f.read()
    m = INSTALL_NAME_RE.search(text)  # first document = the umbrella itself
    if m:
        info.install_name = m.group(1).strip()
    for key, body in LIST_RE.findall(text):
        for entry in body.replace("\n", " ").split(","):
            entry = entry.strip().strip("'\"")
            if entry:
                info.exports.setdefault(entry, key)
    return info


# --- tbd emission ------------------------------------------------------------

PLAIN_SYMBOL = re.compile(r"^[A-Za-z0-9_.]+$")


def yaml_symbol(name):
    return name if PLAIN_SYMBOL.match(name) else f"'{name}'"


def format_list(key, names):
    prefix = f"    {key}:".ljust(22)
    indent = " " * 24
    line = prefix + "[ "
    out = []
    for i, name in enumerate(sorted(names)):
        token = yaml_symbol(name) + ("," if i < len(names) - 1 else " ]")
        if len(line) + len(token) > 100:
            out.append(line.rstrip())
            line = indent + token + " "
        else:
            line += token + " "
    out.append(line.rstrip())
    return "\n".join(out)


def write_tbd(path, install_name, buckets):
    sections = []
    for key in LIST_KEYS:
        names = buckets.get(key)
        if not names:
            continue
        if key in ("objc-classes", "objc-eh-types", "objc-ivars"):
            prefix = {"objc-classes": ("_OBJC_CLASS_$_", "_OBJC_METACLASS_$_"),
                      "objc-eh-types": ("_OBJC_EHTYPE_$_",),
                      "objc-ivars": ("_OBJC_IVAR_$_",)}[key]
            names = {n.split("$_", 1)[1] for n in names if n.startswith(prefix)}
        sections.append(format_list(key, names))
    # A stub with no exports is still useful: it satisfies -l/-framework
    # lookups for libraries whose symbols are bound at runtime (dlsym).
    exports = ""
    if sections:
        body = "\n".join(sections)
        exports = f"""exports:
  - targets:         [ x86_64-macos, arm64-macos ]
{body}
"""
    content = f"""--- !tapi-tbd
tbd-version:     4
targets:         [ x86_64-macos, arm64-macos ]
install-name:    '{install_name}'
{exports}...
"""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(content)


def main():
    sdk = sdk_path()
    print(f"SDK: {sdk}")
    zig_tbd = zig_libsystem_tbd()
    print(f"zig libSystem stub: {zig_tbd}")

    libsystem = parse_tbd(zig_tbd)
    sdk_libsystem = parse_tbd(os.path.join(sdk, "usr/lib/libSystem.B.tbd"))
    libs = []
    for name, sdk_rel, out_rel in LIBRARIES:
        tbd = parse_tbd(os.path.join(sdk, sdk_rel))
        if not tbd.install_name:
            sys.exit(f"error: could not parse install-name from {sdk_rel}")
        libs.append((name, out_rel, tbd))

    # needed = union over packs of (undefined - defined-within-the-same-pack)
    needed = set()
    print("Collecting undefined symbols from runtime packs:")
    for pack, version, rid, url in pack_urls():
        directory = fetch_native_members(pack, version, url)
        undefined = nm_symbols(directory, "-u")
        defined = nm_symbols(directory, "-U")
        external = undefined - defined
        print(f"  {pack} {version}: {len(external)} external references")
        needed |= external

    # Swift objects in the packs autolink overlay dylibs via undefined
    # __swift_FORCE_LOAD_$_<lib> symbols; generate a stub for each such lib.
    FORCE_LOAD = "__swift_FORCE_LOAD_$_"
    for symbol in sorted({s for s in needed if s.startswith(FORCE_LOAD)}):
        lib = "lib" + symbol[len(FORCE_LOAD):]
        rel = f"usr/lib/swift/{lib}.tbd"
        if any(name == lib for name, _, _ in libs):
            continue
        sdk_tbd = os.path.join(sdk, rel)
        if not os.path.exists(sdk_tbd):
            print(f"WARNING: no SDK tbd for autolinked swift library {lib}; skipping")
            continue
        libs.append((lib, rel, parse_tbd(sdk_tbd)))

    resolved_by_libsystem = {s for s in needed if libsystem.lookup(s)}
    needed -= resolved_by_libsystem
    missing_from_zig = {s for s in needed if sdk_libsystem.lookup(s)}
    needed -= missing_from_zig  # libSystem-owned either way; a stub can't help

    assigned = {name: {} for name, _, _ in libs}  # lib -> kind -> set of syms
    leftovers = []
    for symbol in sorted(needed):
        for name, _, tbd in libs:
            kind = tbd.lookup(symbol)
            if kind:
                assigned[name].setdefault(kind, set()).add(symbol)
                break
        else:
            leftovers.append(symbol)

    print(f"\n{len(resolved_by_libsystem)} symbols resolved by zig's libSystem stub")
    for name, out_rel, tbd in libs:
        buckets = assigned[name]
        total = sum(len(v) for v in buckets.values())
        out_path = os.path.join(OUTPUT_DIR, out_rel)
        write_tbd(out_path, tbd.install_name, buckets)
        print(f"{name}: {total} symbols -> {os.path.relpath(out_path, REPO_ROOT)}")

    if missing_from_zig:
        print("\nWARNING: needed by the packs, exported by the SDK's libSystem, but "
              "missing from zig's libSystem stub (link will fail until zig updates):")
        for s in sorted(missing_from_zig):
            print(f"  {s}")
    if leftovers:
        print(f"\n{len(leftovers)} symbols not attributed to any stub "
              "(expected: ilc-generated symbols the app object provides):")
        for s in leftovers:
            print(f"  {s}")


if __name__ == "__main__":
    main()
