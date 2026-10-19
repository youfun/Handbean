# Build a self-contained Web UI OTP release and zip it.
# Usage: powershell -File scripts/pack_webui.ps1 windows-amd64 [-ReleasePath <path>]
[CmdletBinding()]
param(
    [Parameter(Position = 0, Mandatory = $true)]
    [string]$Target,
    [string]$ReleasePath
)

$ErrorActionPreference = "Stop"
if ($Target -ne "windows-amd64") { throw "unsupported Web UI target: $Target" }

$root = Split-Path -Parent $PSScriptRoot
Set-Location $root
if (-not $ReleasePath) {
    $ReleasePath = Join-Path $root "_build\webui-pack\$Target\handbean"
}
$release = [IO.Path]::GetFullPath($ReleasePath)
$tar = Join-Path $env:SystemRoot "System32\tar.exe"
if (-not (Test-Path $tar)) { throw "Windows system tar not found at $tar" }
$lockPath = Join-Path $root "_build\webui-pack.lock"
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $lockPath) | Out-Null
try {
    $lock = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
} catch [IO.IOException] {
    throw "another Web UI package build is already running for this checkout"
}

function Invoke-Native([string]$Description, [scriptblock]$Command) {
    & $Command
    if ($LASTEXITCODE -ne 0) {
        throw "$Description failed with exit code $LASTEXITCODE"
    }
}

try {
    Invoke-Native "mix local.hex" { mix local.hex --force }
    Invoke-Native "mix local.rebar" { mix local.rebar --force }
    Invoke-Native "mix deps.get" { mix deps.get }
    Invoke-Native "npm ci" { npm ci }
    $env:MIX_ENV = "prod"
    Invoke-Native "mix compile" { mix compile }
    Invoke-Native "mix esbuild.install" { mix esbuild.install --if-missing }
    Invoke-Native "mix assets.deploy" { mix assets.deploy }
    Invoke-Native "mix release" { mix release --overwrite --path $release }

$expectedVersion = (Get-Content (Join-Path $root "version.properties") -Raw | ConvertFrom-StringData).version
$actualVersion = ((Get-Content (Join-Path $release "releases\start_erl.data") -Raw).Trim() -split '\s+')[1]
if ($actualVersion -ne $expectedVersion) {
    throw "Web release $actualVersion does not match version.properties $expectedVersion"
}
$startBat = Join-Path $release "start.bat"
$startScript = Join-Path $release "start.ps1"
$releaseLauncher = Join-Path $release "bin\handbean.bat"
Copy-Item (Join-Path $root "scripts\start.bat") $startBat -Force
Copy-Item (Join-Path $root "scripts\start.ps1") $startScript -Force

$startInvocation = Select-String -Path $startScript -Pattern '^\s*&\s+"\$releaseRoot\\bin\\handbean\.bat"\s+([A-Za-z0-9_]+)\s*$'
if (@($startInvocation).Count -ne 1) {
    throw "start.ps1 must invoke bin\handbean.bat with exactly one release command"
}
$releaseCommand = $startInvocation.Matches[0].Groups[1].Value
$commandDeclaration = 'if "%~1" == "' + $releaseCommand + '"'
if (-not (Select-String -Path $releaseLauncher -SimpleMatch $commandDeclaration -Quiet)) {
    throw "start.ps1 calls unsupported release command '$releaseCommand'"
}

    $archive = Join-Path $root "handbean-web-$Target.zip"
    $sum = "$archive.sha256"
    if (Test-Path $archive) { Remove-Item $archive -Force }
    if (Test-Path $sum) { Remove-Item $sum -Force }
    Invoke-Native "Web UI archive creation" { & $tar -a -c -f $archive -C $release . }
    $hash = (Get-FileHash $archive -Algorithm SHA256).Hash.ToLower()
    "$hash  $(Split-Path $archive -Leaf)" | Set-Content -Encoding ascii $sum
} finally {
    $lock.Dispose()
}
