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
$packageName = "NekoProxy-$($version.Version)-windows-x64"

& (Join-Path $PSScriptRoot "build-windows.ps1")
if ($LASTEXITCODE -ne 0) { throw "Windows build failed" }

$release = Join-Path $root "build\windows\x64\runner\Release"
if (-not (Test-Path $release)) { throw "Windows release directory not found: $release" }

# Older incremental builds may still contain the retired elevation helper.
$legacyHelper = Join-Path $release "nekoproxy-helper.exe"
if (Test-Path $legacyHelper) { Remove-Item $legacyHelper -Force }

$target = Join-Path $DistDir "NekoProxy-windows-x64"
if (Test-Path $target) { Remove-Item $target -Recurse -Force }
New-Item -ItemType Directory -Force -Path $target | Out-Null
Copy-Item (Join-Path $release "*") $target -Recurse
Copy-Item (Join-Path $root "LICENSE") $target
Copy-Item (Join-Path $root "README.md") $target
New-Item -ItemType Directory -Force -Path (Join-Path $target "third_party") | Out-Null
Copy-Item (Join-Path $root "third_party\THIRD_PARTY_NOTICES.md") (Join-Path $target "third_party")
Copy-Item (Join-Path $root "third_party\wintun-LICENSE.txt") (Join-Path $target "third_party")
Copy-Item (Join-Path $root "third_party\wfp-LICENSE.txt") (Join-Path $target "third_party")

$zipName = "$packageName.zip"
$zip = Join-Path $DistDir $zipName
if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path $target -DestinationPath $zip
$hash = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant()
[IO.File]::WriteAllText("$zip.sha256", "$hash *$zipName`n", (New-Object Text.UTF8Encoding($false)))
Write-Host "Portable package: $zip"

$makensis = (Get-Command makensis -ErrorAction SilentlyContinue).Source
if (-not $makensis) {
    $candidates = @(
        (Join-Path $env:ProgramFiles "NSIS\makensis.exe"),
        (Join-Path $env:LOCALAPPDATA "Programs\NSIS\makensis.exe")
    )
    if (${env:ProgramFiles(x86)}) {
        $candidates += Join-Path ${env:ProgramFiles(x86)} "NSIS\makensis.exe"
    }
    foreach ($candidate in $candidates) {
        if (Test-Path $candidate) {
            $makensis = $candidate
            break
        }
    }
}
if (-not $makensis) {
    throw "NSIS not found. Install NSIS 3.x or add makensis.exe to PATH; the portable ZIP was written to $zip."
}

$fileVersion = "$($version.BaseVersion).$($version.BuildNumber)"
& $makensis "/V2" "/INPUTCHARSET" "UTF8" `
    "/DFILE_VERSION=$fileVersion" `
    "/DDISPLAY_VERSION=$($version.Version)" `
    "/DOUTPUT_DIR=$DistDir" `
    (Join-Path $PSScriptRoot "installer-windows.nsi")
if ($LASTEXITCODE -ne 0) { throw "NSIS build failed" }
$setupName = "$packageName-setup.exe"
$setup = Join-Path $DistDir $setupName
if (-not (Test-Path $setup)) { throw "Installer was not created: $setup" }
$setupHash = (Get-FileHash $setup -Algorithm SHA256).Hash.ToLowerInvariant()
[IO.File]::WriteAllText("$setup.sha256", "$setupHash *$setupName`n", (New-Object Text.UTF8Encoding($false)))
Write-Host "Installer: $setup"
