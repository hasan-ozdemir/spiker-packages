param(
    [Parameter(Mandatory = $false)]
    [switch]$RelaunchedForRequiredHost,

    [Parameter(Mandatory = $false)]
    [string]$DownloaderUrl = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:Utf8NoBom = New-Object System.Text.UTF8Encoding $false
$script:Utf8Bom = New-Object System.Text.UTF8Encoding $true

function Set-SpikerUtf8Console {
    try {
        $chcp = if (-not [string]::IsNullOrWhiteSpace($env:WINDIR)) {
            Join-Path $env:WINDIR 'System32\chcp.com'
        }
        else {
            'chcp.com'
        }

        if (Get-Command $chcp -ErrorAction SilentlyContinue) {
            & $chcp 65001 | Out-Null
        }
    }
    catch {
    }

    try {
        [Console]::InputEncoding = $script:Utf8NoBom
    }
    catch {
    }

    try {
        [Console]::OutputEncoding = $script:Utf8NoBom
    }
    catch {
    }

    $script:OutputEncoding = $script:Utf8NoBom
    $global:OutputEncoding = $script:Utf8NoBom
}

Set-SpikerUtf8Console

$repository = 'hasan-ozdemir/spiker-packages'
$assetName = 'spiker-setup.exe'
$targetInstallDirectory = 'C:\prodyum\spiker'
$installerScriptUrl = if ([string]::IsNullOrWhiteSpace($DownloaderUrl)) {
    'https://raw.githubusercontent.com/hasan-ozdemir/spiker-packages/main/spiker-setup-downloader.ps1'
}
else {
    $DownloaderUrl
}
$releaseApiUrl = "https://api.github.com/repos/$repository/releases/latest"
$userAgent = 'spiker-install'
$originalProgressPreference = $ProgressPreference
$ProgressPreference = 'SilentlyContinue'
$script:SuppressTopLevelUserMessage = $false

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

function Get-ExceptionMessage {
    param([Parameter(Mandatory = $true)][System.Exception]$Exception)

    $parts = New-Object System.Collections.Generic.List[string]
    $current = $Exception
    while ($null -ne $current) {
        if (-not [string]::IsNullOrWhiteSpace($current.Message) -and -not $parts.Contains($current.Message)) {
            $parts.Add($current.Message) | Out-Null
        }

        $webException = $current -as [System.Net.WebException]
        if ($null -ne $webException) {
            $status = $webException.Status.ToString()
            if (-not [string]::IsNullOrWhiteSpace($status) -and -not $parts.Contains("Web durumu: $status")) {
                $parts.Add("Web durumu: $status") | Out-Null
            }

            $httpResponse = $webException.Response -as [System.Net.HttpWebResponse]
            if ($null -ne $httpResponse) {
                $httpStatus = "HTTP {0} {1}" -f [int]$httpResponse.StatusCode, $httpResponse.StatusDescription
                if (-not $parts.Contains($httpStatus)) {
                    $parts.Add($httpStatus) | Out-Null
                }
            }
        }

        $current = $current.InnerException
    }

    if ($parts.Count -eq 0) {
        return 'Bilinmeyen hata.'
    }

    return ($parts -join "`n")
}

function Initialize-Network {
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

function Get-WindowsPowerShellPath {
    $candidates = @()
    if (-not [string]::IsNullOrWhiteSpace($env:WINDIR)) {
        $candidates += Join-Path $env:WINDIR 'Sysnative\WindowsPowerShell\v1.0\powershell.exe'
        $candidates += Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $candidates += Join-Path $env:WINDIR 'SysWOW64\WindowsPowerShell\v1.0\powershell.exe'
    }

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            return [System.IO.Path]::GetFullPath($candidate)
        }
    }

    $command = Get-Command powershell.exe -ErrorAction Stop
    return [System.IO.Path]::GetFullPath($command.Source)
}

