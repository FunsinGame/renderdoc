<#
.SYNOPSIS
    One-click RenderDoc Windows x64 build and package script.

.DESCRIPTION
    Builds the Win32 (x86) and x64 Release configurations of the RenderDoc
    solution, stages the runtime files needed by the 64-bit installer, creates
    a portable ZIP, and (unless -NoMsi is used) builds RenderDoc_<ver>_x64.msi.

    The x86 build is included so the 64-bit package can also capture 32-bit
    processes, matching the layout of RenderDoc's official 64-bit installer.

.PARAMETER NoMsi
    Skip the MSI step (ZIP is still produced).

.PARAMETER NoZip
    Skip the portable ZIP step.

.PARAMETER Clean
    Remove previous build outputs before starting.

.PARAMETER SkipBuild
    Reuse existing x64/Release and Win32/Release outputs and only re-package.

.EXAMPLE
    build-windows-x64.cmd
    build-windows-x64.cmd -NoMsi
    build-windows-x64.cmd -Clean
#>
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# Windows PowerShell 5.1 can otherwise negotiate an obsolete TLS version for
# the dependency downloads below.
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

# This script is normally launched by build-windows-x64.cmd through
# Invoke-Expression, because some machines block unsigned .ps1 files at the
# AppLocker/WDAC layer regardless of PowerShell's execution policy.  The cmd
# wrapper maps its switches to these environment variables; direct -File usage
# still works with the defaults below.
$NoMsi = $env:RDC_NO_MSI -eq "1"
$NoZip = $env:RDC_NO_ZIP -eq "1"
$Clean = $env:RDC_CLEAN -eq "1"
$SkipBuild = $env:RDC_SKIP_BUILD -eq "1"

$Support = if ($env:RDC_BUILD_SUPPORT) { $env:RDC_BUILD_SUPPORT } elseif ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$Repo = if ($env:RDC_BUILD_REPO) { $env:RDC_BUILD_REPO } else { Split-Path -Parent $Support }
$Deps = Join-Path $Repo "deps"
$Dist = Join-Path $Repo "dist"

