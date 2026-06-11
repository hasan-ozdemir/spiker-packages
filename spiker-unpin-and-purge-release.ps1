Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Warning 'spiker-unpin-and-purge-release.ps1 is deprecated. Use unpin-release-version.ps1.'
& (Join-Path $PSScriptRoot 'unpin-release-version.ps1') @args
exit $LASTEXITCODE
