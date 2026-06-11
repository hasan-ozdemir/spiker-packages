param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repository = 'hasan-ozdemir/spiker-setup'
$userAgent = 'spiker-setup'
$headers = @{
    Accept = 'application/vnd.github+json'
    'User-Agent' = $userAgent
}
$utf8 = New-Object System.Text.UTF8Encoding $false

function Set-SpikerUtf8Console {
    try {
        $chcp = if ($env:WINDIR) { Join-Path $env:WINDIR 'System32\chcp.com' } else { 'chcp.com' }
        if (Get-Command $chcp -ErrorAction SilentlyContinue) {
            & $chcp 65001 | Out-Null
        }
    }
    catch {
    }

    try {
        [Console]::InputEncoding = $utf8
        [Console]::OutputEncoding = $utf8
    }
    catch {
    }

    $script:OutputEncoding = $utf8
    $global:OutputEncoding = $utf8
}

function Initialize-SpikerNetwork {
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    }
    catch {
    }

    try {
        $proxy = [System.Net.WebRequest]::DefaultWebProxy
        if ($null -ne $proxy) {
            $proxy.Credentials = [System.Net.CredentialCache]::DefaultNetworkCredentials
        }
    }
    catch {
    }
}

function Get-SpikerErrorMessage {
    param([Parameter(Mandatory = $true)][System.Exception]$Exception)

    if ($Exception.InnerException -and -not [string]::IsNullOrWhiteSpace($Exception.InnerException.Message)) {
        return $Exception.Message + "`n" + $Exception.InnerException.Message
    }

    return $Exception.Message
}

function Show-SpikerError {
    param([Parameter(Mandatory = $true)][string]$Message)

    try {
        $shell = New-Object -ComObject WScript.Shell
        $null = $shell.Popup($Message, 0, 'Spiker Kurulum', 16)
    }
    catch {
        Write-Host $Message
    }
}

try {
    Set-SpikerUtf8Console
    Initialize-SpikerNetwork

    $branchUrl = "https://api.github.com/repos/$repository/branches/main"
    $sha = [string](Invoke-RestMethod -Uri $branchUrl -UseBasicParsing -Headers $headers).commit.sha
    if ([string]::IsNullOrWhiteSpace($sha) -or $sha -notmatch '^[0-9a-fA-F]{40}$') {
        throw 'spiker-setup main dalı için geçerli commit bilgisi alınamadı.'
    }

    $downloaderUrl = "https://raw.githubusercontent.com/$repository/$sha/spiker-setup-downloader.ps1"
    $downloaderText = [string](Invoke-WebRequest -Uri $downloaderUrl -UseBasicParsing -Headers @{ 'User-Agent' = $userAgent }).Content
    if ([string]::IsNullOrWhiteSpace($downloaderText)) {
        throw 'Spiker kurulum indiricisi boş geldi.'
    }

    $downloader = [scriptblock]::Create($downloaderText)
    & $downloader -DownloaderUrl $downloaderUrl
}
catch {
    Show-SpikerError -Message ("Spiker kurulumu başlatılamadı.`n`n" + (Get-SpikerErrorMessage -Exception $_.Exception))
    throw
}
