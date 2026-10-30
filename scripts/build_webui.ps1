# One-click local Windows build of the Web UI package.
#
# 本机一键编译 Windows Web UI 发布包。本脚本只负责准备本机环境：检查工具链，
# 缺失时用双语报错指出安装方法；找到并加载 MSVC 编译环境（vcvars64）。
# 编译步骤统一委托 scripts/pack_webui.ps1 —— 和 CI 的 pack.yml 调用的是同一个
# 脚本，不维护第二套编译流程。
#
# 用法:
#   双击 scripts\build_webui.bat
#   或 powershell -NoProfile -File scripts\build_webui.ps1 [-Target windows-amd64]
#
# 每次构建写入独立的本地版本目录；成功后更新 current.txt。正在运行的旧版本
# 不会被覆盖，退出并再次运行仓库根目录的 start.bat 后才切换到新版本。
param([string]$Target = "windows-amd64")

$ErrorActionPreference = "Stop"
$utf8 = New-Object Text.UTF8Encoding($false)
[Console]::OutputEncoding = $utf8
$OutputEncoding = $utf8
$root = Split-Path -Parent $PSScriptRoot
$packScript = Join-Path $root "scripts\pack_webui.ps1"
$version = (Get-Content (Join-Path $root "version.properties") -Raw | ConvertFrom-StringData).version
$localRoot = Join-Path $root "_build\local-webui"
$releaseID = "$version-$([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ'))-$PID"
$localRelease = Join-Path $localRoot "versions\$releaseID"

function Stop-Build([string]$Zh, [string]$En) {
  [Console]::Error.WriteLine($Zh)
  [Console]::Error.WriteLine($En)
  exit 1
}

if ($Target -ne "windows-amd64") {
  Stop-Build "本机一键编译只支持 windows-amd64（当前: $Target）；其他目标由 CI 的 pack.yml 构建。" "Local one-click builds only support windows-amd64 (got: $Target); other targets are built by pack.yml in CI."
}
if (-not (Test-Path $packScript)) {
  Stop-Build "未找到 $packScript；请从仓库内运行本脚本。" "pack_webui.ps1 not found at $packScript; run this script from the repo."
}

