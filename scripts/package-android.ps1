param(
    [string]$DistDir = ""
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot "version.ps1")
$version = Get-NekoVersionInfo -Root $root
if ([string]::IsNullOrWhiteSpace($DistDir)) {
    $DistDir = Join-Path $root "dist"
}
$DistDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($DistDir)
New-Item -ItemType Directory -Force -Path $DistDir | Out-Null

& (Join-Path $PSScriptRoot "build-android.ps1")
if ($LASTEXITCODE -ne 0) { throw "Android build failed" }

$apk = Join-Path $root "build\app\outputs\flutter-apk\app-release.apk"
if (-not (Test-Path $apk)) { throw "APK not found: $apk" }
$apkName = "NekoProxy-$($version.Version)-android-arm64.apk"
$target = Join-Path $DistDir $apkName
Copy-Item $apk $target -Force
$checksum = Get-FileHash -LiteralPath $target -Algorithm SHA256
$hash = $checksum.Hash.ToLowerInvariant()
[IO.File]::WriteAllText("$target.sha256", "$hash *$apkName`n", (New-Object Text.UTF8Encoding($false)))
$checksum | Format-List | Out-String | Write-Host
Write-Host "APK: $target"
Write-Host "SHA-256: $target.sha256"