function Write-Step([string]$Message) {
    Write-Host ""
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Fail([string]$Message) {
    throw "[build-windows-x64] $Message"
}

function Download-File([string]$Url, [string]$Destination) {
    if ((Test-Path $Destination) -and ((Get-Item $Destination).Length -gt 0)) {
        Write-Host "    cached: $Destination"
        return
    }
    New-Item -ItemType Directory -Force -Path (Split-Path $Destination) | Out-Null
    if (Test-Path $Destination) { Remove-Item $Destination -Force }

    Write-Host "    downloading: $Url"
    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($curl) {
        & $curl.Source -L --fail --retry 3 --connect-timeout 30 -o $Destination $Url
        if ($LASTEXITCODE -eq 0 -and (Test-Path $Destination) -and ((Get-Item $Destination).Length -gt 0)) {
            return
        }
        Remove-Item $Destination -Force -ErrorAction SilentlyContinue
    }

    try {
        Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing
    } catch {
        Fail "download failed: $Url`n$($_.Exception.Message)"
    }
    if (!(Test-Path $Destination) -or ((Get-Item $Destination).Length -eq 0)) {
        Fail "download produced an empty file: $Url"
    }
}

function Expand-Zip([string]$Zip, [string]$Destination) {
    if (Test-Path $Destination) { Remove-Item $Destination -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    & tar.exe -xf $Zip -C $Destination
    if ($LASTEXITCODE -ne 0) {
        Expand-Archive -LiteralPath $Zip -DestinationPath $Destination -Force
    }
}

function Get-RenderDocVersion {
    $header = Join-Path $Repo "renderdoc\api\replay\version.h"
    if (!(Test-Path $header)) { Fail "version header not found: $header" }
    $text = Get-Content $header -Raw
    $major = [regex]::Match($text, '#define\s+RENDERDOC_VERSION_MAJOR\s+(\d+)').Groups[1].Value
    $minor = [regex]::Match($text, '#define\s+RENDERDOC_VERSION_MINOR\s+(\d+)').Groups[1].Value
    if (!$major -or !$minor) { Fail "could not parse RenderDoc version from $header" }
    return "$major.$minor"
}

function Find-MSBuild {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
    if (!(Test-Path $vswhere)) {
        Fail "vswhere.exe not found. Install Visual Studio with the Desktop development with C++ workload."
    }
    $vsPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath | Select-Object -First 1
    if (!$vsPath) {
        $vsPath = & $vswhere -latest -products * -property installationPath | Select-Object -First 1
    }
    if (!$vsPath) {
        Fail "no Visual Studio C++ toolchain found. Install 'Desktop development with C++'."
    }
    $candidates = @(
        (Join-Path $vsPath "MSBuild\Current\Bin\MSBuild.exe"),
        (Join-Path $vsPath "MSBuild\15.0\Bin\MSBuild.exe")
    )
    foreach ($candidate in $candidates) {
        if (Test-Path $candidate) {
            return [pscustomobject]@{ MSBuild = $candidate; VSPath = $vsPath }
        }
    }
    Fail "MSBuild.exe not found under $vsPath"
}

function Get-CrtDirectory([string]$Arch) {
    $redistRoot = Join-Path $vsInfo.VSPath "VC\Redist\MSVC"
    if (!(Test-Path $redistRoot)) { Fail "VC redist directory not found: $redistRoot" }
    $match = Get-ChildItem $redistRoot -Recurse -Filter "vcruntime140.dll" -ErrorAction SilentlyContinue |
        Where-Object {
            $_.FullName -match "\\$Arch\\" -and
            $_.FullName -notmatch "\\onecore\\" -and
            $_.FullName -notmatch "\\debug_nonredist\\"
        } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if (!$match) { Fail "could not find $Arch VC runtime under $redistRoot" }
    return $match.Directory.FullName
}

function Copy-CrtFiles([string]$Arch, [string]$Destination) {
    $crtDir = Get-CrtDirectory $Arch
    $names = @("vcruntime140.dll", "msvcp140.dll", "msvcp140_1.dll", "msvcp140_2.dll", "concrt140.dll")
    if ($Arch -eq "x64") { $names = @("vcruntime140.dll", "vcruntime140_1.dll") + $names }
    foreach ($name in $names | Select-Object -Unique) {
        $source = Join-Path $crtDir $name
        if (Test-Path $source) {
            Copy-Item $source (Join-Path $Destination $name) -Force
        }
    }
}

function Prepare-PythonOverride([string]$Arch) {
    $platform = if ($Arch -eq "x64") { "x64" } else { "Win32" }
    $embedName = if ($Arch -eq "x64") { "python36-embed-amd64" } else { "python36-embed-win32" }
    $override = Join-Path $Deps "python36-$Arch"
    $embed = Join-Path $Deps $embedName
    $pyside = Join-Path $Deps "qrenderdoc_3rdparty\qrenderdoc\3rdparty\pyside"

    if (!(Test-Path $embed)) { Fail "Python embeddable directory missing: $embed" }
    if (!(Test-Path (Join-Path $pyside "include\PySide2\pyside.h"))) {
        Fail "qrenderdoc_3rdparty.zip was not extracted correctly (PySide2 headers missing)."
    }

    Remove-Item $override -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path (Join-Path $override "include") | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $override $platform) | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $override "pyside") | Out-Null

    Copy-Item (Join-Path $Repo "qrenderdoc\3rdparty\python\include\*") (Join-Path $override "include") -Recurse -Force
    Copy-Item (Join-Path $Repo "qrenderdoc\3rdparty\python\python36.zip") $override -Force
    Copy-Item (Join-Path $Repo "qrenderdoc\3rdparty\python\$platform\python36.dll") (Join-Path $override $platform) -Force
    Copy-Item (Join-Path $Repo "qrenderdoc\3rdparty\python\$platform\python36.lib") (Join-Path $override $platform) -Force

    Copy-Item (Join-Path $embed "*.pyd") (Join-Path $override $platform) -Force -ErrorAction SilentlyContinue
    Copy-Item (Join-Path $embed "sqlite3.dll") (Join-Path $override $platform) -Force -ErrorAction SilentlyContinue
    Copy-Item (Join-Path $embed "python36.zip") $override -Force

    Copy-Item (Join-Path $pyside "include") (Join-Path $override "pyside") -Recurse -Force
    Copy-Item (Join-Path $pyside $platform) (Join-Path $override "pyside") -Recurse -Force

    if (!(Test-Path (Join-Path $override "pyside\$platform\shiboken2.lib"))) {
        Fail "PySide2 import library missing for $Arch"
    }
    return $override
}

