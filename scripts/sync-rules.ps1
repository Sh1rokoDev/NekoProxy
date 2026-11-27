param(
    [string]$OutputDir = "",
    [string]$RuntimeDir = "",
    [string]$CoreVersion = "",
    [switch]$RequireLatest,
    [switch]$Force
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'upstream.ps1')
if ([string]::IsNullOrWhiteSpace($RuntimeDir)) {
    $RuntimeDir = Join-Path $root 'runtime'
}
if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = Join-Path $root "assets/rules"
}
$OutputDir = [IO.Path]::GetFullPath($OutputDir)
$manifestPath = Join-Path $OutputDir "manifest.json"
$sources = @{
    geosite = @{ Repo = "domain-list-community"; Asset = "dlc.dat" }
    geoip = @{ Repo = "geoip"; Asset = "geoip.dat" }
}
$headers = @{ "User-Agent" = "NekoProxy-build" }

function Get-PublicReleaseMetadata($source) {
    $releasePath = "/v2fly/$($source.Repo)/releases"
    $tag = Get-LatestGitHubReleaseTag "v2fly/$($source.Repo)"

    $page = Invoke-WebRequest "https://github.com$releasePath/expanded_assets/$tag" `
        -Headers $headers -TimeoutSec 30 -MaximumRedirection 0
    if ($page.RawContentLength -gt 1MB) {
        throw "Release metadata is too large for $($source.Repo)."
    }
    $assetPath = "$releasePath/download/$tag/$($source.Asset)"
    $link = '<a\b[^>]*\shref="' + [regex]::Escape($assetPath) + '"'
    $rows = @([regex]::Matches($page.Content, '<li\b[^>]*>[\s\S]*?</li>') |
        Where-Object { $_.Value -cmatch $link })
    if ($rows.Count -ne 1) {
        throw "Missing or ambiguous release asset for $($source.Repo)."
    }
    $digest = [regex]::Matches($rows[0].Value, '<clipboard-copy\b[^>]*\svalue="sha256:([a-f0-9]{64})"')
    if ($digest.Count -ne 1) {
        throw "Missing or ambiguous release SHA-256 for $($source.Repo)."
    }

    $asset = Invoke-WebRequest "https://github.com$assetPath" `
        -Method Head -Headers $headers -TimeoutSec 30 -MaximumRedirection 5
    $uri = $asset.BaseResponse.RequestMessage.RequestUri
    $length = [string[]]$asset.Headers['Content-Length']
    $size = 0L
    if ($asset.StatusCode -ne 200 -or $uri.Scheme -ne 'https' -or $uri.Port -ne 443 -or
        $uri.UserInfo -or $uri.Host -notin @('github.com', 'release-assets.githubusercontent.com', 'objects.githubusercontent.com') -or
        $length.Count -ne 1 -or -not [long]::TryParse($length[0], [ref]$size) -or
        $size -lt 1 -or $size -gt 64MB) {
        throw "Invalid release asset size for $($source.Repo)."
    }
    return [ordered]@{ tag = $tag; sha256 = $digest[0].Groups[1].Value; size = $size }
}

function Get-ReleaseMetadata($source) {
    if ([string]::IsNullOrWhiteSpace($env:NEKO_RULES_GITHUB_TOKEN)) {
        return Get-PublicReleaseMetadata $source
    }

    $repository = "v2fly/$($source.Repo)"
    $token = ConvertTo-SecureString $env:NEKO_RULES_GITHUB_TOKEN -AsPlainText -Force
    try {
        $release = Invoke-RestMethod "https://api.github.com/repos/$repository/releases/latest" `
            -Authentication Bearer -Token $token -TimeoutSec 30 -MaximumRedirection 0 `
            -Headers @{ Accept = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2026-03-10' }
    } catch {
        Write-Warning "Cannot query the GitHub API for $repository. Using the public release page."
        return Get-PublicReleaseMetadata $source
    }

    $tag = $release.tag_name
    if ($tag -isnot [string] -or $tag -cnotmatch '\A[A-Za-z0-9._-]+\z' -or $tag -in @('.', '..')) {
        throw "Invalid release tag for $repository."
    }
    $assets = @($release.assets | Where-Object { $_.name -ceq $source.Asset -and $_.state -ceq 'uploaded' })
    if ($assets.Count -ne 1) {
        throw "Missing or ambiguous release asset for $repository."
    }
    $asset = $assets[0]
    $digest = [regex]::Match([string]$asset.digest, '\Asha256:([a-f0-9]{64})\z')
    $size = 0L
    if (-not $digest.Success -or -not [long]::TryParse([string]$asset.size, [ref]$size) -or
        $size -lt 1 -or $size -gt 64MB) {
        throw "Invalid release asset size or SHA-256 for $repository."
    }
    return [ordered]@{ tag = $tag; sha256 = $digest.Groups[1].Value; size = $size }
}

$previous = $null
$previousFiles = @()
if (Test-Path -LiteralPath $manifestPath) {
    try {
        $candidate = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        $files = @($candidate.files.PSObject.Properties)
        $previousFiles = @($files.Name | Where-Object { $_ -match '^geo(?:site|ip)-[a-z0-9_!.@-]+\.srs$' })
        $valid = $candidate.schema -eq 2 -and $files.Count -gt 3
        foreach ($file in $files) {
            if (-not $valid) { break }
            if ($file.Name -notmatch '^geo(?:site|ip)-[a-z0-9_!.@-]+\.srs$') {
                $valid = $false
                break
            }
            $path = Join-Path $OutputDir $file.Name
            $valid = (Test-Path -LiteralPath $path -PathType Leaf) -and
                ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -eq $file.Value.sha256)
        }
        if ($valid) { $previous = $candidate }
    } catch {
        Write-Warning "Cannot reuse the bundled rules: $($_.Exception.Message)"
    }
}

