# Build the Windows GUI shell and zip the directory-style package:
# Handbean.exe beside handbean-web/, mirroring desktop/macos/scripts/build_app.sh.
$ErrorActionPreference = "Stop"

$ROOT = Split-Path -Parent $PSScriptRoot
Set-Location $ROOT
$repoRoot = Split-Path -Parent (Split-Path -Parent $ROOT)
# The checkout may sit on a file system without ownership records; keep the
# Go toolchain from stamping VCS state into the executable.
$env:GOFLAGS = "-buildvcs=false"

$webRoot = Join-Path $ROOT "resources/handbean-web"
$bat = Join-Path $webRoot "bin/handbean.bat"
if (-not (Test-Path $bat)) {
    Write-Warning "$webRoot does not contain bin/handbean.bat."
    Write-Warning "Run scripts/fetch_web_release.ps1 first. The app can attach to a running server, but cannot start one."
}

$version = (Get-Content (Join-Path $repoRoot "version.properties") -Raw | ConvertFrom-StringData).version
if (Test-Path $bat) {
    $erl = ((Get-Content (Join-Path $webRoot "releases/start_erl.data") -Raw).Trim() -split '\s+')
    if ($erl[1] -ne $version) {
        throw "Web release $($erl[1]) does not match version.properties $version"
    }
}

# Inject the release version into mygo.json, and restore the template after.
$configPath = Join-Path $ROOT "mygo.json"
# ReadAllText decodes UTF-8; Windows PowerShell 5.1's Get-Content defaults to
# the ANSI code page and would corrupt non-ASCII text such as the copyright.
$original = [IO.File]::ReadAllText($configPath)
$config = $original | ConvertFrom-Json
$config.version = $version
# WriteAllText writes UTF-8 without a BOM; Windows PowerShell 5.1's
# -Encoding utf8 adds one, which Go's JSON decoder rejects.
[IO.File]::WriteAllText($configPath, ($config | ConvertTo-Json -Depth 10))
try {
    go tool mygo build -platform windows/amd64
    if ($LASTEXITCODE -ne 0) {
        throw "mygo build failed with exit code $LASTEXITCODE"
    }
} finally {
    [IO.File]::WriteAllText($configPath, $original)
}

$dist = Join-Path $ROOT "build/windows-amd64"
$exe = Join-Path $dist "Handbean.exe"
if (-not (Test-Path $exe)) { throw "mygo build produced no $exe" }

$webOut = Join-Path $dist "handbean-web"
$stage = Join-Path $ROOT "build/windows-amd64-package"
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
New-Item -ItemType Directory -Force -Path $stage | Out-Null
Copy-Item $exe (Join-Path $stage "Handbean.exe")
if (Test-Path $webOut) {
    Copy-Item $webOut (Join-Path $stage "handbean-web") -Recurse
} elseif (Test-Path $bat) {
    throw "mygo build did not copy resources/handbean-web next to $exe"
}

$archive = Join-Path $ROOT "Handbean-windows-amd64-experimental.zip"
$sum = "$archive.sha256"
if (Test-Path $archive) { Remove-Item $archive -Force }
if (Test-Path $sum) { Remove-Item $sum -Force }
Compress-Archive -Path (Join-Path $stage "*") -DestinationPath $archive -Force
$hash = (Get-FileHash $archive -Algorithm SHA256).Hash.ToLower()
"$hash  $(Split-Path $archive -Leaf)" | Set-Content -Encoding ascii $sum
Write-Host "Built $archive"
