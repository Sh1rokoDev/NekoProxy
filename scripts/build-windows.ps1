param(
    [string]$Flutter = ""
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot "version.ps1")
. (Join-Path $PSScriptRoot "upstream.ps1")
$version = Get-NekoVersionInfo -Root $root
if ([string]::IsNullOrWhiteSpace($Flutter)) {
    $Flutter = (Get-Command flutter -ErrorAction SilentlyContinue).Source
}
if (-not $Flutter) {
    throw "Flutter not found on PATH. Install Flutter or pass -Flutter <flutter.bat>."
}

Invoke-WithLatestNekoRuntime -Root $root -Build {
    param($SourceDir, $CoreVersion)
    & (Join-Path $PSScriptRoot "sync-rules.ps1") -RuntimeDir $SourceDir -CoreVersion $CoreVersion -RequireLatest
    & (Join-Path $PSScriptRoot "build-runtime.ps1") -RuntimeDir $SourceDir
}

Push-Location $root
try {
    & $Flutter build windows --release "--build-number=$($version.BuildNumber)" "--dart-define=NEKO_VERSION=$($version.Version)" "--dart-define=NEKO_CORE_VERSION=$($NekoCoreVersion)"
    if ($LASTEXITCODE -ne 0) { throw "flutter build windows failed" }
} finally {
    Pop-Location
}