function Test-WindowsPowerShell51 {
    $edition = if ($PSVersionTable.ContainsKey('PSEdition')) { [string]$PSVersionTable.PSEdition } else { '' }
    return $edition -eq 'Desktop' -and $PSVersionTable.PSVersion.Major -eq 5 -and $PSVersionTable.PSVersion.Minor -eq 1
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

function Test-TemporaryInstallerScript {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }

    $tempRootFull = Get-SafeTempRoot
    $pathFull = [System.IO.Path]::GetFullPath($Path)
    if (-not $pathFull.StartsWith($tempRootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $false
    }

    $fileName = [System.IO.Path]::GetFileName($pathFull)
    return ($fileName.StartsWith('spiker-install-', [System.StringComparison]::OrdinalIgnoreCase) -or
        $fileName.StartsWith('spiker-setup-downloader-', [System.StringComparison]::OrdinalIgnoreCase)) -and
        $fileName.EndsWith('.ps1', [System.StringComparison]::OrdinalIgnoreCase)
}

function Remove-TemporaryInstallerScript {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (Test-TemporaryInstallerScript -Path $Path) {
        Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    }
}

function Add-RestartManagerType {
    if ($null -ne ([System.Management.Automation.PSTypeName]'SpikerInstaller.RestartManager').Type) {
        return
    }

    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

namespace SpikerInstaller
{
    public static class RestartManager
    {
        private const int CchRmSessionKey = 32;
        private const int ErrorMoreData = 234;

        [StructLayout(LayoutKind.Sequential)]
        private struct FILETIME
        {
            public uint dwLowDateTime;
            public uint dwHighDateTime;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct RM_UNIQUE_PROCESS
        {
            public int dwProcessId;
            public FILETIME ProcessStartTime;
        }

        private enum RM_APP_TYPE
        {
            RmUnknownApp = 0,
            RmMainWindow = 1,
            RmOtherWindow = 2,
            RmService = 3,
            RmExplorer = 4,
            RmConsole = 5,
            RmCritical = 1000
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct RM_PROCESS_INFO
        {
            public RM_UNIQUE_PROCESS Process;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)]
            public string strAppName;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)]
            public string strServiceShortName;
            public RM_APP_TYPE ApplicationType;
            public uint AppStatus;
            public uint TSSessionId;
            [MarshalAs(UnmanagedType.Bool)]
            public bool bRestartable;
        }

        [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
        private static extern int RmStartSession(out uint pSessionHandle, int dwSessionFlags, StringBuilder strSessionKey);

        [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
        private static extern int RmRegisterResources(
            uint pSessionHandle,
            uint nFiles,
            string[] rgsFilenames,
            uint nApplications,
            IntPtr rgApplications,
            uint nServices,
            string[] rgsServiceNames);

        [DllImport("rstrtmgr.dll")]
        private static extern int RmGetList(
            uint dwSessionHandle,
            out uint pnProcInfoNeeded,
            ref uint pnProcInfo,
            [In, Out] RM_PROCESS_INFO[] rgAffectedApps,
            ref uint lpdwRebootReasons);

        [DllImport("rstrtmgr.dll")]
        private static extern int RmEndSession(uint pSessionHandle);

        public static int[] GetLockingProcessIds(string[] resources)
        {
            if (resources == null || resources.Length == 0)
            {
                return new int[0];
            }

            uint handle;
            var key = new StringBuilder(CchRmSessionKey + 1);
            var result = RmStartSession(out handle, 0, key);
            if (result != 0)
            {
                throw new Win32Exception(result, "Restart Manager oturumu başlatılamadı.");
            }

            try
            {
                const int chunkSize = 128;
                for (var index = 0; index < resources.Length; index += chunkSize)
                {
                    var count = Math.Min(chunkSize, resources.Length - index);
                    var chunk = new string[count];
                    Array.Copy(resources, index, chunk, 0, count);
                    result = RmRegisterResources(handle, (uint)chunk.Length, chunk, 0, IntPtr.Zero, 0, null);
                    if (result != 0)
                    {
                        throw new Win32Exception(result, "Restart Manager kaynak kaydı başarısız oldu.");
                    }
                }

                uint needed;
                uint countInfo = 0;
                uint rebootReasons = 0;
                result = RmGetList(handle, out needed, ref countInfo, null, ref rebootReasons);
                if (result == 0)
                {
                    return new int[0];
                }

                if (result != ErrorMoreData)
                {
                    throw new Win32Exception(result, "Restart Manager process listesi alınamadı.");
                }

                countInfo = needed;
                var processes = new RM_PROCESS_INFO[countInfo];
                result = RmGetList(handle, out needed, ref countInfo, processes, ref rebootReasons);
                if (result != 0)
                {
                    throw new Win32Exception(result, "Restart Manager process listesi okunamadı.");
                }

                var ids = new HashSet<int>();
                for (var index = 0; index < countInfo; index++)
                {
                    var id = processes[index].Process.dwProcessId;
                    if (id > 0)
                    {
                        ids.Add(id);
                    }
                }

                var output = new int[ids.Count];
                ids.CopyTo(output);
                return output;
            }
            finally
            {
                RmEndSession(handle);
            }
        }
    }
}
'@
}

function Get-SpikerInstallResources {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return @()
    }

    $resources = New-Object System.Collections.Generic.List[string]
    foreach ($item in Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue) {
        $resources.Add([System.IO.Path]::GetFullPath($item.FullName)) | Out-Null
    }

    return @($resources | Select-Object -Unique)
}

