function Get-LatestGitHubReleaseTag {
    param([Parameter(Mandatory)][string]$Repository)

    $releasePath = "/$Repository/releases"
    $latest = [uri]"https://github.com$releasePath/latest"
    $response = Invoke-WebRequest $latest -Headers @{ 'User-Agent' = 'NekoProxy-build' } `
        -TimeoutSec 30 -MaximumRedirection 0 -SkipHttpErrorCheck -ErrorAction SilentlyContinue
    $location = [string[]]$response.Headers['Location']
    if ($response.StatusCode -notin @(301, 302, 303, 307, 308) -or $location.Count -ne 1) {
        throw "Cannot find the latest GitHub release for $Repository."
    }
    $tagged = [uri]::new($latest, $location[0])
    $tag = $tagged.Segments[-1]
    if ($tagged.Scheme -ne 'https' -or $tagged.Host -ne 'github.com' -or
        $tagged.Port -ne 443 -or $tagged.UserInfo -or
        $tagged.AbsolutePath -cne "$releasePath/tag/$tag" -or
        $tag -notmatch '^[A-Za-z0-9._-]+$' -or $tag -in @('.', '..')) {
        throw "Invalid release tag for $Repository."
    }
    return $tag
}

function Invoke-WithLatestNekoRuntime {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][scriptblock]$Build
    )

    $go = (Get-Command go -ErrorAction SilentlyContinue).Source
    if (-not $go) { throw 'Go not found on PATH. Install Go 1.26.9+ and add it to PATH.' }
    $tag = Get-LatestGitHubReleaseTag 'SagerNet/sing-box'
    if ($tag -cnotmatch '^v[0-9]+\.[0-9]+\.[0-9]+$') {
        throw "Unexpected stable sing-box release tag: $tag."
    }
    # Expose the resolved tag so build entry points can report it to Flutter.
    $script:NekoCoreVersion = $tag

    # Resolve the published Go module in a private copy, leaving the development
    # submodule and the tracked dependency files unchanged.
    $tempRoot = (Get-Item -LiteralPath ([IO.Path]::GetTempPath())).FullName
    $stage = New-Item -ItemType Directory -Path (Join-Path $tempRoot "nekoproxy-runtime-$([guid]::NewGuid().ToString('N'))")
    $previousWorkspace = $env:GOWORK
    $previousToolchain = $env:GOTOOLCHAIN
    try {
        $env:GOWORK = 'off'
        $env:GOTOOLCHAIN = 'local'
        Copy-Item -LiteralPath (Join-Path $Root 'runtime') -Destination $stage.FullName -Recurse
        $runtime = Join-Path $stage.FullName 'runtime'
        Push-Location $runtime
        try {
            & $go mod edit '-dropreplace=github.com/sagernet/sing-box' "-require=github.com/sagernet/sing-box@$tag"
            if ($LASTEXITCODE -ne 0) { throw "Cannot configure the sing-box $tag build." }
            & $go mod tidy
            if ($LASTEXITCODE -ne 0) { throw "Cannot resolve dependencies for sing-box $tag." }
            $resolved = & $go list -m -f '{{.Version}}{{if .Replace}} (replaced){{end}}' github.com/sagernet/sing-box
            if ($LASTEXITCODE -ne 0 -or $resolved -cne $tag) {
                throw "The build did not resolve the latest sing-box release $tag."
            }
        } finally {
            Pop-Location
        }
        Write-Host "Building with sing-box $tag."
        & $Build $runtime $tag
    } finally {
        $env:GOWORK = $previousWorkspace
        $env:GOTOOLCHAIN = $previousToolchain
        $resolvedStage = (Resolve-Path -LiteralPath $stage.FullName).Path
        if ((Split-Path -Parent $resolvedStage) -ieq $tempRoot.TrimEnd([IO.Path]::DirectorySeparatorChar)) {
            Remove-Item -LiteralPath $resolvedStage -Recurse -Force
        }
    }
}
