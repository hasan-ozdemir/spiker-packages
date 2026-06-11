Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$Latest = $false
$CommitNumber = 0
$ReleaseTag = ''
$Repository = 'prodyum/spiker-setup'
$NoPush = $false
$Arguments = @($args)
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$pinFile = Join-Path $scriptRoot 'release-pins.json'

function Apply-Arguments {
    for ($i = 0; $i -lt $Arguments.Count; $i++) {
        $argument = $Arguments[$i]
        if ([string]::Equals($argument, '--latest', [System.StringComparison]::OrdinalIgnoreCase) -or
            [string]::Equals($argument, '-Latest', [System.StringComparison]::OrdinalIgnoreCase)) {
            $script:Latest = $true
            continue
        }

        if ($argument -match '^--commit-number=(\d+)$') {
            $script:CommitNumber = [int]$Matches[1]
            continue
        }

        if ([string]::Equals($argument, '--commit-number', [System.StringComparison]::OrdinalIgnoreCase) -or
            [string]::Equals($argument, '-CommitNumber', [System.StringComparison]::OrdinalIgnoreCase)) {
            if ($i + 1 -ge $Arguments.Count -or $Arguments[$i + 1] -notmatch '^\d+$') {
                throw "$argument requires a numeric value."
            }

            $script:CommitNumber = [int]$Arguments[$i + 1]
            $i++
            continue
        }

        if ($argument -match '^--release-tag=(.+)$') {
            $script:ReleaseTag = $Matches[1]
            continue
        }

        if ([string]::Equals($argument, '--release-tag', [System.StringComparison]::OrdinalIgnoreCase) -or
            [string]::Equals($argument, '-ReleaseTag', [System.StringComparison]::OrdinalIgnoreCase)) {
            if ($i + 1 -ge $Arguments.Count) {
                throw "$argument requires a value."
            }

            $script:ReleaseTag = $Arguments[$i + 1]
            $i++
            continue
        }

        if ($argument -match '^--repository=(.+)$') {
            $script:Repository = $Matches[1]
            continue
        }

        if ([string]::Equals($argument, '--repository', [System.StringComparison]::OrdinalIgnoreCase) -or
            [string]::Equals($argument, '-Repository', [System.StringComparison]::OrdinalIgnoreCase)) {
            if ($i + 1 -ge $Arguments.Count) {
                throw "$argument requires a value."
            }

            $script:Repository = $Arguments[$i + 1]
            $i++
            continue
        }

        if ([string]::Equals($argument, '--no-push', [System.StringComparison]::OrdinalIgnoreCase) -or
            [string]::Equals($argument, '-NoPush', [System.StringComparison]::OrdinalIgnoreCase)) {
            $script:NoPush = $true
            continue
        }

        throw "Unknown argument: $argument"
    }
}

function Invoke-CheckedCommand {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $false)][string[]]$Arguments = @()
    )

    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$FilePath failed with exit code $LASTEXITCODE."
    }

    $global:LASTEXITCODE = 0
}

function Get-GhText {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $output = & gh @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "gh $($Arguments -join ' ') failed with exit code $LASTEXITCODE."
    }

    return (($output | Out-String).Trim())
}

