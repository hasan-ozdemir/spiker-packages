param(
    [Parameter(Mandatory = $false)]
    [switch]$Current,

    [Parameter(Mandatory = $false)]
    [string]$ReleaseTag = '',

    [Parameter(Mandatory = $false)]
    [string]$Repository = 'hasan-ozdemir/spiker-setup',

    [Parameter(Mandatory = $false)]
    [switch]$NoPush
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$pinFile = Join-Path $scriptRoot 'release-pins.json'

function Invoke-CheckedCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [Parameter(Mandatory = $false)]
        [string[]]$Arguments = @()
    )

    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$FilePath failed with exit code $LASTEXITCODE."
    }
}

function Assert-ReleaseTag {
    param([Parameter(Mandatory = $true)][string]$Tag)

    if ([string]::IsNullOrWhiteSpace($Tag) -or $Tag -match '[\\/\[\]\^\s\*`~:?<>|]') {
        throw "Invalid release tag: $Tag"
    }
}

function Resolve-CurrentReleaseTag {
    $tags = @(& gh release list --repo $Repository --limit 100 --json tagName --jq '.[].tagName')
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to list releases for $Repository."
    }

    $tag = @($tags | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_) -and
        -not [string]::Equals($_, 'latest', [System.StringComparison]::OrdinalIgnoreCase)
    } | Select-Object -First 1)

    if ($tag.Count -ne 1) {
        throw "No current version release was found in $Repository."
    }

    return [string]$tag[0]
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
        Write-Host "Release is already pinned: $Tag"
        return
    }

    Invoke-CheckedCommand -FilePath git -Arguments @('-C', $scriptRoot, 'commit', '-m', "Pin Spiker setup release $Tag")
    if (-not $NoPush) {
        Invoke-CheckedCommand -FilePath git -Arguments @('-C', $scriptRoot, 'push', 'origin', 'HEAD')
    }
}

if ($Current -and -not [string]::IsNullOrWhiteSpace($ReleaseTag)) {
    throw 'Use either -Current or -ReleaseTag, not both.'
}

$targetTag = if ($Current) { Resolve-CurrentReleaseTag } else { $ReleaseTag }
Assert-ReleaseTag -Tag $targetTag
Invoke-CheckedCommand -FilePath gh -Arguments @('release', 'view', $targetTag, '--repo', $Repository)

$manifest = Read-PinManifest
$tags = @($manifest.pinnedReleaseTags)
if ($tags -notcontains $targetTag) {
    $tags += $targetTag
}

Write-PinManifest -Tags $tags
Commit-PinManifest -Tag $targetTag
Write-Host "Pinned release: $targetTag"
