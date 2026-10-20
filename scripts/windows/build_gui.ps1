# Build the Windows Web UI release and the GUI shell around it, then zip the
# directory-style package. Mirrors the macOS branch of scripts/build.sh.
# Requires Elixir/OTP and Node on PATH (e.g. via vfox), and Visual Studio
# with the C++ workload for the storage NIF.
$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$guiRoot = Join-Path $repoRoot "desktop/mygo"
Set-Location $repoRoot

# Locate the MSVC environment for the storage NIF (Makefile.win).
$vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
$vcvars = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -find "VC\Auxiliary\Build\vcvars64.bat" | Select-Object -First 1
if (-not $vcvars) { throw "Visual Studio with the C++ workload is required to compile the storage NIF" }
$erl = (Get-Command erl.exe -ErrorAction Stop).Source
$otpRoot = Split-Path -Parent (Split-Path -Parent $erl)
$ertsInclude = Get-ChildItem (Join-Path $otpRoot "erts-*\include") -Directory | Select-Object -First 1
if (-not $ertsInclude) { throw "cannot locate the ERTS include directory under $otpRoot" }

# Reuse the Web UI packaging flow, including its start.bat/start.ps1 launchers.
$packScript = Join-Path $repoRoot "scripts/pack_webui.ps1"
$powerShell = (Get-Process -Id $PID).Path
$modulePath = $env:PSModulePath
cmd /d /c ('call "{0}" && set "ERTS_INCLUDE_DIR={1}" && set "PSModulePath={2}" && "{3}" -NoProfile -ExecutionPolicy Bypass -File "{4}" windows-amd64' -f $vcvars, $ertsInclude.FullName, $modulePath, $powerShell, $packScript)
if ($LASTEXITCODE -ne 0) { throw "Web UI build failed with exit code $LASTEXITCODE" }

$zip = Join-Path $repoRoot "handbean-web-windows-amd64.zip"

$env:HANDBEAN_WEB_ZIP = $zip
try {
    & (Join-Path $guiRoot "scripts/fetch_web_release.ps1")
} finally {
    Remove-Item Env:HANDBEAN_WEB_ZIP
}
& (Join-Path $guiRoot "scripts/build_app.ps1")
