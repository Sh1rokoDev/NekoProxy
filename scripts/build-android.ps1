param(
    [string]$Flutter = ""
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot "version.ps1")
. (Join-Path $PSScriptRoot "upstream.ps1")
$version = Get-NekoVersionInfo -Root $root

function Resolve-Tool([string]$Name) {
    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    return $null
}

function Resolve-Jdk {
    if ($env:JAVA_HOME -and (Test-Path (Join-Path $env:JAVA_HOME "bin\javac.exe"))) {
        return $env:JAVA_HOME
    }
    $javac = Resolve-Tool "javac"
    if ($javac) {
        $jdkHome = Split-Path (Split-Path $javac -Parent) -Parent
        if (Test-Path (Join-Path $jdkHome "bin\javac.exe")) { return $jdkHome }
    }
    foreach ($base in @(
        (Join-Path $env:ProgramFiles "Java"),
        (Join-Path $env:ProgramFiles "Eclipse Adoptium"),
        (Join-Path $env:LOCALAPPDATA "Programs\Eclipse Adoptium")
    )) {
        if (-not (Test-Path $base)) { continue }
        $candidate = Get-ChildItem $base -Directory |
            Where-Object { Test-Path (Join-Path $_.FullName "bin\javac.exe") } |
            Sort-Object Name -Descending |
            Select-Object -First 1
        if ($candidate) { return $candidate.FullName }
    }
    return $null
}

if ([string]::IsNullOrWhiteSpace($Flutter)) {
    $Flutter = Resolve-Tool "flutter"
}
if (-not $Flutter) {
    throw "Flutter not found on PATH. Install Flutter or pass -Flutter <flutter.bat>."
}

$sdk = $env:ANDROID_HOME
if ([string]::IsNullOrWhiteSpace($sdk)) { $sdk = $env:ANDROID_SDK_ROOT }
if ([string]::IsNullOrWhiteSpace($sdk)) {
    $fallback = Join-Path $env:LOCALAPPDATA "Programs\AndroidSDK"
    if (Test-Path $fallback) { $sdk = $fallback }
}
if ([string]::IsNullOrWhiteSpace($sdk) -or -not (Test-Path $sdk)) {
    throw "Android SDK not found. Set ANDROID_HOME or ANDROID_SDK_ROOT."
}

$ndkRoot = Join-Path $sdk "ndk"
$ndk = Join-Path $ndkRoot "28.2.13676358"
if (-not (Test-Path $ndk)) {
    $candidate = Get-ChildItem $ndkRoot -Directory -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending |
        Select-Object -First 1
    if ($candidate) { $ndk = $candidate.FullName }
}
if (-not (Test-Path $ndk)) {
    throw "Android NDK not found under $ndkRoot. Install NDK 28.2.13676358."
}

$jdk = Resolve-Jdk
if (-not $jdk) {
    throw "JDK not found. Set JAVA_HOME to a JDK 17+ installation."
}

$go = Resolve-Tool "go"
if (-not $go) { throw "Go not found on PATH. Install Go 1.26+ and add it to PATH." }
$goBin = Join-Path (& $go env GOPATH) "bin"
$gomobile = Resolve-Tool "gomobile"
if (-not $gomobile) {
    $candidate = Join-Path $goBin "gomobile.exe"
    if (Test-Path $candidate) { $gomobile = $candidate }
}
if (-not $gomobile) {
    throw "gomobile not found. Install it with: go install golang.org/x/mobile/cmd/gomobile@latest"
}

$env:JAVA_HOME = $jdk
$env:ANDROID_HOME = $sdk
$env:ANDROID_SDK_ROOT = $sdk
$env:ANDROID_NDK_HOME = $ndk
if (-not $env:GOPROXY) { $env:GOPROXY = "https://goproxy.cn,direct" }
$env:PATH = "$jdk\bin;$goBin;$env:PATH"

$libs = Join-Path $root "android\app\libs"
New-Item -ItemType Directory -Force -Path $libs | Out-Null

Invoke-WithLatestNekoRuntime -Root $root -Build {
    param($SourceDir, $CoreVersion)
    & (Join-Path $PSScriptRoot "sync-rules.ps1") -RuntimeDir $SourceDir -CoreVersion $CoreVersion -RequireLatest
    Push-Location $SourceDir
    try {
        $bindArgs = @(
            "bind",
            "-target=android/arm64",
            "-androidapi", "24",
            "-trimpath",
            "-ldflags", "-s -w",
            "-javapkg=com.nekoproxy",
            "-tags", "with_gvisor,with_quic,with_wireguard,with_utls",
            "-o", (Join-Path $libs "nekoproxy.aar"),
            "./mobile"
        )
        & $gomobile @bindArgs
        if ($LASTEXITCODE -ne 0) { throw "gomobile bind failed" }
    } finally {
        Pop-Location
    }
}

Push-Location $root
try {
    & $Flutter build apk --release --target-platform android-arm64 "--build-number=$($version.BuildNumber)" "--dart-define=NEKO_VERSION=$($version.Version)"
    if ($LASTEXITCODE -ne 0) { throw "flutter build apk failed" }
} finally {
    Pop-Location
}
