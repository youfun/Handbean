# Download handbean-web-windows-amd64.zip and unpack it into resources/handbean-web.
# Usage: scripts/fetch_web_release.ps1 [tag]
#   tag defaults to web-latest.
#   HANDBEAN_WEB_ZIP=/path/to.zip skips the download.
#   HANDBEAN_WEB_DEST overrides the unpack directory.
[CmdletBinding()]
param([string]$Tag = "web-latest")
$ErrorActionPreference = "Stop"

function Invoke-WebRequestRetry([string]$Uri, [string]$OutFile) {
    $last = $null
    for ($i = 1; $i -le 3; $i++) {
        try {
            Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing
            return
        } catch {
            $last = $_
            if ($i -lt 3) { Start-Sleep -Seconds (2 * $i) }
        }
    }
    throw $last
}

$ROOT = Split-Path -Parent $PSScriptRoot
$DEST = if ($env:HANDBEAN_WEB_DEST) { $env:HANDBEAN_WEB_DEST } else { Join-Path $ROOT "resources/handbean-web" }
$TMP = Join-Path ([IO.Path]::GetTempPath()) ("handbean-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $TMP | Out-Null

try {
    $archive = Join-Path $TMP "archive.zip"
    if ($env:HANDBEAN_WEB_ZIP) {
        Copy-Item $env:HANDBEAN_WEB_ZIP $archive
    } else {
        $URL = "https://github.com/youfun/Handbean/releases/download/$Tag/handbean-web-windows-amd64.zip"
        Write-Host "Downloading $URL"
        Invoke-WebRequestRetry $URL $archive
        $sidecar = "$archive.sha256"
        $haveSidecar = $true
        try {
            Invoke-WebRequestRetry "$URL.sha256" $sidecar
        } catch {
            $haveSidecar = $false
        }
        if ($haveSidecar) {
            $expected = (Get-Content $sidecar -Raw).Split()[0].Trim()
            $actual = (Get-FileHash $archive -Algorithm SHA256).Hash.ToLower()
            if ($expected -ne $actual) { throw "sha256 mismatch: $actual != $expected" }
            Write-Host "sha256 ok"
        } else {
            Write-Warning "No .sha256 sidecar; continuing without checksum"
        }
    }
    if (Test-Path $DEST) { Remove-Item $DEST -Recurse -Force }
    New-Item -ItemType Directory -Path $DEST | Out-Null
    Expand-Archive -Path $archive -DestinationPath $DEST -Force
    if (-not (Test-Path (Join-Path $DEST "bin/handbean.bat"))) {
        throw "archive does not contain bin/handbean.bat"
    }
    Write-Host "Unpacked to $DEST"
} finally {
    Remove-Item $TMP -Recurse -Force -ErrorAction SilentlyContinue
}
