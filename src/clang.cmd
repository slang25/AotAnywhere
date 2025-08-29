@echo off

@where zig >nul 2>&1
@if ERRORLEVEL 1 (
  echo Error: zig is not on the PATH. Install zig and make sure it's on PATH. Follow instructions at https://github.com/MichalStrehovsky/PublishAotCross.
  exit /B 1
)

set args=%*

rem Detect if this is a macOS target by looking for macOS-specific flags
echo %args% | findstr /C:"-apple-darwin" /C:"-framework" /C:"-exported_symbols_list" >nul
if not errorlevel 1 (
    rem We're on Windows (not macOS) and targeting macOS, so this is cross-compilation
    echo Cross-compiling to macOS target using PublishAotCross...
    
    rem Handle macOS-specific flags that zig doesn't support
    set args=%args:-ld_classic =%
    
    rem Remove problematic libraries that may not be available during cross-compilation
    set args=%args:-lswiftCore =%
    set args=%args:-lswiftFoundation =%
    set args=%args:-licucore =%
    set args=%args:-L/usr/lib/swift =%
    set args=%args:-lobjc =%
    set args=%args:-lz =%
    
    rem Remove frameworks that may cause issues in cross-compilation
    set args=%args:-framework CryptoKit =%
    set args=%args:-framework GSS =%
    set args=%args:-framework CoreFoundation =%
    set args=%args:-framework Foundation =%
    set args=%args:-framework Security =%
    
) else (
    rem Linux-specific argument handling (existing logic)
    
    rem Works around zlib not being available with zig. This is not great.
    set args=%args:-lz =%

    rem Work around a .NET 8 Preview 6 issue
    set args=%args:'-Wl,-rpath,$ORIGIN'=-Wl,-rpath,$ORIGIN%

    rem Work around parameters unsupported by zig. Just drop them from the command line.
    set args=%args:--discard-all=--as-needed%
    set args=%args:-Wl,-pie =%
    set args=%args:-pie =%
    set args=%args:-Wl,-e0x0 =%

    rem Works around zig linker dropping necessary parts of the executable.
    set args=-Wl,-u,__Module %args%
)

rem Run zig cc
zig cc %args%
