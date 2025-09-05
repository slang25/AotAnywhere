@echo off
setlocal enabledelayedexpansion

:: ==========================================================================
:: clang.cmd - Wrapper to redirect clang calls to 'zig cc'.
:: ==========================================================================

:: --- Dependency Check ---
@where zig >nul 2>&1
@if ERRORLEVEL 1 (
  echo Error: zig is not on the PATH.
  echo Install zig and ensure it's on the PATH.
  exit /B 1
)

set "args=%*"

:: --- Optional Debug Logging ---
if defined ZIG_SHIM_DEBUG (
    echo [DEBUG] Original args: clang %args%
)

rem Pad arguments with spaces to make string replacement robust and simple.
set "args= %args% "

rem --- Target Detection ---
echo !args! | findstr /C:"-apple-darwin" /C:"-framework" /C:"-exported_symbols_list" /C:"x86_64-macos" /C:"aarch64-macos" >nul
if not errorlevel 1 (
    rem --- macOS Cross-Compilation Target ---
    echo [clang.cmd] Detected macOS cross-compilation target.

    rem Remove macOS-specific linker option that zig doesn't support.
    set "args=!args: -ld_classic = !"

    rem Remove host-specific library search path. Zig finds these automatically.
    set "args=!args: -L/usr/lib/swift = !"

    rem Add -mmacosx-version-min to tell Zig which of its bundled SDKs
    rem to activate. This is critical for the linker to find system libraries
    rem like 'objc' and frameworks like 'CoreFoundation'.
    set "args=!args! -mmacosx-version-min=11.0"

) else (
    rem --- Linux Cross-Compilation Target ---
    echo [clang.cmd] Detected Linux cross-compilation target.

    rem Works around zlib not being available with zig.
    set "args=!args: -lz = !"

    rem Work around a .NET 8 Preview 6 issue (removes single quotes).
    set "args=!args:'-Wl,-rpath,$ORIGIN'=-Wl,-rpath,$ORIGIN!"

    rem Replace parameters unsupported by zig.
    set "args=!args: --discard-all = --as-needed !"

    rem Remove -pie flags. The space padding makes this simple and robust.
    set "args=!args: -pie = !"
    set "args=!args: -Wl,-pie = !"

    rem Remove other unsupported flags.
    set "args=!args: -Wl,-e0x0 = !"

    rem Works around zig linker dropping necessary parts of the executable.
    set "args=-Wl,-u,__Module !args!"
)

rem --- Final Cleanup ---
call :trim_args args

if defined ZIG_SHIM_DEBUG (
    echo [DEBUG] Final command: zig cc !args!
)

rem --- Execution ---
zig cc !args!
exit /B !ERRORLEVEL!


:trim_args
rem Helper function to trim spaces from arguments and normalize spacing.
rem Usage: call :trim_args variable_name
setlocal enabledelayedexpansion
set "var_name=%~1"
call set "input_args=%%%~1%%"

rem Remove leading spaces
for /f "tokens=* delims= " %%a in ("!input_args!") do set "input_args=%%a"

rem Remove trailing spaces
:trim_end
if "!input_args:~-1!"==" " (
    set "input_args=!input_args:~0,-1!"
    goto trim_end
)

rem Replace multiple spaces with single space
:normalize_spaces
set "temp_args=!input_args:  = !"
if not "!temp_args!"=="!input_args!" (
    set "input_args=!temp_args!"
    goto normalize_spaces
)

endlocal & set "%var_name%=%input_args%"
goto :EOF
