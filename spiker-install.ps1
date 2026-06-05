param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$repository = 'hasan-ozdemir/spiker-packages'
$assetName = 'spiker-setup.exe'
$installerScriptUrl = 'https://raw.githubusercontent.com/hasan-ozdemir/spiker-packages/main/spiker-install.ps1'
$releaseApiUrl = "https://api.github.com/repos/$repository/releases/latest"
$userAgent = 'spiker-install'
$originalProgressPreference = $ProgressPreference
$ProgressPreference = 'SilentlyContinue'

function Write-Info {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host "[Spiker] $Message"
}

function Show-UserMessage {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [Parameter(Mandatory = $false)][string]$Title = 'Spiker Kurulum',
        [Parameter(Mandatory = $false)][int]$Icon = 64
    )

    try {
        $shell = New-Object -ComObject WScript.Shell
        $null = $shell.Popup($Message, 0, $Title, $Icon)
    }
    catch {
        Write-Host $Message
    }
}

function Enable-ProcessScriptExecution {
    try {
        Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force -ErrorAction Stop
        return
    }
    catch {
        Write-Warning "PowerShell script yürütme izni bu oturum için otomatik ayarlanamadı: $($_.Exception.Message)"
    }

    $prompt = 'PowerShell script çalıştırma izni bu kullanıcı için RemoteSigned yapılsın mı? (E/H)'
    $answer = if ([Environment]::UserInteractive) { Read-Host $prompt } else { 'H' }
    if ($answer -match '^(e|E|evet|EVET|y|Y|yes|YES)$') {
        Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force -ErrorAction Stop
        return
    }

    throw 'PowerShell script yürütme izni verilmediği için Spiker kurulumu başlatılamadı.'
}

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-SafeTempRoot {
    $tempRoot = [System.IO.Path]::GetTempPath()
    if ([string]::IsNullOrWhiteSpace($tempRoot)) {
        throw 'Temp klasörü bulunamadı.'
    }

    $tempRootFull = [System.IO.Path]::GetFullPath($tempRoot)
    if (-not $tempRootFull.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
        $tempRootFull += [System.IO.Path]::DirectorySeparatorChar
    }

    return $tempRootFull
}

function Test-SafeInstallDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)

    $tempRootFull = Get-SafeTempRoot
    $expected = [System.IO.Path]::GetFullPath((Join-Path $tempRootFull 'spiker-setup')).TrimEnd('\')
    $actual = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')

    return [string]::Equals($expected, $actual, [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-SafeInstallDirectory {
    $installDirectory = Join-Path (Get-SafeTempRoot) 'spiker-setup'
    if (-not (Test-SafeInstallDirectory -Path $installDirectory)) {
        throw "Güvenli olmayan temp yolu: $installDirectory"
    }

    if (Test-Path -LiteralPath $installDirectory) {
        Remove-SafeInstallDirectory -Path $installDirectory
    }

    New-Item -Path $installDirectory -ItemType Directory -Force | Out-Null
    return [System.IO.Path]::GetFullPath($installDirectory)
}

function Remove-SafeInstallDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        return
    }

    if (-not (Test-SafeInstallDirectory -Path $Path)) {
        throw "Güvenli olmayan temizlik yolu: $Path"
    }

    Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
}

function New-ElevatedBootstrapScript {
    $tempRoot = Get-SafeTempRoot
    $bootstrapPath = Join-Path $tempRoot ('spiker-install-bootstrap-' + ([Guid]::NewGuid().ToString('N')) + '.ps1')
    $escapedBootstrapPath = $bootstrapPath.Replace("'", "''")
    $escapedInstallerUrl = $installerScriptUrl.Replace("'", "''")

    $content = @"
`$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
`$OutputEncoding = [System.Text.Encoding]::UTF8

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}
catch {
}

try {
    Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force -ErrorAction SilentlyContinue
    `$webClient = New-Object System.Net.WebClient
    try {
        `$webClient.Headers['User-Agent'] = 'spiker-install-bootstrap'
        `$script = `$webClient.DownloadString('$escapedInstallerUrl')
    }
    finally {
        `$webClient.Dispose()
    }

    Invoke-Expression `$script
}
catch {
    `$message = 'Spiker kurulumu başlatılamadı: ' + `$_.Exception.Message
    try {
        `$shell = New-Object -ComObject WScript.Shell
        `$null = `$shell.Popup(`$message, 0, 'Spiker Kurulum', 16)
    }
    catch {
        Write-Error `$message
    }

    exit 1
}
finally {
    Remove-Item -LiteralPath '$escapedBootstrapPath' -Force -ErrorAction SilentlyContinue
}
"@

    Set-Content -LiteralPath $bootstrapPath -Value $content -Encoding UTF8
    return $bootstrapPath
}

function Start-ElevatedInstaller {
    Write-Info 'Spiker kurulumu yönetici izni gerektiriyor.'
    Write-Info 'Birazdan Windows izin penceresi açılacak. Lütfen izin verin.'

    $bootstrapPath = New-ElevatedBootstrapScript
    $powerShell = (Get-Command powershell.exe -ErrorAction Stop).Source

    try {
        Start-Process -FilePath $powerShell -ArgumentList @(
            '-NoProfile',
            '-ExecutionPolicy',
            'Bypass',
            '-File',
            "`"$bootstrapPath`""
        ) -Verb RunAs -WindowStyle Normal | Out-Null
    }
    catch {
        Remove-Item -LiteralPath $bootstrapPath -Force -ErrorAction SilentlyContinue
        Show-UserMessage -Message "Yönetici izni alınamadı. Spiker kurulumu başlatılamadı.`n`n$($_.Exception.Message)" -Icon 16
        throw
    }

    Write-Info 'Yönetici kurulum penceresi başlatıldı. Bu pencere kapanabilir.'
}