$releases = [ordered]@{}
try {
    foreach ($kind in @("geosite", "geoip")) {
        $source = $sources[$kind]
        $releases[$kind] = Get-ReleaseMetadata $source
    }
} catch {
    if ($null -eq $previous -or $Force -or $RequireLatest) { throw }
    Write-Warning "Cannot check v2fly releases. Using the verified bundled rules. $($_.Exception.Message)"
    return
}

if (-not $Force -and $null -ne $previous -and
    (-not $CoreVersion -or $previous.singBox -ceq $CoreVersion) -and
    $previous.releases.geosite.tag -ceq $releases.geosite.tag -and
    $previous.releases.geosite.sha256 -ceq $releases.geosite.sha256 -and
    $previous.releases.geosite.size -eq $releases.geosite.size -and
    $previous.releases.geoip.tag -ceq $releases.geoip.tag -and
    $previous.releases.geoip.sha256 -ceq $releases.geoip.sha256 -and
    $previous.releases.geoip.size -eq $releases.geoip.size) {
    Write-Host "Bundled rules are up to date (GeoSite $($releases.geosite.tag) / GeoIP $($releases.geoip.tag))."
    return
}

$stage = Join-Path ([IO.Path]::GetTempPath()) ("nekoproxy-rules-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $stage | Out-Null
try {
    Push-Location $RuntimeDir
    try {
        foreach ($kind in @("geosite", "geoip")) {
            $source = $sources[$kind]
            $release = $releases[$kind]
            $input = Join-Path $stage $source.Asset
            $url = "https://github.com/v2fly/$($source.Repo)/releases/download/$($release.tag)/$($source.Asset)"
            try {
                Invoke-WebRequest -Uri $url -OutFile $input -TimeoutSec 120
            } catch {
                if ($null -eq $previous -or $Force -or $RequireLatest) { throw }
                Write-Warning "Cannot download $($source.Asset). Using the verified bundled rules. $($_.Exception.Message)"
                return
            }
            if ((Get-Item -LiteralPath $input).Length -ne $release.size -or
                (Get-FileHash -LiteralPath $input -Algorithm SHA256).Hash -ne $release.sha256) {
                throw "Checksum mismatch for $($source.Asset)."
            }
            & go run ./cmd/rulesets $kind $input $stage
            if ($LASTEXITCODE -ne 0) { throw "Conversion failed for $($source.Asset)." }
        }
    } finally {
        Pop-Location
    }

    $files = [ordered]@{}
    $compiled = @(Get-ChildItem -LiteralPath $stage -Filter '*.srs' -File | Sort-Object Name)
    foreach ($file in $compiled) {
        $files[$file.Name] = [ordered]@{
            size = $file.Length
            sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    }
    $manifest = [ordered]@{
        schema = 2
        generatedAt = [DateTime]::UtcNow.ToString("o")
        releases = $releases
        files = $files
    }
    if ($CoreVersion) { $manifest['singBox'] = $CoreVersion }
    $json = $manifest | ConvertTo-Json -Depth 6

    New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
    foreach ($file in $compiled) {
        Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $OutputDir $file.Name) -Force
    }
    foreach ($old in $previousFiles) {
        $oldPath = Join-Path $OutputDir $old
        if (-not $files.Contains($old) -and (Test-Path -LiteralPath $oldPath -PathType Leaf)) {
            Remove-Item -LiteralPath $oldPath
        }
    }
    [IO.File]::WriteAllText($manifestPath, "$json`n", [Text.UTF8Encoding]::new($false))
    Write-Host "Bundled $($files.Count) rule sets (GeoSite $($releases.geosite.tag) / GeoIP $($releases.geoip.tag))."
} finally {
    $resolvedStage = (Resolve-Path -LiteralPath $stage).ProviderPath
    $tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if ($resolvedStage.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase) -and
        [IO.Path]::GetFileName($resolvedStage) -match '^nekoproxy-rules-[0-9a-f]{32}$') {
        Remove-Item -LiteralPath $resolvedStage -Recurse -Force
    }
}
