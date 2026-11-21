param(
    [string]$Flutter = "",
    [string]$OutputDir = ""
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'version.ps1')
. (Join-Path $PSScriptRoot 'upstream.ps1')
if (-not $IsLinux -or [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne 'X64') {
    throw 'Build the Linux package on x86_64 Linux.'
}
if (-not $Flutter) { $Flutter = (Get-Command flutter -ErrorAction Stop).Source }
$go = (Get-Command go -ErrorAction Stop).Source
$version = Get-NekoVersionInfo -Root $root
if (-not $OutputDir) { $OutputDir = Join-Path $root 'dist' }
$OutputDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDir)

$tempRoot = (Get-Item -LiteralPath ([IO.Path]::GetTempPath())).FullName
$stage = New-Item -ItemType Directory -Path (Join-Path $tempRoot "nekoproxy-linux-$([guid]::NewGuid().ToString('N'))")
try {
    $worker = Join-Path $stage.FullName 'nekoproxy-worker'
    $tags = 'with_gvisor,with_quic,with_wireguard,with_utls'
    Invoke-WithLatestNekoRuntime -Root $root -Build {
        param($SourceDir, $CoreVersion)
        & (Join-Path $PSScriptRoot 'sync-rules.ps1') -RuntimeDir $SourceDir -CoreVersion $CoreVersion -RequireLatest

        Push-Location $SourceDir
        try {
            & $go test -mod=readonly -tags $tags ./...
            if ($LASTEXITCODE -ne 0) { throw 'Linux runtime tests failed.' }
            & $go build -tags $tags -trimpath -buildvcs=false -ldflags "-s -w -X main.version=$($version.Version)" -o $worker ./cmd/worker
            if ($LASTEXITCODE -ne 0) { throw 'Linux worker build failed.' }
        } finally {
            Pop-Location
        }
    }

    Push-Location $root
    try {
        & $Flutter build linux --release --target-platform=linux-x64 "--build-number=$($version.BuildNumber)" "--dart-define=NEKO_VERSION=$($version.Version)" "--dart-define=NEKO_CORE_VERSION=$NekoCoreVersion"
        if ($LASTEXITCODE -ne 0) { throw 'Flutter Linux build failed.' }
    } finally {
        Pop-Location
    }

    $package = Join-Path $stage.FullName 'package'
    $library = Join-Path $package 'usr/lib/nekoproxy'
    $control = Join-Path $package 'DEBIAN'
    foreach ($directory in @('DEBIAN', 'usr/lib/nekoproxy', 'usr/bin', 'usr/share/applications',
        'usr/share/icons/hicolor/256x256/apps', 'usr/share/doc/nekoproxy', 'usr/lib/tmpfiles.d',
        'usr/share/polkit-1/rules.d')) {
        New-Item -ItemType Directory -Path (Join-Path $package $directory) -Force | Out-Null
    }

    $bundle = Join-Path $root 'build/linux/x64/release/bundle'
    & cp -a -- "$bundle/." "$library/"
    if ($LASTEXITCODE -ne 0) { throw 'Cannot copy Flutter bundle.' }
    & install -m 0755 -- $worker (Join-Path $library 'nekoproxy-worker')
    if ($LASTEXITCODE -ne 0) { throw 'Cannot stage the normal worker.' }
    & install -m 0750 -- $worker (Join-Path $library 'nekoproxy-tun-worker')
    if ($LASTEXITCODE -ne 0) { throw 'Cannot stage the TUN component.' }
    & ln -s ../lib/nekoproxy/nekoproxy (Join-Path $package 'usr/bin/nekoproxy')
    if ($LASTEXITCODE -ne 0) { throw 'Cannot stage the launcher.' }

    $appId = 'io.github.sh1rokodev.NekoProxy'
    Copy-Item -LiteralPath (Join-Path $root 'assets/icons/app_icon.png') -Destination (Join-Path $package "usr/share/icons/hicolor/256x256/apps/$appId.png")
    Copy-Item -LiteralPath (Join-Path $root 'LICENSE') -Destination (Join-Path $package 'usr/share/doc/nekoproxy/copyright')
    Copy-Item -LiteralPath (Join-Path $root 'third_party/THIRD_PARTY_NOTICES.md') -Destination (Join-Path $package 'usr/share/doc/nekoproxy/')
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'linux/nekoproxy.conf') -Destination (Join-Path $package 'usr/lib/tmpfiles.d/')
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'linux/49-nekoproxy-resolved.rules') -Destination (Join-Path $package 'usr/share/polkit-1/rules.d/')
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot "linux/$appId.desktop") -Destination (Join-Path $package 'usr/share/applications/')
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'linux/postinst') -Destination $control
    & chmod 0755 (Join-Path $control 'postinst')
    if ($LASTEXITCODE -ne 0) { throw 'Cannot make the installer hook executable.' }

    $metadata = @"
Package: nekoproxy
Version: $($version.BaseVersion)-$($version.BuildNumber)
Architecture: amd64
Section: net
Priority: optional
Maintainer: NekoProxy maintainers <nekoproxy@users.noreply.github.com>
Depends: libgtk-3-0t64 | libgtk-3-0, libsecret-1-0, libstdc++6, ca-certificates, adduser, libcap2-bin, systemd | systemd-standalone-tmpfiles
Recommends: gnome-keyring | kwalletmanager, gsettings-desktop-schemas, dbus-bin, polkitd
Description: NekoProxy sing-box desktop client
 Local HTTP and SOCKS5 proxy, desktop proxy integration and optional TUN.
"@
    [IO.File]::WriteAllText((Join-Path $control 'control'), $metadata + [Environment]::NewLine)

    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
    $name = "NekoProxy-$($version.Version)-linux-x64.deb"
    $artifact = Join-Path $OutputDir $name
    & dpkg-deb --root-owner-group --build $package $artifact
    if ($LASTEXITCODE -ne 0) { throw 'Linux package build failed.' }
    $sha = (Get-FileHash -LiteralPath $artifact -Algorithm SHA256).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText("$artifact.sha256", "$sha  $name`n")
    Copy-Item -LiteralPath (Join-Path $root 'assets/rules/manifest.json') -Destination (Join-Path $OutputDir 'rules-manifest.json')
    Write-Host "Linux package written to $artifact"
} finally {
    if ((Split-Path -Parent $stage.FullName) -ceq $tempRoot.TrimEnd('/')) {
        Remove-Item -LiteralPath $stage.FullName -Recurse -Force
    }
}
