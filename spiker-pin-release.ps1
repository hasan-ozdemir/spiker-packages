Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Warning 'spiker-pin-release.ps1 is deprecated. Use pin-release-version.ps1.'
& (Join-Path $PSScriptRoot 'pin-release-version.ps1') @args
exit $LASTEXITCODE
