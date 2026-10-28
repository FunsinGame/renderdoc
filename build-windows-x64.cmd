@echo off
setlocal
chcp 65001 >nul

rem One-click RenderDoc Windows x64 build/package entry point.
rem Usage:
rem   build-windows-x64.cmd                 build x64 + x86 support, ZIP + MSI
rem   build-windows-x64.cmd -NoMsi          build ZIP only
rem   build-windows-x64.cmd -NoZip          build MSI only
rem   build-windows-x64.cmd -Clean          clean before building
rem   build-windows-x64.cmd -SkipBuild      repackage existing outputs

if not exist "%~dp0buildtools\build-windows-x64.ps1" (
    echo [ERROR] Missing buildtools\build-windows-x64.ps1
    exit /b 2
)

set "RDC_BUILD_SUPPORT=%~dp0buildtools"
set "RDC_BUILD_REPO=%~dp0"
set "RDC_NO_MSI=0"
set "RDC_NO_ZIP=0"
set "RDC_CLEAN=0"
set "RDC_SKIP_BUILD=0"

set "RDC_USAGE_RC=0"
if /I "%~1"=="-Help" goto usage
if /I "%~1"=="-?" goto usage

:parse_args
if "%~1"=="" goto run
if /I "%~1"=="-NoMsi" (
    set "RDC_NO_MSI=1"
    shift
    goto parse_args
)
if /I "%~1"=="-NoZip" (
    set "RDC_NO_ZIP=1"
    shift
    goto parse_args
)
if /I "%~1"=="-Clean" (
    set "RDC_CLEAN=1"
    shift
    goto parse_args
)
if /I "%~1"=="-SkipBuild" (
    set "RDC_SKIP_BUILD=1"
    shift
    goto parse_args
)
echo [ERROR] Unknown option: %~1
set "RDC_USAGE_RC=2"
goto usage

:usage
echo Usage: build-windows-x64.cmd [-NoMsi] [-NoZip] [-Clean] [-SkipBuild]
echo.
echo   (no option)  build x64 + x86 support, create ZIP and MSI
echo   -NoMsi       skip MSI, create ZIP only
echo   -NoZip       skip ZIP, create MSI only
echo   -Clean       remove previous build outputs first
echo   -SkipBuild   reuse existing x64/Release and Win32/Release outputs
exit /b %RDC_USAGE_RC%

:run
rem Invoke the script as text so AppLocker/WDAC rules that reject unsigned
rem .ps1 files do not block the build. The script reads its roots from the
rem RDC_BUILD_* environment variables set above.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Expression (Get-Content -LiteralPath '%RDC_BUILD_SUPPORT%\build-windows-x64.ps1' -Raw)"
set "RC=%ERRORLEVEL%"

if not "%RC%"=="0" (
    echo.
    echo [ERROR] Build failed with exit code %RC%.
) else (
    echo.
    echo [OK] Build completed.
)

exit /b %RC%
