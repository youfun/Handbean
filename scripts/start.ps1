$ErrorActionPreference = "Stop"

$releaseRoot = $PSScriptRoot
if (-not (Test-Path (Join-Path $releaseRoot "bin\handbean.bat"))) {
  $repoRoot = Split-Path -Parent $PSScriptRoot
  $localRoot = Join-Path $repoRoot "_build\local-webui"
  $current = Join-Path $localRoot "current.txt"

  if (Test-Path $current) {
    $releaseID = (Get-Content $current -Raw).Trim()
    if ($releaseID -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
      throw "Invalid local Web UI version pointer: $current"
    }
    $releaseRoot = Join-Path $localRoot "versions\$releaseID"
    if (-not (Test-Path (Join-Path $releaseRoot "bin\handbean.bat"))) {
      throw "Local Web UI version '$releaseID' is incomplete or missing. Re-run scripts\build_webui.bat."
    }
  } else {
    # Backward-compatible fallback for a release built before versioned local builds.
    $releaseRoot = Join-Path $repoRoot "_build\prod\rel\handbean"
  }
}
if (-not (Test-Path (Join-Path $releaseRoot "bin\handbean.bat"))) {
  throw "Web UI release not found. Build one with scripts\build_webui.bat first."
}
Set-Location $releaseRoot

function Add-ExperimentalToolchain($data, $releaseRoot) {
  $toolchain = Join-Path $releaseRoot "toolchain"
  $mixBat = Join-Path $toolchain "elixir\bin\mix.bat"
  if (-not (Test-Path $mixBat)) { return }

  $dirs = @()
  $shims = Join-Path $toolchain "shims"
  $hasCompiler = (Get-Command cl -ErrorAction SilentlyContinue) -or (Get-Command gcc -ErrorAction SilentlyContinue)
  if ((Test-Path $shims) -and -not $hasCompiler) { $dirs += $shims }
  $dirs += (Join-Path $toolchain "elixir\bin")
  $gitCmd = Join-Path $toolchain "git\cmd"
  if (Test-Path $gitCmd) { $dirs += $gitCmd }
  $erts = Get-ChildItem -Directory -Path (Join-Path $releaseRoot "erts-*") -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($erts) { $dirs += (Join-Path $erts.FullName "bin") }

  $existing = @()
  if ($env:PATH) { $existing = $env:PATH.Split(';') }
  $env:PATH = (($dirs + $existing) | Where-Object { $_ } | Select-Object -Unique) -join ';'

  if (-not $env:MIX_HOME) { $env:MIX_HOME = Join-Path $data "mix" }
  $seed = Join-Path $toolchain "mix-seed"
  $archives = Join-Path $env:MIX_HOME "archives"
  if ((Test-Path $seed) -and -not (Test-Path $archives)) {
    New-Item -ItemType Directory -Force -Path $env:MIX_HOME | Out-Null
    Copy-Item -Path (Join-Path $seed "*") -Destination $env:MIX_HOME -Recurse -Force
  }
  if (-not $env:MIX_REBAR3) {
    $rebar = Get-ChildItem -Path $env:MIX_HOME -Recurse -File -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -in @("rebar3", "rebar3.bat", "rebar3.cmd") } |
      Select-Object -First 1
    if ($rebar) { $env:MIX_REBAR3 = $rebar.FullName }
  }

  Write-Host "Experimental toolchain: bundled mix and git are first on PATH"
}

if (-not $env:PHX_SERVER) { $env:PHX_SERVER = "true" }
if (-not $env:PORT) { $env:PORT = "5008" }
if (-not $env:PHX_HOST) { $env:PHX_HOST = "localhost" }

$data = Join-Path $env:USERPROFILE ".handbean"
New-Item -ItemType Directory -Force -Path $data | Out-Null
if (-not $env:DATABASE_PATH) { $env:DATABASE_PATH = Join-Path $data "handbean.db" }
Add-ExperimentalToolchain $data $releaseRoot
if (-not $env:SECRET_KEY_BASE) {
  $bytes = New-Object byte[] 48
  [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
  $env:SECRET_KEY_BASE = [Convert]::ToBase64String($bytes)
}

Write-Host "Handbean http://localhost:$($env:PORT)"
Write-Host "Stop with Ctrl+C"
& "$releaseRoot\bin\handbean.bat" start
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
