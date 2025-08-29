@echo off

@where zig >nul 2>&1
@if ERRORLEVEL 1 (
  echo Error: zig is not on the PATH. Install zig and make sure it's on PATH. Follow instructions at https://github.com/MichalStrehovsky/PublishAotCross.
  exit /B 1
)

set args=%*

rem Check if we're targeting Windows (for cross-compilation from Windows to Windows with different arch)
echo %args% | findstr /C:"--target=" | findstr /C:"windows" >nul
if %ERRORLEVEL%==0 (
    rem Convert Windows linker arguments to GCC/Clang format for Windows targets
    set args=%args:/OUT:=-o %
    set args=%args:/DEF:=-Wl,--output-def,%
    set args=%args:/NOLOGO=%
    set args=%args:/MANIFEST:NO=-Wl,--no-manifest%
    set args=%args:/DEBUG=-g%
    set args=%args:/INCREMENTAL:NO=%
    set args=%args:/SUBSYSTEM:CONSOLE=-Wl,--subsystem,console%
    set args=%args:/SUBSYSTEM:WINDOWS=-Wl,--subsystem,windows%
    set args=%args:/ENTRY:wmainCRTStartup=-Wl,--entry,wmainCRTStartup%
    set args=%args:/NOEXP=%
    set args=%args:/NOIMPLIB=%
    set args=%args:/NODEFAULTLIB:libucrt.lib=%
    set args=%args:/DEFAULTLIB:ucrt.lib=%
    set args=%args:/OPT:REF=-Wl,--gc-sections%
    set args=%args:/OPT:ICF=%
    
    rem Convert Windows library names
    set args=%args:advapi32.lib=-ladvapi32%
    set args=%args:bcrypt.lib=-lbcrypt%
    set args=%args:crypt32.lib=-lcrypt32%
    set args=%args:iphlpapi.lib=-liphlpapi%
    set args=%args:kernel32.lib=-lkernel32%
    set args=%args:mswsock.lib=-lmswsock%
    set args=%args:ncrypt.lib=-lncrypt%
    set args=%args:normaliz.lib=-lnormaliz%
    set args=%args:ntdll.lib=-lntdll%
    set args=%args:ole32.lib=-lole32%
    set args=%args:oleaut32.lib=-loleaut32%
    set args=%args:secur32.lib=-lsecur32%
    set args=%args:user32.lib=-luser32%
    set args=%args:version.lib=-lversion%
    set args=%args:ws2_32.lib=-lws2_32%
) else (
    rem Linux-specific workarounds (existing code)
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