# A build launched from the running Web UI inherits its release ERTS on PATH.
# That erl.exe expects the running release boot files and cannot drive Mix, so
# retain the installed toolchain while removing only ERTS directories that are
# demonstrably part of an OTP release.
$cleanPath = @()
foreach ($entry in $env:PATH.Split(';')) {
  if (-not $entry) { continue }
  $inspectEntry = $entry.Trim().Trim('"').TrimEnd([char[]]@('\', '/'))
  $erts = Split-Path -Parent $inspectEntry -ErrorAction SilentlyContinue
  $release = if ($erts) { Split-Path -Parent $erts -ErrorAction SilentlyContinue } else { $null }
  $isReleaseERTS =
    $erts -and
    ((Split-Path -Leaf $erts) -like "erts-*") -and
    (Test-Path (Join-Path $release "releases\start_erl.data")) -and
    (Test-Path (Join-Path $release "bin\handbean.bat"))
  if (-not $isReleaseERTS) { $cleanPath += $entry }
}
$env:PATH = $cleanPath -join ';'
foreach ($name in @("ROOTDIR", "BINDIR", "EMU", "PROGNAME", "RELEASE_ROOT", "RELEASE_NAME", "RELEASE_VSN")) {
  Remove-Item "Env:$name" -ErrorAction SilentlyContinue
}

New-Item -ItemType Directory -Force -Path $localRoot | Out-Null
$localBuildLockPath = Join-Path $localRoot "build.lock"
try {
  $localBuildLock = [IO.File]::Open($localBuildLockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
} catch [IO.IOException] {
  Stop-Build "另一个本地 Web UI 构建正在运行，请等待它完成。" "Another local Web UI build is already running; wait for it to finish."
}

try {
# 1) Elixir / Mix（mise.toml 固定 1.20.2-otp-29）
if (-not (Get-Command mix -ErrorAction SilentlyContinue)) {
  Stop-Build "未找到 Elixir/Mix，无法编译。mise.toml 固定 elixir 1.20.2-otp-29；请先安装（推荐 mise 或 vfox），然后重新运行。" "Elixir/Mix not found; cannot build. mise.toml pins elixir 1.20.2-otp-29; install it first (mise or vfox recommended), then run again."
}
$elixirVersion = (& elixir --version 2>$null) -join " "
Write-Host "Elixir: $elixirVersion"
if ($elixirVersion -notmatch "Elixir 1\.20\.") {
  Write-Warning "mise.toml 固定 Elixir 1.20.2-otp-29；当前版本与 CI 不一致，构建可能失败。"
  Write-Warning "mise.toml pins Elixir 1.20.2-otp-29; this version differs from CI and the build may fail."
}

# 2) Node.js / npm（pack_webui.ps1 会执行 npm ci）
$node = Get-Command node -ErrorAction SilentlyContinue
$npm = Get-Command npm -ErrorAction SilentlyContinue
if (-not $node -or -not $npm) {
  Stop-Build "未找到 Node.js/npm；pack_webui.ps1 会执行 npm ci。请先安装 Node.js 24（https://nodejs.org），然后重新运行。" "Node.js/npm not found; pack_webui.ps1 runs npm ci. Install Node.js 24 (https://nodejs.org) first, then run again."
}
Write-Host "Node.js: $(& node --version 2>$null)"

# 3) Windows 系统 tar（pack_webui.ps1 用它打 zip 包）
$tar = Join-Path $env:SystemRoot "System32\tar.exe"
if (-not (Test-Path $tar)) {
  Stop-Build "未找到 Windows 系统 tar：$tar。请在 Windows 10/11 上运行。" "Windows system tar not found at $tar; run on Windows 10 or 11."
}
Write-Host "tar: $tar"

# 4) Zig 0.16.0（Ghostty 终端 NIF 编译需要固定版本 0.16.0）
$zigResolved = $false
$zigCmd = Get-Command zig -ErrorAction SilentlyContinue
if ($zigCmd -and (((& $zigCmd.Source version 2>$null) -join "").Trim() -eq "0.16.0")) {
  $zigResolved = $true
} else {
  $zigCandidates = @(
    $env:GHOSTTY_ZIG_DIR,
    "D:\tools\zig-x86_64-windows-0.16.0",
    (Join-Path $env:LOCALAPPDATA "zigler\Cache\zig-x86_64-windows-0.16.0"),
    (Join-Path $env:LOCALAPPDATA "mise\installs\zig\0.16.0"),
    (Join-Path $env:USERPROFILE ".version-fox\cache\zig\current")
  ) | Where-Object { $_ -and (Test-Path -LiteralPath (Join-Path $_ "zig.exe")) }
  foreach ($dir in $zigCandidates) {
    $zigExe = Join-Path $dir "zig.exe"
    if ((((& $zigExe version 2>$null) -join "").Trim() -eq "0.16.0")) {
      $env:PATH = "$dir;$env:PATH"
      $zigResolved = $true
      break
    }
  }
}
if (-not $zigResolved) {
  Stop-Build "未找到 Zig 0.16.0；Ghostty 终端 NIF 编译需要固定版本 0.16.0（见 mise.toml）。请先安装 Zig 0.16.0 或设置 GHOSTTY_ZIG_DIR，然后重新运行。" "Zig 0.16.0 not found; Ghostty terminal NIF build requires Zig 0.16.0 (see mise.toml). Install Zig 0.16.0 or set GHOSTTY_ZIG_DIR first, then run again."
}
Write-Host "Zig: $(& zig version 2>$null)"

# 5) MSVC C++ 工具链（NIF 编译需要 cl 和 nmake）
$vcvars = $null
$cl = Get-Command cl -ErrorAction SilentlyContinue
$nmake = Get-Command nmake -ErrorAction SilentlyContinue
if ($cl -and $nmake) {
  Write-Host "MSVC: cl 与 nmake 已在 PATH 中（当前处于开发人员命令提示环境）。"
} else {
  if ($env:HANDBEAN_VCVARS) {
    $vcvars = $env:HANDBEAN_VCVARS
  } else {
    $candidates = @()
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path $vswhere)) { $vswhere = Join-Path $env:ProgramFiles "Microsoft Visual Studio\Installer\vswhere.exe" }
    if (Test-Path $vswhere) {
      $installPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath 2>$null | Select-Object -First 1
      if ($installPath) { $candidates += Join-Path $installPath "VC\Auxiliary\Build\vcvars64.bat" }
    }
    foreach ($pattern in @("C:\Program Files\Microsoft Visual Studio\2022\*\VC\Auxiliary\Build\vcvars64.bat", "C:\Program Files (x86)\Microsoft Visual Studio\2019\*\VC\Auxiliary\Build\vcvars64.bat")) {
      $candidates += @(Get-ChildItem $pattern -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)
    }
    $vcvars = $candidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
  }
  if (-not $vcvars) {
    Stop-Build "未找到 MSVC C++ 工具链（cl/nmake），NIF 编译需要它。请安装 Visual Studio Build Tools（工作负载：使用 C++ 的桌面开发），或设置 HANDBEAN_VCVARS 指向 vcvars64.bat，然后重新运行。" "MSVC C++ toolchain (cl/nmake) not found; the NIF build needs it. Install Visual Studio Build Tools with the 'Desktop development with C++' workload, or set HANDBEAN_VCVARS to vcvars64.bat, then run again."
  }
  cmd /c ('call "{0}" && where cl >NUL && where nmake >NUL' -f $vcvars) | Out-Null
  if ($LASTEXITCODE -ne 0) {
    Stop-Build "加载 vcvars64 后仍找不到 cl 或 nmake: $vcvars。请确认已安装 VC++ 工具集，或用 HANDBEAN_VCVARS 指向可用的 vcvars64.bat。" "cl or nmake still missing after loading vcvars64: $vcvars. Confirm the VC++ toolset is installed, or point HANDBEAN_VCVARS at a working vcvars64.bat."
  }
  Write-Host "MSVC: $vcvars"
}

# 委托同一个 pack_webui.ps1 编译（CI 的 pack.yml 也是调用它）。本地 release
# 使用唯一目录，避免 mix release 覆盖当前 Windows 进程仍在使用的 ERTS/DLL。
$pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
if ($pwsh) { $shell = $pwsh.Source } else { $shell = "powershell" }
$packArgs = '"{0}" -Target "{1}" -ReleasePath "{2}"' -f $packScript, $Target, $localRelease
if ($vcvars) {
  $prefix = 'call "{0}"' -f $vcvars
  if (-not $pwsh) {
    # vcvars 会把 PowerShell 7 的模块目录插进 PSModulePath，害得 Windows
    # PowerShell 5.1 找不到自带 cmdlet（如 Get-FileHash）。加载 vcvars 后
    # 重置为 5.1 的模块路径（CI 用 pwsh 跑，不受影响）。
    $prefix += ' && set "PSModulePath=C:\Program Files\WindowsPowerShell\Modules;C:\Windows\system32\WindowsPowerShell\v1.0\Modules"'
  }
  $commandLine = '{0} && "{1}" -NoProfile -File {2}' -f $prefix, $shell, $packArgs
} else {
  $commandLine = '"{0}" -NoProfile -File {1}' -f $shell, $packArgs
}
Write-Host "开始编译：在独立目录生成新的本地 Web UI 版本..."
cmd /c $commandLine
$packStatus = $LASTEXITCODE
if ($packStatus -ne 0) { exit $packStatus }

$current = Join-Path $localRoot "current.txt"
$pending = Join-Path $localRoot ("current." + [guid]::NewGuid().ToString("N") + ".tmp")
$backup = Join-Path $localRoot ("current." + [guid]::NewGuid().ToString("N") + ".bak")
New-Item -ItemType Directory -Force -Path $localRoot | Out-Null
[IO.File]::WriteAllText($pending, $releaseID, (New-Object Text.UTF8Encoding($false)))
try {
  if (Test-Path $current) {
    [IO.File]::Replace($pending, $current, $backup)
  } else {
    [IO.File]::Move($pending, $current)
  }
} finally {
  if (Test-Path $pending) { Remove-Item $pending -Force -ErrorAction SilentlyContinue }
  if (Test-Path $backup) { Remove-Item $backup -Force -ErrorAction SilentlyContinue }
}

Write-Host "本地 Web UI $version 已准备好：$localRelease"
Write-Host "当前运行实例未被修改；退出后重新运行仓库根目录 start.bat 即可切换。"
Write-Host "Local Web UI $version is ready. Restart the root start.bat to use it."
} finally {
  $localBuildLock.Dispose()
}
exit 0