function Hide-ConsoleWindow {
    try {
        if ($null -eq ([System.Management.Automation.PSTypeName]'SpikerConsoleWindow').Type) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class SpikerConsoleWindow
{
    [DllImport("kernel32.dll")]
    public static extern IntPtr GetConsoleWindow();

    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
}
'@
        }

        $handle = [SpikerConsoleWindow]::GetConsoleWindow()
        if ($handle -ne [IntPtr]::Zero) {
            [SpikerConsoleWindow]::ShowWindow($handle, 0) | Out-Null
        }
    }
    catch {
    }
}

function Invoke-GitHubRequest {
    param([Parameter(Mandatory = $true)][string]$Uri)

    Invoke-RestMethod -Uri $Uri -Headers @{
        Accept = 'application/vnd.github+json'
        'User-Agent' = $userAgent
    }
}

function Get-LatestSetupAsset {
    Write-Info 'En son Spiker kurulum yayını aranıyor...'
    $release = Invoke-GitHubRequest -Uri $releaseApiUrl
    if ($null -eq $release.assets) {
        throw 'GitHub yayınında indirilebilir dosya bulunamadı.'
    }

    $asset = @($release.assets | Where-Object { $_.name -eq $assetName } | Select-Object -First 1)
    if ($asset.Count -ne 1 -or [string]::IsNullOrWhiteSpace([string]$asset[0].browser_download_url)) {
        throw "En son GitHub yayınında $assetName bulunamadı."
    }

    $digestProperty = $asset[0].PSObject.Properties['digest']
    $digest = if ($null -ne $digestProperty) { [string]$digestProperty.Value } else { '' }

    return [pscustomobject]@{
        ReleaseName = [string]$release.name
        ReleaseTag = [string]$release.tag_name
        DownloadUrl = [string]$asset[0].browser_download_url
        Size = [int64]$asset[0].size
        Digest = $digest
    }
}

function Save-SetupAsset {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Asset,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    $uri = [System.Uri]$Asset.DownloadUrl
    if ($uri.Scheme -ne 'https') {
        throw "Güvenli olmayan indirme adresi: $($Asset.DownloadUrl)"
    }

    Write-Info "Kurulum paketi indiriliyor: $($Asset.ReleaseTag)"
    $webClient = New-Object System.Net.WebClient
    try {
        $webClient.Headers['User-Agent'] = $userAgent
        $webClient.DownloadFile($Asset.DownloadUrl, $Destination)
    }
    finally {
        $webClient.Dispose()
    }

    $downloaded = Get-Item -LiteralPath $Destination
    if ($downloaded.Length -le 0) {
        throw 'Kurulum dosyası boş indirildi.'
    }

    if ($Asset.Size -gt 0 -and $downloaded.Length -ne $Asset.Size) {
        throw "Kurulum dosyası boyutu beklenenden farklı. Beklenen=$($Asset.Size), indirilen=$($downloaded.Length)."
    }

    if (-not [string]::IsNullOrWhiteSpace($Asset.Digest) -and $Asset.Digest.StartsWith('sha256:', [System.StringComparison]::OrdinalIgnoreCase)) {
        $expectedHash = $Asset.Digest.Substring('sha256:'.Length).ToUpperInvariant()
        $actualHash = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash.ToUpperInvariant()
        if ($actualHash -ne $expectedHash) {
            throw "SHA256 doğrulaması başarısız. Beklenen=$expectedHash, indirilen=$actualHash."
        }
    }

    if (Get-Command Unblock-File -ErrorAction SilentlyContinue) {
        Unblock-File -LiteralPath $Destination -ErrorAction SilentlyContinue
    }
}

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}
catch {
}

$installDirectory = $null
try {
    Enable-ProcessScriptExecution

    if (-not (Test-Administrator)) {
        Start-ElevatedInstaller
        return
    }

    Write-Info 'Yönetici izni doğrulandı.'
    $installDirectory = Get-SafeInstallDirectory
    $setupPath = Join-Path $installDirectory $assetName
    $asset = Get-LatestSetupAsset

    Save-SetupAsset -Asset $asset -Destination $setupPath

    Write-Info 'Kurulum asistanı başlatılıyor. PowerShell penceresi gizlenecek.'
    $process = Start-Process -FilePath $setupPath -WorkingDirectory $installDirectory -WindowStyle Normal -PassThru
    Hide-ConsoleWindow
    $process.WaitForExit()

    $exitCode = if ($null -ne $process.ExitCode) { [int]$process.ExitCode } else { 0 }
    if ($exitCode -ne 0) {
        throw "Spiker kurulumu $exitCode çıkış koduyla sonlandı."
    }
}
catch {
    Show-UserMessage -Message "Spiker kurulumu tamamlanamadı.`n`n$($_.Exception.Message)" -Icon 16
    throw
}
finally {
    $ProgressPreference = $originalProgressPreference
    if ($null -ne $installDirectory) {
        try {
            Remove-SafeInstallDirectory -Path $installDirectory
        }
        catch {
            Show-UserMessage -Message "Geçici Spiker kurulum klasörü temizlenemedi:`n$installDirectory`n`n$($_.Exception.Message)" -Icon 48
        }
    }
}
