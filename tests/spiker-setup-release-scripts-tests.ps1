Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('spiker-setup-release-tests-' + [Guid]::NewGuid().ToString('N'))
$oldPath = $env:PATH

function Assert-True {
    param(
        [Parameter(Mandatory = $true)]
        [bool]$Condition,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

try {
    New-Item -ItemType Directory -Path $tempRoot | Out-Null
    $workRepo = Join-Path $tempRoot 'repo'
    $fakeBin = Join-Path $tempRoot 'bin'
    New-Item -ItemType Directory -Path $workRepo, $fakeBin | Out-Null

    Copy-Item -LiteralPath (Join-Path $repoRoot 'pin-release-version.ps1') -Destination $workRepo
    Copy-Item -LiteralPath (Join-Path $repoRoot 'unpin-release-version.ps1') -Destination $workRepo
    Copy-Item -LiteralPath (Join-Path $repoRoot 'release-pins.json') -Destination $workRepo

    $deleteLog = Join-Path $tempRoot 'deleted.txt'
    $fakeGh = Join-Path $fakeBin 'gh.cmd'
    Set-Content -LiteralPath $fakeGh -Encoding ASCII -Value @'
@echo off
if "%1"=="release" if "%2"=="list" (
  echo v2026.6.12.200
  echo latest
  echo v2026.6.11.199
  exit /b 0
)
if "%1"=="release" if "%2"=="view" if "%3"=="latest" (
  echo Current version release: v2026.6.12.200
  exit /b 0
)
if "%1"=="release" if "%2"=="view" exit /b 0
if "%1"=="release" if "%2"=="delete" (
  echo %3>>"%SPIKER_FAKE_GH_DELETE_LOG%"
  exit /b 0
)
exit /b 0
'@

    $env:SPIKER_FAKE_GH_DELETE_LOG = $deleteLog
    $env:PATH = $fakeBin + [System.IO.Path]::PathSeparator + $oldPath

    git -C $workRepo init | Out-Null
    git -C $workRepo config user.email spiker-tests@example.invalid
    git -C $workRepo config user.name "Spiker Tests"
    git -C $workRepo add .
    git -C $workRepo commit -m init | Out-Null

    & (Join-Path $workRepo 'pin-release-version.ps1') --latest -NoPush
    $manifest = Get-Content -LiteralPath (Join-Path $workRepo 'release-pins.json') -Raw | ConvertFrom-Json
    Assert-True -Condition (@($manifest.pinnedReleaseTags) -contains 'v2026.6.12.200') -Message 'Current release pin was not written.'

    & (Join-Path $workRepo 'unpin-release-version.ps1') --commit-number=200 -NoPush
    $manifest = Get-Content -LiteralPath (Join-Path $workRepo 'release-pins.json') -Raw | ConvertFrom-Json
    Assert-True -Condition (-not (@($manifest.pinnedReleaseTags) -contains 'v2026.6.12.200')) -Message 'Pinned release was not removed.'
    Assert-True -Condition ((Get-Content -LiteralPath $deleteLog -Raw).Trim() -eq 'v2026.6.12.200') -Message 'Pinned release was not purged through gh.'

    $downloader = Get-Content -LiteralPath (Join-Path $repoRoot 'spiker-setup-downloader.ps1') -Raw
    Assert-True -Condition ($downloader.Contains('releases/download/latest')) -Message 'Downloader does not use the stable latest asset URL.'
    Assert-True -Condition (-not $downloader.Contains('/releases/latest')) -Message 'Downloader still uses the mutable releases/latest API endpoint.'

    $workflow = Get-Content -LiteralPath (Join-Path $repoRoot '.github\workflows\publish-spiker-setup.yml') -Raw
    Assert-True -Condition ($workflow.Contains('EXPECTED_ARTIFACT_SHA256')) -Message 'Release workflow does not validate the expected source artifact SHA256.'
    Assert-True -Condition ($workflow.Contains('force_update_tag latest')) -Message 'Release workflow does not force-update the latest tag.'
    Assert-True -Condition ($workflow.Contains('verify_release_asset_metadata latest "$sha256"')) -Message 'Release workflow does not verify the stable latest download asset metadata.'
    Assert-True -Condition ($workflow.Contains('.digest')) -Message 'Release workflow does not use GitHub asset digest metadata for fast verification.'
    Assert-True -Condition ($workflow.Contains('curl -fsSI')) -Message 'Release workflow does not use a lightweight HEAD check for canonical release URLs.'
    Assert-True -Condition ($workflow.Contains('releases/download/$tag/spiker-setup.exe')) -Message 'Release workflow does not verify canonical release download URLs.'

    Write-Host 'spiker-setup release script tests passed.'
}
finally {
    $env:PATH = $oldPath
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