function Get-LockingProcessIds {
    param([Parameter(Mandatory = $true)][string]$Path)

    $resources = @(Get-SpikerInstallResources -Path $Path)
    if ($resources.Count -eq 0) {
        return @()
    }

    Add-RestartManagerType
    return @([SpikerInstaller.RestartManager]::GetLockingProcessIds($resources))
}

function Get-ProcessRestartInfo {
    param([Parameter(Mandatory = $true)][object[]]$ProcessIds)

    $currentProcessId = [System.Diagnostics.Process]::GetCurrentProcess().Id
    $infos = @()
    foreach ($rawProcessId in ($ProcessIds | Sort-Object -Unique)) {
        $processId = [int]$rawProcessId
        if ($processId -eq $currentProcessId) {
            continue
        }

        $processInfo = Get-CimInstance Win32_Process -Filter "ProcessId = $processId" -ErrorAction SilentlyContinue
        if ($null -eq $processInfo) {
            continue
        }

        $commandLine = [string]$processInfo.CommandLine
        $executablePath = [string]$processInfo.ExecutablePath
        if ([string]::IsNullOrWhiteSpace($commandLine) -and [string]::IsNullOrWhiteSpace($executablePath)) {
            throw "Process yeniden başlatma bilgisi alınamadı. PID=$processId"
        }

        $infos += [pscustomobject]@{
            ProcessId = [int]$processInfo.ProcessId
            Name = [string]$processInfo.Name
            ExecutablePath = $executablePath
            CommandLine = $commandLine
        }
    }

    return @($infos)
}

function Split-ProcessCommandLine {
    param(
        [Parameter(Mandatory = $false)][string]$ExecutablePath,
        [Parameter(Mandatory = $false)][string]$CommandLine
    )

    $command = if ([string]::IsNullOrWhiteSpace($CommandLine)) { '' } else { $CommandLine.Trim() }
    if ([string]::IsNullOrWhiteSpace($command)) {
        if ([string]::IsNullOrWhiteSpace($ExecutablePath)) {
            throw 'Process komut satırı boş.'
        }

        return [pscustomobject]@{ FileName = $ExecutablePath; Arguments = '' }
    }

    $parsedFile = ''
    $parsedArguments = ''
    if ($command.StartsWith('"')) {
        $endQuote = $command.IndexOf('"', 1)
        if ($endQuote -lt 0) {
            throw "Process komut satırı ayrıştırılamadı: $command"
        }

        $parsedFile = $command.Substring(1, $endQuote - 1)
        $parsedArguments = $command.Substring($endQuote + 1).TrimStart()
    }
    else {
        $space = $command.IndexOf(' ')
        if ($space -lt 0) {
            $parsedFile = $command
            $parsedArguments = ''
        }
        else {
            $parsedFile = $command.Substring(0, $space)
            $parsedArguments = $command.Substring($space + 1).TrimStart()
        }
    }

    $fileName = if (-not [string]::IsNullOrWhiteSpace($ExecutablePath)) { $ExecutablePath } else { $parsedFile }
    if (-not [string]::IsNullOrWhiteSpace($ExecutablePath)) {
        $sameExecutable =
            [string]::Equals($parsedFile, $ExecutablePath, [System.StringComparison]::OrdinalIgnoreCase) -or
            [string]::Equals([System.IO.Path]::GetFileName($parsedFile), [System.IO.Path]::GetFileName($ExecutablePath), [System.StringComparison]::OrdinalIgnoreCase)
        if (-not $sameExecutable) {
            $parsedArguments = $command
        }
    }

    return [pscustomobject]@{ FileName = $fileName; Arguments = $parsedArguments }
}

