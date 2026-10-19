# Build the experimental Windows amd64 package: the Web UI release plus
# Elixir, Mix, Hex, Rebar3, and MinGit. Does not include a C compiler.
# Run after scripts/pack_webui.ps1 windows-amd64.
$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $false

$ElixirVersion = "1.20.1"
$ElixirUrl = "https://github.com/elixir-lang/elixir/releases/download/v$ElixirVersion/elixir-otp-29.zip"
$GitTag = "v2.49.0.windows.1"
$GitUrl = "https://github.com/git-for-windows/git/releases/download/$GitTag/MinGit-2.49.0-64-bit.zip"
$HexVersion = "2.4.1"

$root = Split-Path -Parent $PSScriptRoot
$tar = Join-Path $env:SystemRoot "System32\tar.exe"
if (-not (Test-Path $tar)) { throw "Windows system tar not found at $tar" }
$release = Join-Path $root "_build\webui-pack\windows-amd64\handbean"
if (-not (Test-Path (Join-Path $release "bin\handbean.bat"))) {
  throw "OTP release missing at $release; run scripts/pack_webui.ps1 windows-amd64 first"
}

$work = Join-Path ([System.IO.Path]::GetTempPath()) ("handbean-toolchain-" + [guid]::NewGuid().ToString("n"))
$stage = Join-Path $work "stage"
$downloads = Join-Path $work "downloads"
New-Item -ItemType Directory -Force -Path $stage, $downloads | Out-Null

function Get-PinnedZip($url, $name) {
  $dest = Join-Path $downloads $name
  Write-Host "download $url"
  Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing
  return $dest
}

function Expand-PinnedZip($zip, $dest) {
  New-Item -ItemType Directory -Force -Path $dest | Out-Null
  & $tar -xf $zip -C $dest
  if ($LASTEXITCODE -ne 0) { throw "failed to extract $zip" }
}

try {
  Write-Host "stage release"
  & robocopy $release $stage /E /NFL /NDL /NJH /NJS /NC /NS
  if ($LASTEXITCODE -ge 8) { throw "robocopy failed: $LASTEXITCODE" }

  $toolchain = Join-Path $stage "toolchain"
  $elixirZip = Get-PinnedZip $ElixirUrl "elixir-otp-29.zip"
  $gitZip = Get-PinnedZip $GitUrl "MinGit.zip"
  Expand-PinnedZip $elixirZip (Join-Path $toolchain "elixir")
  Expand-PinnedZip $gitZip (Join-Path $toolchain "git")

  $mixBat = Join-Path $toolchain "elixir\bin\mix.bat"
  if (-not (Test-Path $mixBat)) {
    $nested = Get-ChildItem -Path (Join-Path $toolchain "elixir") -Filter mix.bat -Recurse | Select-Object -First 1
    if (-not $nested) { throw "elixir zip did not contain bin/mix.bat" }
    $elixirRoot = Split-Path (Split-Path $nested.FullName -Parent) -Parent
    Get-ChildItem $elixirRoot | ForEach-Object {
      Move-Item $_.FullName (Join-Path $toolchain "elixir") -Force
    }
  }
  if (-not (Test-Path (Join-Path $toolchain "git\cmd\git.exe"))) {
    throw "MinGit zip did not contain cmd/git.exe"
  }

  $seed = Join-Path $toolchain "mix-seed"
  New-Item -ItemType Directory -Force -Path $seed | Out-Null
  $previousMixHome = $env:MIX_HOME
  $env:MIX_HOME = $seed
  Write-Host "install Hex $HexVersion and Rebar3 into toolchain seed"
  mix local.hex $HexVersion --force
  if ($LASTEXITCODE -ne 0) { throw "mix local.hex failed: $LASTEXITCODE" }
  mix local.rebar --force
  if ($LASTEXITCODE -ne 0) { throw "mix local.rebar failed: $LASTEXITCODE" }
  if ($previousMixHome) { $env:MIX_HOME = $previousMixHome } else { Remove-Item Env:MIX_HOME }
  if (-not (Get-ChildItem -Path $seed -Filter "hex-$HexVersion*" -Recurse -Directory -ErrorAction SilentlyContinue)) {
    throw "Hex $HexVersion was not installed into $seed"
  }

  Copy-Item -Path (Join-Path $root "scripts\windows\shims") -Destination (Join-Path $toolchain "shims") -Recurse -Force
  @"
Experimental Handbean Windows package.

This archive adds Elixir $ElixirVersion, Mix, Hex $HexVersion, Rebar3, and MinGit to the Web UI release.
start.bat puts those tools first on PATH for this process only. It does not change the system PATH.

No C compiler, Zig, or Node is included. Projects that compile NIFs need Visual Studio Build Tools installed separately.
There is no in-browser terminal.
"@ | Set-Content -Encoding utf8 (Join-Path $toolchain "README.txt")

  $archive = Join-Path $root "handbean-web-windows-amd64-toolchain.zip"
  $sum = "$archive.sha256"
  if (Test-Path $archive) { Remove-Item $archive -Force }
  if (Test-Path $sum) { Remove-Item $sum -Force }
  & $tar -a -c -f $archive -C $stage .
  if ($LASTEXITCODE -ne 0) { throw "failed to zip toolchain package" }
  $hash = (Get-FileHash $archive -Algorithm SHA256).Hash.ToLower()
  "$hash  $(Split-Path $archive -Leaf)" | Set-Content -Encoding ascii $sum
  Write-Host "wrote $archive"
}
finally {
  if (Test-Path $work) { Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue }
}
