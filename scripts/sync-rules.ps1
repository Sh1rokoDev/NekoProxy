param(
    [string]$OutputDir = "",
    [switch]$Force
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = Join-Path $root "assets\rules"
}
$OutputDir = [IO.Path]::GetFullPath($OutputDir)
$manifestPath = Join-Path $OutputDir "manifest.json"
$sources = @{
    geosite = @{ Repo = "domain-list-community"; Asset = "dlc.dat" }
    geoip = @{ Repo = "geoip"; Asset = "geoip.dat" }
}
$headers = @{ "User-Agent" = "NekoProxy-build"; Accept = "application/vnd.github+json" }

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
        $release = Invoke-RestMethod "https://api.github.com/repos/v2fly/$($source.Repo)/releases/latest" `
            -Headers $headers -TimeoutSec 30
        $asset = @($release.assets | Where-Object { $_.name -eq $source.Asset })
        if ($release.tag_name -notmatch '^[A-Za-z0-9._-]+$' -or $release.tag_name -in @('.', '..') -or
            $asset.Count -ne 1 -or
            $asset[0].digest -notmatch '^sha256:[0-9a-f]{64}$' -or
            $asset[0].size -lt 1 -or $asset[0].size -gt 64MB) {
            throw "Invalid release metadata for $($source.Repo)."
        }
        $releases[$kind] = [ordered]@{
            tag = $release.tag_name
            sha256 = $asset[0].digest.Substring(7)
            size = $asset[0].size
        }
    }
} catch {
    if ($null -eq $previous -or $Force) { throw }
    Write-Warning "Cannot check v2fly releases. Using the verified bundled rules. $($_.Exception.Message)"
    return
}

if (-not $Force -and $null -ne $previous -and
    $previous.releases.geosite.sha256 -eq $releases.geosite.sha256 -and
    $previous.releases.geoip.sha256 -eq $releases.geoip.sha256) {
    Write-Host "Bundled GeoSite and GeoIP rules are up to date."
    return
}

$stage = Join-Path ([IO.Path]::GetTempPath()) ("nekoproxy-rules-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $stage | Out-Null
try {
    Push-Location (Join-Path $root "runtime")
    try {
        foreach ($kind in @("geosite", "geoip")) {
            $source = $sources[$kind]
            $release = $releases[$kind]
            $input = Join-Path $stage $source.Asset
            $url = "https://github.com/v2fly/$($source.Repo)/releases/download/$($release.tag)/$($source.Asset)"
            try {
                Invoke-WebRequest -Uri $url -OutFile $input -TimeoutSec 120
            } catch {
                if ($null -eq $previous -or $Force) { throw }
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
