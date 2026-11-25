param(
    [string]$OutputDir = "",
    [string]$RuntimeDir = ""
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot "version.ps1")
. (Join-Path $PSScriptRoot "upstream.ps1")
$version = Get-NekoVersionInfo -Root $root
if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = Join-Path $root "build"
}
$OutputDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDir)
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

$go = (Get-Command go -ErrorAction SilentlyContinue).Source
if (-not $go) { throw "Go not found on PATH. Install Go 1.26.9+ and add it to PATH." }
if (-not $env:GOPROXY) { $env:GOPROXY = "https://goproxy.cn,direct" }

$tags = "with_gvisor,with_quic,with_wireguard,with_utls"

$buildWorker = {
    param($SourceDir)
    Push-Location $SourceDir
    try {
        & $go build -tags $tags -trimpath -buildvcs=false -ldflags "-s -w -X main.version=$($version.Version)" -o (Join-Path $OutputDir "nekoproxy-worker.exe") ./cmd/worker
        if ($LASTEXITCODE -ne 0) { throw "worker build failed" }
    } finally {
        Pop-Location
    }
}
if ($RuntimeDir) {
    & $buildWorker $RuntimeDir
} else {
    Invoke-WithLatestNekoRuntime -Root $root -Build $buildWorker
}

$wintunDll = Join-Path $OutputDir "wintun.dll"
if (-not (Test-Path $wintunDll)) {
    $wintunVersion = "0.14.1"
    $wintunSha256 = "07c256185d6ee3652e09fa55c0b673e2624b565e02c4b9091c79ca7d2f24ef51"
    $cache = Join-Path $env:LOCALAPPDATA "NekoProxy\cache"
    $zip = Join-Path $cache "wintun-$wintunVersion.zip"
    $extract = Join-Path $cache "wintun-$wintunVersion"
    New-Item -ItemType Directory -Force -Path $cache | Out-Null
    if (-not (Test-Path $zip)) {
        Invoke-WebRequest -Uri "https://www.wintun.net/builds/wintun-$wintunVersion.zip" -OutFile $zip -UseBasicParsing
    }
    $actual = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $wintunSha256) { throw "wintun archive checksum mismatch: $actual" }
    if (-not (Test-Path (Join-Path $extract "wintun\bin\amd64\wintun.dll"))) {
        Expand-Archive -Path $zip -DestinationPath $extract -Force
    }
    Copy-Item (Join-Path $extract "wintun\bin\amd64\wintun.dll") $wintunDll -Force
}

Write-Host "Runtime binaries written to $OutputDir"
