# Windows x64 build script

`build-windows-x64.cmd` is the one-click entry point. It builds RenderDoc in
Release mode for x64 and x86, stages the 64-bit installer layout (including
the `x86` capture-support subfolder), and creates a portable ZIP plus an MSI.

## Requirements

- Windows 10/11 x64
- Visual Studio 2022 or 2026 with **Desktop development with C++**
  (MSBuild, v143/v145 toolset, Windows 10/11 SDK)
- Network access on the first run, to download:
  - `qrenderdoc_3rdparty.zip` (Qt/PySide2 headers and x64 PySide2)
  - `plugins.zip` (Windows plugins)
  - Python 3.6.8 embeddable packages
  - WiX Toolset 3.11 when building the MSI
- `curl.exe`, `tar.exe` (included with Windows 10 1803+) and PowerShell 5.1

Downloads are cached under `deps/`, so later runs are offline-capable.

## Usage

```bat
build-windows-x64.cmd
```

Options:

| Option | Meaning |
| --- | --- |
| *(none)* | Build x64 + x86, create ZIP and MSI |
| `-NoMsi` | Skip the MSI, create the portable ZIP only |
| `-NoZip` | Skip the ZIP, create the MSI only |
| `-Clean` | Remove previous `x64/Release`, `Win32/Release`, and package outputs first |
| `-SkipBuild` | Reuse existing build outputs and only re-stage/re-package |
| `-Help` | Show usage |

## Outputs

- `RenderDoc_<version>_x64.msi`
- `RenderDoc_<version>_x64.zip`
- `RenderDoc_<version>_x64.msi.sha256` / `.zip.sha256`
- `dist/Release64/` — staged runtime tree, including `dist/Release64/x86/`

The MSI is built from `buildtools/Installer64.custom.wxs`. The script skips
WiX ICE validation (`light -sval`) because ICE requires the Windows Installer
service, which is unavailable in restricted/CI sessions; the MSI is still
linked and can be verified with an administrative install.

## Notes

- The x86 build is intentional: the 64-bit installer includes 32-bit capture
  support under `x86/`. Use `-Clean` if you want a full rebuild from scratch.
- The installer currently omits the optional CHM help file and Android APKs,
  because those artifacts are not produced by this source tree/build setup.
- The MSI is unsigned. Windows may show a SmartScreen warning.
- `build-windows-x64.cmd` invokes the PowerShell script through
  `Invoke-Expression` so machines with AppLocker/WDAC rules against unsigned
  `.ps1` files can still run the build.
