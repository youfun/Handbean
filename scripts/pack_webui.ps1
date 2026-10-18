# Build a self-contained Web UI OTP release and zip it.
# Usage: powershell -File scripts/pack_webui.ps1 windows-amd64
$ErrorActionPreference = "Stop"
$target = $args[0]
if (-not $target) { throw "target name required, e.g. windows-amd64" }

$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

mix local.hex --force
mix local.rebar --force
mix deps.get
npm ci
$env:MIX_ENV = "prod"
mix compile
mix esbuild.install --if-missing
mix assets.deploy
mix release --overwrite

$release = Join-Path $root "_build\prod\rel\handbean"
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

$startInvocation = Select-String -Path $startScript -Pattern '^\s*&\s+"\$PSScriptRoot\\bin\\handbean\.bat"\s+([A-Za-z0-9_]+)\s*$'
if (@($startInvocation).Count -ne 1) {
    throw "start.ps1 must invoke bin\handbean.bat with exactly one release command"
}
$releaseCommand = $startInvocation.Matches[0].Groups[1].Value
$commandDeclaration = 'if "%~1" == "' + $releaseCommand + '"'
if (-not (Select-String -Path $releaseLauncher -SimpleMatch $commandDeclaration -Quiet)) {
    throw "start.ps1 calls unsupported release command '$releaseCommand'"
}

$archive = Join-Path $root "handbean-web-$target.zip"
$sum = "$archive.sha256"
if (Test-Path $archive) { Remove-Item $archive -Force }
if (Test-Path $sum) { Remove-Item $sum -Force }
tar -a -c -f $archive -C $release .
$hash = (Get-FileHash $archive -Algorithm SHA256).Hash.ToLower()
"$hash  $(Split-Path $archive -Leaf)" | Set-Content -Encoding ascii $sum
