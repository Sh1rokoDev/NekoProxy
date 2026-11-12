function Get-NekoVersionInfo {
    param(
        [Parameter(Mandatory)][string]$Root
    )

    $pubspec = Join-Path $Root "pubspec.yaml"
    $content = Get-Content -LiteralPath $pubspec -Raw -ErrorAction Stop
    $match = [regex]::Match($content, '(?m)^version:[ \t]*([0-9]+\.[0-9]+\.[0-9]+)\+([0-9]+)[ \t]*(?:#[^\r\n]*)?\r?$')
    if (-not $match.Success) {
        throw "Expected version: <major>.<minor>.<patch>+<numeric build> in $pubspec"
    }
    $baseVersion = $match.Groups[1].Value
    $initialBuild = $match.Groups[2].Value

    $git = Get-Command git -ErrorAction SilentlyContinue
    $commit = $null
    $commitCount = $null
    if ($git) {
        $previous = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            $commit = "$(& $git.Source -C $Root rev-parse --short HEAD 2>$null)".Trim()
            if ($LASTEXITCODE -ne 0) { $commit = $null }
            $commitCount = "$(& $git.Source -C $Root rev-list --count HEAD 2>$null)".Trim()
            if ($LASTEXITCODE -ne 0) { $commitCount = $null }
        } finally {
            $ErrorActionPreference = $previous
        }
    }

    if ([string]::IsNullOrWhiteSpace($commit)) { $commit = $null }
    $buildNumber = $initialBuild
    if ($commitCount -match '^[1-9][0-9]*$') {
        $buildNumber = [string]([long]$initialBuild + [long]$commitCount - 1)
    }

    $version = if ($commit) { "$baseVersion+$commit" } else { $baseVersion }
    return [pscustomobject]@{
        Version     = $version
        BaseVersion = $baseVersion
        BuildNumber = $buildNumber
        Commit      = $commit
    }
}
