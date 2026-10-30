# Run by Mix from the Ghostty dependency directory.
$ErrorActionPreference = "Stop"

function Resolve-Zig016 {
  $zigCmd = Get-Command zig -ErrorAction SilentlyContinue
  if ($zigCmd) {
    $ver = (& $zigCmd.Source version 2>$null) -join ""
    if ($ver.Trim() -eq "0.16.0") {
      return
    }
  }

  $candidates = @(
    $env:GHOSTTY_ZIG_DIR,
    "D:\tools\zig-x86_64-windows-0.16.0",
    (Join-Path $env:LOCALAPPDATA "zigler\Cache\zig-x86_64-windows-0.16.0"),
    (Join-Path $env:LOCALAPPDATA "mise\installs\zig\0.16.0"),
    (Join-Path $env:USERPROFILE ".version-fox\cache\zig\current")
  ) | Where-Object { $_ -and (Test-Path -LiteralPath (Join-Path $_ "zig.exe")) }

  foreach ($dir in $candidates) {
    $zigExe = Join-Path $dir "zig.exe"
    $ver = (& $zigExe version 2>$null) -join ""
    if ($ver.Trim() -eq "0.16.0") {
      $env:PATH = "$dir;$env:PATH"
      return
    }
  }
}

Resolve-Zig016
$zigVersion = ((& zig version 2>$null) -join "").Trim()
if ($zigVersion -ne "0.16.0") {
  [Console]::Error.WriteLine("Ghostty source builds require Zig 0.16.0 (see mise.toml).")
  exit 1
}

$env:GHOSTTY_BUILD = "1"

$projectRoot = Split-Path -Parent $PSScriptRoot
$depRoot = (Get-Location).Path

$env:MIX_ENV = "dev"
$env:MIX_BUILD_PATH = Join-Path $depRoot "_build\handbean"
if (-not $env:MIX_DEPS_PATH) {
  $env:MIX_DEPS_PATH = Join-Path $projectRoot "deps"
}

$compiledLibDir = Join-Path $env:MIX_BUILD_PATH "lib\ghostty\priv\lib"
$compileArgs = @("--no-deps-check", "--no-archives-check", "--no-prune-code-paths", "--no-protocol-consolidation")

& elixir -r lib/mix/tasks/ghostty.setup.ex -S mix ghostty.setup
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$terminalNifBuilt = Join-Path $compiledLibDir "Elixir.Ghostty.Terminal.Nif.dll"
$ptyNifBuilt = Join-Path $compiledLibDir "Elixir.Ghostty.PTY.Nif.dll"
if (-not (Test-Path -LiteralPath $terminalNifBuilt) -or -not (Test-Path -LiteralPath $ptyNifBuilt)) {
  $compileArgs = @("--force") + $compileArgs
}

& elixir -S mix compile @compileArgs
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$ebinDest = Join-Path $depRoot "ebin"
New-Item -ItemType Directory -Force -Path $ebinDest | Out-Null
$builtEbin = Join-Path $env:MIX_BUILD_PATH "lib\ghostty\ebin"
Get-ChildItem -LiteralPath $builtEbin -Filter "*.beam" | ForEach-Object {
  Copy-Item -LiteralPath $_.FullName -Destination $ebinDest -Force
}
Copy-Item -LiteralPath (Join-Path $builtEbin "ghostty.app") -Destination $ebinDest -Force

$libDir = Join-Path $depRoot "priv\lib"
New-Item -ItemType Directory -Force -Path $libDir | Out-Null
foreach ($nif in @("Elixir.Ghostty.Terminal.Nif.dll", "Elixir.Ghostty.PTY.Nif.dll")) {
  $src = Join-Path $compiledLibDir $nif
  $dst = Join-Path $libDir $nif
  if ([IO.Path]::GetFullPath($src) -ne [IO.Path]::GetFullPath($dst)) {
    Copy-Item -LiteralPath $src -Destination $dst -Force
  }
}
$staticLib = Join-Path $libDir "ghostty-vt-static.lib"
if (Test-Path -LiteralPath $staticLib) {
  Remove-Item -LiteralPath $staticLib -Force
}
