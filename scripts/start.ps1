param([string]$LanHost)

$ErrorActionPreference = "Stop"

if ($LanHost) {
  if ($LanHost -match '[/\s:]' -or $LanHost.StartsWith('-')) {
    throw "LanHost must be a hostname or IPv4 address without scheme or port."
  }
  $env:PHX_HOST = $LanHost
  $env:HANDBEAN_PUBLIC_BIND = "1"
  $env:HANDBEAN_ALLOW_HTTP = "1"
  $env:HANDBEAN_ACCESS_MODE = "password"
}

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
  $erts = Get-ChildItem -Directory -Path (Join-Path $releaseRoot "erts-*") -ErrorAction SilentlyContinue |
    Select-Object -First 1
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

if ($env:HANDBEAN_PUBLIC_BIND -eq "1") {
  Write-Warning "安全提醒：请设置足够长、随机且不重复使用的强密码，建议用密码管理器生成。"
  Write-Warning "Security reminder: use a long, random, unique strong password; a password manager is recommended."
}

if ($env:HANDBEAN_PUBLIC_BIND -eq "1" -and -not $env:HANDBEAN_ACCESS_PASSWORD) {
  $password = Read-Host "Web UI password / Web UI 密码" -AsSecureString
  $pointer = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($password)
  try {
    $env:HANDBEAN_ACCESS_PASSWORD = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
  } finally {
    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
    $password.Dispose()
  }
  if (-not $env:HANDBEAN_ACCESS_PASSWORD) { throw "HANDBEAN_ACCESS_PASSWORD must not be empty." }
}

if (-not $env:HOME -and $env:USERPROFILE) { $env:HOME = $env:USERPROFILE }
$data = Join-Path $env:USERPROFILE ".handbean"
New-Item -ItemType Directory -Force -Path $data | Out-Null
if (-not $env:DATABASE_PATH) { $env:DATABASE_PATH = Join-Path $data "handbean.db" }
if (-not $env:HANDBEAN_WORKSPACES_FILE) { $env:HANDBEAN_WORKSPACES_FILE = Join-Path $data "workspaces.json" }
Add-ExperimentalToolchain $data $releaseRoot
if (-not $env:SECRET_KEY_BASE) {
  $bytes = New-Object byte[] 48
  [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
  $env:SECRET_KEY_BASE = [Convert]::ToBase64String($bytes)
}

if ($env:HANDBEAN_PUBLIC_BIND -eq "1") {
  Write-Host "Handbean listening on 0.0.0.0:$($env:PORT) (password authentication required)"
  if ($env:HANDBEAN_ALLOW_HTTP -eq "1") {
    Write-Host "Address: http://$($env:PHX_HOST):$($env:PORT)"
  } else {
    Write-Host "Public address: https://$($env:PHX_HOST) (configure a TLS reverse proxy)"
  }
} else {
  Write-Host "Handbean local only: http://$($env:PHX_HOST):$($env:PORT)"
}
if ($env:HANDBEAN_ALLOW_HTTP -eq "1") {
  Write-Warning "警告：HTTP 不加密密码或通信内容，仅用于受信任网络。"
  Write-Warning "HTTP does not encrypt passwords or traffic. Use trusted networks only."
}
Write-Host "Stop with Ctrl+C"
& "$releaseRoot\bin\handbean.bat" start
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