function Invoke-Build([string]$Arch, [string]$PythonOverride) {
    $log = Join-Path $Repo "build-$Arch.log"
    Write-Step "Building RenderDoc $Arch Release"
    $msbuildArgs = @(
        "renderdoc.sln",
        "/nologo",
        "/p:Configuration=Release",
        "/p:Platform=$Arch",
        "/p:TrackFileAccess=false",
        "/p:VSPythonOverridePath=$PythonOverride",
        "/flp:LogFile=$log;Verbosity=minimal"
    )
    & $vsInfo.MSBuild @msbuildArgs
    if ($LASTEXITCODE -ne 0) {
        if (Test-Path $log) { Get-Content $log -Tail 60 | Write-Host }
        Fail "$Arch build failed (exit $LASTEXITCODE). See $log"
    }
}

function Stage-X64 {
    $out = Join-Path $Dist "Release64"
    Remove-Item $out -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $out | Out-Null

    Write-Step "Staging x64 runtime files"
    $roboArgs = @(
        (Join-Path $Repo "x64\Release"),
        $out,
        "/E",
        "/XD", "obj", "pymodules",
        "/XF", "*.lib", "*.exp", "*.pdb", "*.ipdb", "*.iobj", "renderdocui.exe",
        "/NFL", "/NDL", "/NJH", "/NJS", "/NC", "/NS", "/NP"
    )
    & robocopy @roboArgs | Out-Null
    if ($LASTEXITCODE -gt 7) { Fail "robocopy failed staging x64 output (exit $LASTEXITCODE)" }

    # OpenSSL used by QtNetwork / Python _ssl.
    $openSsl = Join-Path $Deps "qrenderdoc_3rdparty\qrenderdoc\3rdparty\qt\x64\bin"
    foreach ($name in @("libcrypto-1_1-x64.dll", "libssl-1_1-x64.dll")) {
        $source = Join-Path $openSsl $name
        if (!(Test-Path $source)) { Fail "OpenSSL DLL not found: $source" }
        Copy-Item $source (Join-Path $out $name) -Force
    }

    Copy-CrtFiles "x64" $out

    # Files referenced by Installer64.custom.wxs but not always copied by the
    # qrenderdoc project's Content items.
    foreach ($name in @("_decimal.pyd", "_sqlite3.pyd", "sqlite3.dll")) {
        $source = Join-Path (Join-Path $Deps "python36-x64\x64") $name
        if (Test-Path $source) {
            Copy-Item $source (Join-Path $out $name) -Force
        }
    }

    Write-Step "Staging x64 plugins"
    $pluginSource = Join-Path $Deps "plugins\plugins-win64"
    if (!(Test-Path $pluginSource)) { Fail "Win64 plugins missing: $pluginSource" }
    New-Item -ItemType Directory -Force -Path (Join-Path $out "plugins") | Out-Null
    Copy-Item (Join-Path $pluginSource "*") (Join-Path $out "plugins") -Recurse -Force

    Write-Step "Staging 32-bit capture support (x86)"
    $x86 = Join-Path $out "x86"
    New-Item -ItemType Directory -Force -Path $x86 | Out-Null
    $x86Files = @(
        "renderdoc.dll", "renderdoc.json", "d3dcompiler_47.dll",
        "renderdocshim32.dll", "renderdoccmd.exe", "dbghelp.dll",
        "symsrv.dll", "symsrv.yes"
    )
    foreach ($name in $x86Files) {
        $source = Join-Path $Repo "Win32\Release\$name"
        if (!(Test-Path $source)) { Fail "32-bit capture file missing: $source" }
        Copy-Item $source (Join-Path $x86 $name) -Force
    }
    Copy-CrtFiles "x86" $x86

    if (!(Test-Path (Join-Path $out "qrenderdoc.exe"))) { Fail "qrenderdoc.exe missing from x64 output" }
    if (!(Test-Path (Join-Path $out "renderdoc.dll"))) { Fail "renderdoc.dll missing from x64 output" }
}