function Assert-ReleaseTag {
    param([Parameter(Mandatory = $true)][string]$Tag)

    if ([string]::IsNullOrWhiteSpace($Tag) -or $Tag -match '[\\/\[\]\^\s\*`~:?<>|]') {
        throw "Invalid release tag: $Tag"
    }

    if ([string]::Equals($Tag, 'latest', [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'Pin the current version behind latest, not the moving latest alias itself.'
    }
}

function Read-PinManifest {
    if (-not (Test-Path -LiteralPath $pinFile -PathType Leaf)) {
        return [ordered]@{ pinnedReleaseTags = @() }
    }

    $raw = Get-Content -LiteralPath $pinFile -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return [ordered]@{ pinnedReleaseTags = @() }
    }

    $json = $raw | ConvertFrom-Json
    $tags = if ($null -ne $json.pinnedReleaseTags) { @($json.pinnedReleaseTags) } else { @() }
    return [ordered]@{ pinnedReleaseTags = @($tags | ForEach-Object { [string]$_ }) }
}

function Write-PinManifest {
    param([Parameter(Mandatory = $false)][string[]]$Tags = @())

    $payload = [ordered]@{
        pinnedReleaseTags = @($Tags | Sort-Object -Unique)
    }
    $payload | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $pinFile -Encoding UTF8
}

function Commit-PinManifest {
    param([Parameter(Mandatory = $true)][string]$Tag)

    Invoke-CheckedCommand -FilePath git -Arguments @('-C', $scriptRoot, 'add', 'release-pins.json')
    & git -C $scriptRoot diff --cached --quiet
    if ($LASTEXITCODE -eq 0) {
        $global:LASTEXITCODE = 0
        Write-Host "Release is already pinned: $Tag"
        return
    }

    $global:LASTEXITCODE = 0
    Invoke-CheckedCommand -FilePath git -Arguments @('-C', $scriptRoot, 'commit', '-m', "Pin Spiker setup release $Tag")
    if (-not $NoPush) {
        Invoke-CheckedCommand -FilePath git -Arguments @('-C', $scriptRoot, 'push', 'origin', 'HEAD')
    }
}

function Resolve-LatestVersionReleaseTag {
    $body = Get-GhText -Arguments @('release', 'view', 'latest', '--repo', $Repository, '--json', 'body', '--jq', '.body')
    $match = [regex]::Match($body, 'Current version release:\s*(v[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)')
    if ($match.Success) {
        return $match.Groups[1].Value
    }

    $tag = Get-GhText -Arguments @(
        'release', 'list',
        '--repo', $Repository,
        '--limit', '1000',
        '--json', 'tagName',
        '--jq', '[.[].tagName | select(. != "latest")] | first // ""')
    if ([string]::IsNullOrWhiteSpace($tag)) {
        throw "No current version release was found in $Repository."
    }

    return $tag
}

function Resolve-CommitNumberReleaseTag {
    param([Parameter(Mandatory = $true)][int]$Number)

    $tags = @(Get-GhText -Arguments @(
        'release', 'list',
        '--repo', $Repository,
        '--limit', '1000',
        '--json', 'tagName',
        '--jq', '.[].tagName') -split '\r?\n')
    $matches = @($tags | Where-Object { $_ -match ('^v[0-9]+\.[0-9]+\.[0-9]+\.' + [regex]::Escape([string]$Number) + '$') })
    if ($matches.Count -gt 0) {
        return [string]($matches | Sort-Object -Descending | Select-Object -First 1)
    }

    $latestTag = Resolve-LatestVersionReleaseTag
    if ($latestTag -match ('^v[0-9]+\.[0-9]+\.[0-9]+\.' + [regex]::Escape([string]$Number) + '$')) {
        return $latestTag
    }

    throw "No published setup release was found for commit number $Number."
}

function Test-ReleaseExists {
    param([Parameter(Mandatory = $true)][string]$Tag)

    & gh release view $Tag --repo $Repository *> $null
    $exists = $LASTEXITCODE -eq 0
    $global:LASTEXITCODE = 0
    return $exists
}

function Publish-VersionReleaseFromLatest {
    param([Parameter(Mandatory = $true)][string]$Tag)

    $latestTag = Resolve-LatestVersionReleaseTag
    if (-not [string]::Equals($latestTag, $Tag, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Release $Tag is not published and cannot be pinned from latest."
    }

    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('spiker-pin-release-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempRoot | Out-Null
    try {
        Invoke-CheckedCommand -FilePath gh -Arguments @('release', 'download', 'latest', '--repo', $Repository, '--pattern', 'spiker-setup.exe', '--dir', $tempRoot)
        $asset = Get-ChildItem -LiteralPath $tempRoot -Filter 'spiker-setup.exe' -File | Select-Object -First 1
        if ($null -eq $asset) {
            throw 'spiker-setup.exe was not downloaded from latest.'
        }

        $notes = Join-Path $tempRoot 'notes.md'
        @(
            "Pinned Spiker setup release copied from latest.",
            "Current version release: $Tag"
        ) | Set-Content -LiteralPath $notes -Encoding UTF8

        Invoke-CheckedCommand -FilePath gh -Arguments @(
            'release', 'create', $Tag, $asset.FullName,
            '--repo', $Repository,
            '--title', "Spiker Setup $Tag",
            '--notes-file', $notes)
    }
    finally {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Apply-Arguments
$selectorCount = 0
if ($Latest) { $selectorCount++ }
if ($CommitNumber -gt 0) { $selectorCount++ }
if (-not [string]::IsNullOrWhiteSpace($ReleaseTag)) { $selectorCount++ }
if ($selectorCount -ne 1) {
    throw 'Use exactly one target selector: --latest, --commit-number=<n>, or -ReleaseTag <tag>.'
}

$targetTag = if ($Latest) {
    Resolve-LatestVersionReleaseTag
}
elseif ($CommitNumber -gt 0) {
    Resolve-CommitNumberReleaseTag -Number $CommitNumber
}
else {
    $ReleaseTag
}

Assert-ReleaseTag -Tag $targetTag
if (-not (Test-ReleaseExists -Tag $targetTag)) {
    Publish-VersionReleaseFromLatest -Tag $targetTag
}

$manifest = Read-PinManifest
$tags = @($manifest.pinnedReleaseTags)
if ($tags -notcontains $targetTag) {
    $tags += $targetTag
}

Write-PinManifest -Tags $tags
Commit-PinManifest -Tag $targetTag
Write-Host "Pinned release: $targetTag"