function Stop-ProcessesForInstallCleanup {
    param([Parameter(Mandatory = $true)][object[]]$Processes)

    foreach ($processInfo in $Processes) {
        Write-Info ("Spiker klasörünü kullanan process durduruluyor: {0} (PID {1})" -f $processInfo.Name, $processInfo.ProcessId)
        $process = Get-Process -Id $processInfo.ProcessId -ErrorAction SilentlyContinue
        if ($null -eq $process) {
            continue
        }

        try {
            if ($process.MainWindowHandle -ne 0) {
                $null = $process.CloseMainWindow()
                if ($process.WaitForExit(10000)) {
                    continue
                }
            }
        }
        catch {
        }

        Stop-Process -Id $processInfo.ProcessId -Force -ErrorAction SilentlyContinue
        try {
            $process.WaitForExit(10000) | Out-Null
        }
        catch {
        }
    }
}

function Restart-ProcessesForInstallCleanup {
    param([Parameter(Mandatory = $true)][object[]]$Processes)

    foreach ($processInfo in $Processes) {
        $command = Split-ProcessCommandLine -ExecutablePath $processInfo.ExecutablePath -CommandLine $processInfo.CommandLine
        if ([string]::IsNullOrWhiteSpace($command.FileName)) {
            throw "Process yeniden başlatılamadı; çalıştırılabilir dosya yolu yok. PID=$($processInfo.ProcessId)"
        }

        Write-Info ("Process yeniden başlatılıyor: {0}" -f $processInfo.Name)
        $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = $command.FileName
        $startInfo.Arguments = $command.Arguments
        if (Test-Path -LiteralPath $command.FileName -PathType Leaf) {
            $startInfo.WorkingDirectory = Split-Path -Parent $command.FileName
        }

        $startInfo.UseShellExecute = $false
        $started = [System.Diagnostics.Process]::Start($startInfo)
        if ($null -eq $started) {
            throw "Process yeniden başlatılamadı: $($processInfo.Name)"
        }
    }
}