function New-ZipPackage([string]$Version) {
    if ($NoZip) { return }
    $zip = Join-Path $Repo "RenderDoc_${Version}_x64.zip"
    Remove-Item $zip -Force -ErrorAction SilentlyContinue
    Write-Step "Creating portable ZIP: $(Split-Path -Leaf $zip)"
    Compress-Archive -Path (Join-Path $Dist "Release64\*") -DestinationPath $zip -CompressionLevel Optimal
    return $zip
}

function New-MsiPackage([string]$Version) {
    if ($NoMsi) { return }

    $wixDir = Join-Path $Deps "wix311"
    $candle = Join-Path $wixDir "candle.exe"
    $light = Join-Path $wixDir "light.exe"
    if (!(Test-Path $candle) -or !(Test-Path $light)) {
        Write-Step "Preparing WiX Toolset 3.11"
        $wixZip = Join-Path $Deps "wix311-binaries.zip"
        Download-File "https://github.com/wixtoolset/wix3/releases/download/wix3112rtm/wix311-binaries.zip" $wixZip
        Expand-Zip $wixZip $wixDir
    }

    Write-Step "Building x64 MSI"
    $wxs = Join-Path $Support "Installer64.custom.wxs"
    if (!(Test-Path $wxs)) { Fail "installer definition missing: $wxs" }
    $obj = Join-Path $Dist "Installer64.wixobj"
    Remove-Item $obj -Force -ErrorAction SilentlyContinue
    $env:RENDERDOC_VERSION = $Version

    & $candle -o $obj $wxs | Out-Host
    if ($LASTEXITCODE -ne 0) { Fail "candle failed (exit $LASTEXITCODE)" }

    $msi = Join-Path $Repo "RenderDoc_${Version}_x64.msi"
    Remove-Item $msi -Force -ErrorAction SilentlyContinue
    & $light -sval -ext WixUIExtension -sw1076 -loc (Join-Path $Repo "util\installer\customtext.wxl") -o $msi $obj | Out-Host
    if ($LASTEXITCODE -ne 0) { Fail "light failed (exit $LASTEXITCODE)" }
    if (!(Test-Path $msi)) { Fail "MSI was not created: $msi" }
    return $msi
}

function Write-Checksum([string]$File) {
    if (!(Test-Path $File)) { return }
    $hash = (Get-FileHash -LiteralPath $File -Algorithm SHA256).Hash
    $line = "$hash  $(Split-Path -Leaf $File)"
    Set-Content -LiteralPath "$File.sha256" -Value $line -Encoding ASCII
}

