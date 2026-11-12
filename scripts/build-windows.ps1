param(
    [string]$Flutter = ""
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot "version.ps1")
$version = Get-NekoVersionInfo -Root $root
if ([string]::IsNullOrWhiteSpace($Flutter)) {
    $Flutter = (Get-Command flutter -ErrorAction SilentlyContinue).Source
}
if (-not $Flutter) {
    throw "Flutter not found on PATH. Install Flutter or pass -Flutter <flutter.bat>."
}

& (Join-Path $PSScriptRoot "sync-rules.ps1")

& (Join-Path $PSScriptRoot "build-runtime.ps1")
if ($LASTEXITCODE -ne 0) { throw "runtime build failed" }

Push-Location $root
try {
    & $Flutter build windows --release "--build-number=$($version.BuildNumber)" "--dart-define=NEKO_VERSION=$($version.Version)"
    if ($LASTEXITCODE -ne 0) { throw "flutter build windows failed" }
} finally {
    Pop-Location
}