function Clear-SpikerInstallDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    $fullPath = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    if (-not [string]::Equals($fullPath, 'C:\prodyum\spiker', [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Güvenli olmayan kurulum temizlik yolu: $Path"
    }

    $backupPath = $null
    $iniPath = Join-Path $Path 'spiker.ini'
    if (Test-Path -LiteralPath $iniPath -PathType Leaf) {
        $backupPath = Join-Path (Get-SafeTempRoot) ('spiker-ini-backup-' + ([Guid]::NewGuid().ToString('N')) + '.ini')
        Copy-Item -LiteralPath $iniPath -Destination $backupPath -Force
    }

    try {
        foreach ($item in Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue) {
            Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction Stop
        }

        if ($null -ne $backupPath -and (Test-Path -LiteralPath $backupPath -PathType Leaf)) {
            New-Item -Path $Path -ItemType Directory -Force | Out-Null
            Copy-Item -LiteralPath $backupPath -Destination $iniPath -Force
        }
    }
    finally {
        if ($null -ne $backupPath) {
            Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-SpikerInstallPreflight {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    Write-Info "Kurulum klasörü kontrol ediliyor: $Path"
    $lockingProcessIds = @(Get-LockingProcessIds -Path $Path)
    $restartInfos = @(Get-ProcessRestartInfo -ProcessIds $lockingProcessIds)
    if ($restartInfos.Count -gt 0) {
        Stop-ProcessesForInstallCleanup -Processes $restartInfos
    }

    Write-Info 'Kurulum klasörü temizleniyor. spiker.ini korunacak.'
    Clear-SpikerInstallDirectory -Path $Path

    if ($restartInfos.Count -gt 0) {
        Restart-ProcessesForInstallCleanup -Processes $restartInfos
    }
}

function Save-UrlFile {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $uri = [System.Uri]$Url
    if ($uri.Scheme -ne 'https') {
        throw "Güvenli olmayan indirme adresi: $Url"
    }

    $directory = Split-Path -Parent $Destination
    if (-not [string]::IsNullOrWhiteSpace($directory)) {
        New-Item -Path $directory -ItemType Directory -Force | Out-Null
    }

    $temporaryDestination = $Destination + '.download'
    Remove-Item -LiteralPath $temporaryDestination -Force -ErrorAction SilentlyContinue
    try {
        Invoke-WebRequest `
            -Uri $Url `
            -OutFile $temporaryDestination `
            -UseBasicParsing `
            -Headers @{ 'User-Agent' = $userAgent } `
            -ErrorAction Stop

        Move-Item -LiteralPath $temporaryDestination -Destination $Destination -Force
    }
    catch {
        Remove-Item -LiteralPath $temporaryDestination -Force -ErrorAction SilentlyContinue
        throw "$Description indirilemedi.`nAdres: $Url`nAyrıntı: $(Get-ExceptionMessage -Exception $_.Exception)"
    }
}

function Write-Utf8BomFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Content
    )

    [System.IO.File]::WriteAllText($Path, $Content, $script:Utf8Bom)
}

function Get-Sha256 {
    param([Parameter(Mandatory = $true)][string]$Path)

    $algorithm = [System.Security.Cryptography.SHA256]::Create()
    if ($null -eq $algorithm) {
        throw 'SHA256 crypto provider kullanılamıyor.'
    }

    $stream = [System.IO.File]::OpenRead((Resolve-Path -LiteralPath $Path).Path)
    try {
        $hashBytes = $algorithm.ComputeHash($stream)
        return -join ($hashBytes | ForEach-Object { $_.ToString('X2') })
    }
    finally {
        $stream.Dispose()
        $algorithm.Dispose()
    }
}

function New-InstallerScriptFile {
    $tempRoot = Get-SafeTempRoot
    $scriptPath = Join-Path $tempRoot ('spiker-setup-downloader-' + ([Guid]::NewGuid().ToString('N')) + '.ps1')
    if ($PSCommandPath -and (Test-Path -LiteralPath $PSCommandPath -PathType Leaf)) {
        $content = [System.IO.File]::ReadAllText($PSCommandPath, [System.Text.Encoding]::UTF8)
        Write-Utf8BomFile -Path $scriptPath -Content $content
    }
    else {
        try {
            $response = Invoke-WebRequest `
                -Uri $installerScriptUrl `
                -UseBasicParsing `
                -Headers @{ 'User-Agent' = $userAgent } `
                -ErrorAction Stop
            $content = [string]$response.Content
            if ([string]::IsNullOrWhiteSpace($content)) {
                throw 'İndirilen script içeriği boş.'
            }

            Write-Utf8BomFile -Path $scriptPath -Content $content
        }
        catch {
            throw "Spiker kurulum scripti indirilemedi.`nAdres: $installerScriptUrl`nAyrıntı: $(Get-ExceptionMessage -Exception $_.Exception)"
        }
    }

    return $scriptPath
}

function Start-RequiredPowerShellHost {
    $needsWindowsPowerShell51 = -not (Test-WindowsPowerShell51)
    $needsAdministrator = -not (Test-Administrator)
    if (-not $needsWindowsPowerShell51 -and -not $needsAdministrator) {
        return $false
    }

    if ($RelaunchedForRequiredHost.IsPresent) {
        if ($needsWindowsPowerShell51) {
            throw 'Kurulum Windows PowerShell 5.1 altında başlatılamadı.'
        }

        throw 'Yönetici izni alınamadı veya PowerShell yönetici olarak başlatılamadı.'
    }

    if ($needsWindowsPowerShell51) {
        Write-Info 'Kurulum Windows PowerShell 5.1 ile yeniden başlatılacak.'
    }

    if ($needsAdministrator) {
        Write-Info 'Spiker kurulumu yönetici izni gerektiriyor.'
        Write-Info 'Birazdan Windows izin penceresi açılacak. Lütfen izin verin.'
    }

    $scriptPath = New-InstallerScriptFile
    $powerShell = Get-WindowsPowerShellPath

    $startArguments = @{
        FilePath = $powerShell
        ArgumentList = @(
            '-NoProfile',
            '-ExecutionPolicy',
            'Bypass',
            '-File',
            "`"$scriptPath`"",
            '-RelaunchedForRequiredHost'
        )
        WindowStyle = 'Normal'
        PassThru = $true
        Wait = $true
    }
    if ($needsAdministrator) {
        $startArguments.Verb = 'RunAs'
    }

    try {
        $process = Start-Process @startArguments
    }
    catch {
        $script:SuppressTopLevelUserMessage = $true
        Show-UserMessage -Message "Yönetici izni alınamadı. Spiker kurulumu başlatılamadı.`n`n$(Get-ExceptionMessage -Exception $_.Exception)" -Icon 16
        throw
    }
    finally {
        Remove-TemporaryInstallerScript -Path $scriptPath
    }

    $exitCode = if ($null -ne $process.ExitCode) { [int]$process.ExitCode } else { 0 }
    if (@(0, 3010) -notcontains $exitCode) {
        $script:SuppressTopLevelUserMessage = $true
        throw "Yükseltilmiş Spiker kurulum işlemi tamamlanamadı. Çıkış kodu: $exitCode"
    }

    return $true
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

    try {
        Invoke-RestMethod -Uri $Uri -UseBasicParsing -Headers @{
            Accept = 'application/vnd.github+json'
            'User-Agent' = $userAgent
        }
    }
    catch {
        throw "GitHub yayın bilgisi alınamadı.`nAdres: $Uri`nAyrıntı: $(Get-ExceptionMessage -Exception $_.Exception)"
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
    Save-UrlFile -Url $Asset.DownloadUrl -Destination $Destination -Description 'Spiker kurulum paketi'

    $downloaded = Get-Item -LiteralPath $Destination
    if ($downloaded.Length -le 0) {
        throw 'Kurulum dosyası boş indirildi.'
    }

    if ($Asset.Size -gt 0 -and $downloaded.Length -ne $Asset.Size) {
        throw "Kurulum dosyası boyutu beklenenden farklı. Beklenen=$($Asset.Size), indirilen=$($downloaded.Length)."
    }

    if (-not [string]::IsNullOrWhiteSpace($Asset.Digest) -and $Asset.Digest.StartsWith('sha256:', [System.StringComparison]::OrdinalIgnoreCase)) {
        $expectedHash = $Asset.Digest.Substring('sha256:'.Length).ToUpperInvariant()
        $actualHash = (Get-Sha256 -Path $Destination).ToUpperInvariant()
        if ($actualHash -ne $expectedHash) {
            throw "SHA256 doğrulaması başarısız. Beklenen=$expectedHash, indirilen=$actualHash."
        }
    }

    if (Get-Command Unblock-File -ErrorAction SilentlyContinue) {
        Unblock-File -LiteralPath $Destination -ErrorAction SilentlyContinue
    }
}

function Get-SetupExitCode {
    param(
        [Parameter(Mandatory = $true)][System.Diagnostics.Process]$Process,
        [Parameter(Mandatory = $true)][string]$ExitCodePath
    )

    $processExitCode = if ($null -ne $Process.ExitCode) { [int]$Process.ExitCode } else { 0 }
    if (-not (Test-Path -LiteralPath $ExitCodePath)) {
        return $processExitCode
    }

    $raw = (Get-Content -LiteralPath $ExitCodePath -Raw -ErrorAction Stop).Trim()
    $innerExitCode = 0
    if (-not [int]::TryParse($raw, [ref]$innerExitCode)) {
        throw "Kurulum sonucunu bildiren dosya okunamadı: $ExitCodePath"
    }

    return $innerExitCode
}

$installDirectory = $null
try {
    Initialize-Network
    if (Start-RequiredPowerShellHost) {
        return
    }

    Write-Info 'Windows PowerShell 5.1 ve yönetici izni doğrulandı.'
    Invoke-SpikerInstallPreflight -Path $targetInstallDirectory

    $installDirectory = Get-SafeInstallDirectory
    $setupPath = Join-Path $installDirectory $assetName
    $setupExitCodePath = Join-Path $installDirectory 'spiker-setup-exit-code.txt'
    $asset = Get-LatestSetupAsset

    Save-SetupAsset -Asset $asset -Destination $setupPath

    Write-Info 'Kurulum asistanı başlatılıyor. PowerShell penceresi gizlenecek.'
    $process = Start-Process -FilePath $setupPath -ArgumentList @(
        '--spiker-sfx-exit-file',
        "`"$setupExitCodePath`""
    ) -WorkingDirectory $installDirectory -WindowStyle Normal -PassThru
    Hide-ConsoleWindow
    $process.WaitForExit()

    $exitCode = Get-SetupExitCode -Process $process -ExitCodePath $setupExitCodePath
    if (@(0, 3010) -notcontains $exitCode) {
        throw "Spiker kurulumu $exitCode çıkış koduyla sonlandı."
    }
}
catch {
    if (-not $script:SuppressTopLevelUserMessage) {
        Show-UserMessage -Message "Spiker kurulumu tamamlanamadı.`n`n$(Get-ExceptionMessage -Exception $_.Exception)" -Icon 16
    }

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

    if ($PSCommandPath) {
        Remove-TemporaryInstallerScript -Path $PSCommandPath
    }
}