try {
    Set-Location $Repo
    Write-Host "RenderDoc Windows x64 one-click build" -ForegroundColor Green
    Write-Host "Repository: $Repo"

    $vsInfo = Find-MSBuild
    Write-Host "Visual Studio: $($vsInfo.VSPath)"
    Write-Host "MSBuild: $($vsInfo.MSBuild)"

    $version = Get-RenderDocVersion
    Write-Host "RenderDoc version: $version"

    if ($Clean) {
        Write-Step "Cleaning previous outputs"
        Remove-Item (Join-Path $Repo "x64\Release") -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item (Join-Path $Repo "Win32\Release") -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item (Join-Path $Dist "Release64") -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item (Join-Path $Repo "RenderDoc_${version}_x64.zip") -Force -ErrorAction SilentlyContinue
        Remove-Item (Join-Path $Repo "RenderDoc_${version}_x64.msi") -Force -ErrorAction SilentlyContinue
    }

    Write-Step "Preparing third-party inputs"
    New-Item -ItemType Directory -Force -Path $Deps | Out-Null
    $qrenderdocZip = Join-Path $Deps "qrenderdoc_3rdparty.zip"
    $pluginsZip = Join-Path $Deps "plugins.zip"
    $py64Zip = Join-Path $Deps "python36-embed-amd64.zip"
    $py32Zip = Join-Path $Deps "python36-embed-win32.zip"

    # Accept the filenames used by older build notes/workspaces as a cache.
    if (!(Test-Path $py64Zip) -and (Test-Path (Join-Path $Deps "python36-embed-x64.zip"))) {
        Copy-Item (Join-Path $Deps "python36-embed-x64.zip") $py64Zip -Force
    }
    if (!(Test-Path $py32Zip) -and (Test-Path (Join-Path $Deps "python36-embed.zip"))) {
        Copy-Item (Join-Path $Deps "python36-embed.zip") $py32Zip -Force
    }

    Download-File "https://renderdoc.org/qrenderdoc_3rdparty.zip" $qrenderdocZip
    Download-File "https://renderdoc.org/plugins.zip" $pluginsZip
    Download-File "https://www.python.org/ftp/python/3.6.8/python-3.6.8-embed-amd64.zip" $py64Zip
    Download-File "https://www.python.org/ftp/python/3.6.8/python-3.6.8-embed-win32.zip" $py32Zip

    if (!(Test-Path (Join-Path $Deps "qrenderdoc_3rdparty\qrenderdoc\3rdparty\pyside\include\PySide2\pyside.h"))) {
        Expand-Zip $qrenderdocZip (Join-Path $Deps "qrenderdoc_3rdparty")
    }
    if (!(Test-Path (Join-Path $Deps "plugins\plugins-win64\d3d12\dxcompiler.dll"))) {
        Expand-Zip $pluginsZip (Join-Path $Deps "plugins")
    }
    if (!(Test-Path (Join-Path $Deps "python36-embed-amd64\python.exe"))) {
        Expand-Zip $py64Zip (Join-Path $Deps "python36-embed-amd64")
    }
    if (!(Test-Path (Join-Path $Deps "python36-embed-win32\python.exe"))) {
        Expand-Zip $py32Zip (Join-Path $Deps "python36-embed-win32")
    }

    $py64 = Prepare-PythonOverride "x64"
    $py32 = Prepare-PythonOverride "x86"

    if (!$SkipBuild) {
        Invoke-Build "x64" $py64
        Invoke-Build "x86" $py32
    } else {
        if (!(Test-Path (Join-Path $Repo "x64\Release\qrenderdoc.exe"))) { Fail "x64 build output missing (do not use -SkipBuild)" }
        if (!(Test-Path (Join-Path $Repo "Win32\Release\renderdoc.dll"))) { Fail "x86 build output missing (do not use -SkipBuild)" }
    }

    Stage-X64

    $zip = New-ZipPackage $version
    $msi = New-MsiPackage $version

    Write-Step "Artifacts"
    $artifacts = @()
    if ($msi) { $artifacts += (Resolve-Path $msi).Path }
    if ($zip) { $artifacts += (Resolve-Path $zip).Path }
    $artifacts += (Resolve-Path (Join-Path $Dist "Release64")).Path
    foreach ($artifact in $artifacts) {
        $item = Get-Item $artifact
        if ($item.PSIsContainer) {
            Write-Host ("  DIR  {0}" -f $item.FullName)
        } else {
            Write-Host ("  FILE {0}  ({1:N1} MB)" -f $item.FullName, ($item.Length / 1MB))
            Write-Checksum $item.FullName
        }
    }
    Write-Host ""
    Write-Host "Build completed successfully." -ForegroundColor Green
} catch {
    Write-Host ""
    Write-Host "BUILD FAILED" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}
