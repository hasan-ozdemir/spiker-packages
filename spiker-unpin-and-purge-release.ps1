param(
    [Parameter(Mandatory = $true)]
    [string]$ReleaseTag,

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

    if ([string]::Equals($Tag, 'latest', [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'The latest alias cannot be purged with the pinned release purge script.'
    }
}

function Read-PinManifest {
    if (-not (Test-Path -LiteralPath $pinFile -PathType Leaf)) {
        return @()
    }

    $raw = Get-Content -LiteralPath $pinFile -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return @()
    }

    $json = $raw | ConvertFrom-Json
    if ($null -eq $json.pinnedReleaseTags) {
        return @()
    }

    return @($json.pinnedReleaseTags | ForEach-Object { [string]$_ })
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
    if ($LASTEXITCODE -ne 0) {
        Invoke-CheckedCommand -FilePath git -Arguments @('-C', $scriptRoot, 'commit', '-m', "Unpin Spiker setup release $Tag")
        if (-not $NoPush) {
            Invoke-CheckedCommand -FilePath git -Arguments @('-C', $scriptRoot, 'push', 'origin', 'HEAD')
        }
    }
}

Assert-ReleaseTag -Tag $ReleaseTag
$tags = Read-PinManifest
if ($tags -notcontains $ReleaseTag) {
    throw "Release is not pinned and will not be purged by this script: $ReleaseTag"
}

$remaining = @($tags | Where-Object { -not [string]::Equals($_, $ReleaseTag, [System.StringComparison]::OrdinalIgnoreCase) })
Write-PinManifest -Tags $remaining
Commit-PinManifest -Tag $ReleaseTag

Invoke-CheckedCommand -FilePath gh -Arguments @('release', 'delete', $ReleaseTag, '--repo', $Repository, '--cleanup-tag', '--yes')
Write-Host "Unpinned and purged release: $ReleaseTag"
