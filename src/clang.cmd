@echo off

@where zig >nul 2>&1
@if ERRORLEVEL 1 (
  echo Error: zig is not on the PATH. Install zig and make sure it's on PATH. Follow instructions at https://github.com/MichalStrehovsky/PublishAotCross.
  exit /B 1
)

set "args=%*"

rem Detect if this is a macOS target by looking for macOS-specific flags
echo %args% | findstr /C:"-apple-darwin" /C:"-framework" /C:"-exported_symbols_list" >nul
if not errorlevel 1 (
    rem We're on Windows (not macOS) and targeting macOS, so this is cross-compilation
    echo Cross-compiling to macOS target using PublishAotCross...
    
    rem Handle macOS-specific flags that zig doesn't support
    rem Remove -ld_classic flag which is macOS-specific
    set "args=%args:-ld_classic =%"
    set "args=%args: -ld_classic=%"
    
    rem Remove problematic libraries that may not be available during cross-compilation
    set "args=%args:-lswiftCore =%"
    set "args=%args: -lswiftCore=%"
    set "args=%args:-lswiftFoundation =%"
    set "args=%args: -lswiftFoundation=%"
    set "args=%args:-licucore =%"
    set "args=%args: -licucore=%"
    set "args=%args:-L/usr/lib/swift =%"
    set "args=%args: -L/usr/lib/swift=%"
    set "args=%args:-lobjc =%"
    set "args=%args: -lobjc=%"
    set "args=%args:-lz =%"
    set "args=%args: -lz=%"
    set "args=%args:-ldl =%"
    set "args=%args: -ldl=%"
    set "args=%args:-lm =%"
    set "args=%args: -lm=%"
    
    rem Remove frameworks that may cause issues in cross-compilation
    set "args=%args:-framework CryptoKit =%"
    set "args=%args: -framework CryptoKit=%"
    set "args=%args:-framework GSS =%"
    set "args=%args: -framework GSS=%"
    set "args=%args:-framework CoreFoundation =%"
    set "args=%args: -framework CoreFoundation=%"
    set "args=%args:-framework Foundation =%"
    set "args=%args: -framework Foundation=%"
    set "args=%args:-framework Security =%"
    set "args=%args: -framework Security=%"
    
    rem Note: Cross-compilation to macOS has inherent limitations
    echo Warning: Cross-compilation removes system libraries/frameworks that may be required at runtime
    
) else (
    rem Linux-specific argument handling (existing logic)
    
    rem Works around zlib not being available with zig. This is not great.
    set "args=%args:-lz =%"
    set "args=%args: -lz=%"

    rem Work around a .NET 8 Preview 6 issue
    set "args=%args:'-Wl,-rpath,$ORIGIN'=-Wl,-rpath,$ORIGIN%"

    rem Work around parameters unsupported by zig. Just drop them from the command line.
    set "args=%args:--discard-all=--as-needed%"
    
    rem Remove -pie and -Wl,-pie flags precisely using iterative approach
    call :filter_pie_flags args
    
    rem Remove other unsupported flags
    set "args=%args: -Wl,-e0x0 =%"
    set "args=%args:-Wl,-e0x0 =%"
    set "args=%args: -Wl,-e0x0=%"
    set "args=%args:-Wl,-e0x0=%"

    rem Works around zig linker dropping necessary parts of the executable.
    set "args=-Wl,-u,__Module %args%"
)

rem Run zig cc
zig cc %args%
exit /B %ERRORLEVEL%

:filter_pie_flags
rem Helper function to filter out -pie and -Wl,-pie flags precisely
rem Usage: call :filter_pie_flags variable_name
setlocal enabledelayedexpansion
set "var_name=%~1"
call set "input_args=%%%~1%%"
set "output_args="

rem Split args and filter
for %%a in (%input_args%) do (
    set "current_arg=%%a"
    if not "!current_arg!"=="-pie" (
        if not "!current_arg!"=="-Wl,-pie" (
            if defined output_args (
                set "output_args=!output_args! !current_arg!"
            ) else (
                set "output_args=!current_arg!"
            )
        )
    )
)

endlocal & set "%var_name%=%output_args%"
goto :EOF
