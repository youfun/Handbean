# Install a native Windows ARM64 OTP 29 and Elixir 1.20 onto PATH.
# Erlang/OTP does not publish an ARM64 Windows installer. This follows the
# upstream Windows build (WSL shell + MSVC), without wxWidgets.
$ErrorActionPreference = "Stop"
$OtpRoot = "C:\otp-arm64"
$ElixirRoot = "C:\elixir-1.20-otp-29"
$OtpVersion = "29.0"
$ElixirZip = "https://github.com/elixir-lang/elixir/releases/download/v1.20.0/elixir-otp-29.zip"

function Add-GithubPath([string]$Path) {
  if (Test-Path $Path) {
    Add-Content -Path $env:GITHUB_PATH -Value $Path
    $env:PATH = "$Path;$env:PATH"
  }
}

$cachedErl = Get-ChildItem -Path $OtpRoot -Filter erl.exe -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
if ($cachedErl -and (Test-Path "$ElixirRoot\bin\elixir.bat")) {
  Add-GithubPath $cachedErl.DirectoryName
  Add-GithubPath "$ElixirRoot\bin"
  Write-Host "Using cached OTP and Elixir"
  & $cachedErl.FullName -noshell -eval 'io:format("~s~n", [erlang:system_info(system_architecture)]), halt().'
  exit 0
}

Write-Host "Installing WSL Ubuntu for the OTP ARM64 build"
wsl --status
wsl --install -d Ubuntu --no-launch
if ($LASTEXITCODE -ne 0) {
  Write-Host "wsl --install failed with exit $LASTEXITCODE"
  throw "WSL Ubuntu is required to build native Windows ARM64 OTP, and it could not be installed on this runner. GitHub-hosted ARM runners cannot reboot to finish enabling WSL, and OTP publishes no Windows ARM64 installer."
}
wsl -d Ubuntu -e true
if ($LASTEXITCODE -ne 0) {
  throw "WSL Ubuntu did not start. A reboot may be required; GitHub-hosted runners cannot reboot mid-job."
}

$workspace = (Get-Location).Path
$wslWorkspace = (wsl -d Ubuntu -u root -- wslpath -a $workspace).Trim()
wsl -d Ubuntu -u root -- bash -lc "cd '$wslWorkspace' && bash scripts/ci/build_otp_windows_arm64.sh '$OtpVersion' '/mnt/c/otp-arm64' '/mnt/c/vcpkg'"
if ($LASTEXITCODE -ne 0) { throw "OTP ARM64 build failed" }

if (-not (Test-Path "$ElixirRoot\bin\elixir.bat")) {
  $zip = Join-Path $env:RUNNER_TEMP "elixir-otp-29.zip"
  Invoke-WebRequest -Uri $ElixirZip -OutFile $zip
  New-Item -ItemType Directory -Force -Path $ElixirRoot | Out-Null
  tar -xf $zip -C $ElixirRoot
}

$erl = Get-ChildItem -Path $OtpRoot -Filter erl.exe -Recurse | Select-Object -First 1
if (-not $erl) { throw "OTP ARM64 build did not produce erl.exe" }
Add-GithubPath $erl.DirectoryName
Add-GithubPath "$ElixirRoot\bin"
$arch = & $erl.FullName -noshell -eval 'io:format("~s~n", [erlang:system_info(system_architecture)]), halt().'
Write-Host "OTP architecture: $arch"
if ($arch -notmatch "aarch64|arm64") {
  throw "Built OTP is not ARM64: $arch"
}
