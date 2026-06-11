param(
    [Parameter(Mandatory = $false)]
    [switch]$RelaunchedForRequiredHost,

    [Parameter(Mandatory = $false)]
    [string]$DownloaderUrl = '',

    [Parameter(Mandatory = $false)]
    [string[]]$SetupArguments = @(),

    [Parameter(Mandatory = $false)]
    [string]$SetupArgumentsBase64 = ''
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

$repository = 'hasan-ozdemir/spiker-setup'
$assetName = 'spiker-setup.exe'
$latestSetupAssetUrl = "https://github.com/$repository/releases/download/latest/$assetName"
$installerScriptUrl = if ([string]::IsNullOrWhiteSpace($DownloaderUrl)) {
    'https://raw.githubusercontent.com/hasan-ozdemir/spiker-setup/main/spiker-setup-downloader.ps1'
}
else {
    $DownloaderUrl
}
$userAgent = 'spiker-setup'
$originalProgressPreference = $ProgressPreference
$ProgressPreference = 'SilentlyContinue'
$script:SuppressTopLevelUserMessage = $false
$script:CurrentInstallerStep = $null
$script:InstallDirectory = ''
$script:SetupLogPath = ''
$script:DownloaderSucceeded = $false

function Write-Info {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host "[Spiker] $Message"
}

function ConvertTo-SetupArgumentsBase64 {
    param([Parameter(Mandatory = $false)][string[]]$Arguments = @())

    $payload = [pscustomobject]@{ SetupArguments = @($Arguments) }
    $json = $payload | ConvertTo-Json -Compress
    return [Convert]::ToBase64String($script:Utf8NoBom.GetBytes($json))
}

function ConvertFrom-SetupArgumentsBase64 {
    param([Parameter(Mandatory = $false)][AllowEmptyString()][string]$Value = '')

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return @()
    }

    $json = $script:Utf8NoBom.GetString([Convert]::FromBase64String($Value))
    $payload = $json | ConvertFrom-Json
    if ($null -eq $payload -or $null -eq $payload.SetupArguments) {
        return @()
    }

    return @($payload.SetupArguments | ForEach-Object { [string]$_ })
}

$rawSetupArguments = @($SetupArguments)

function Show-UserMessage {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [Parameter(Mandatory = $false)][string]$Title = 'Spiker Kurulum',
        [Parameter(Mandatory = $false)][int]$Icon = 64
    )

    if ([string]::Equals($env:SPIKER_INSTALL_NO_MESSAGE, '1', [System.StringComparison]::OrdinalIgnoreCase)) {
        Write-Host $Message
        return
    }

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

function Set-InstallerStep {
    param(
        [Parameter(Mandatory = $true)][string]$Step,
        [Parameter(Mandatory = $true)][string]$Action,
        [Parameter(Mandatory = $true)][string]$Expected,
        [Parameter(Mandatory = $false)][string]$Detail = ''
    )

    $script:CurrentInstallerStep = [pscustomobject]@{
        Step = $Step
        Action = $Action
        Expected = $Expected
        Detail = $Detail
    }
}

function Get-InstallerLogSummary {
    $candidates = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($script:SetupLogPath)) {
        $candidates.Add($script:SetupLogPath) | Out-Null
    }

    if (-not [string]::IsNullOrWhiteSpace($script:InstallDirectory)) {
        $candidates.Add((Join-Path $script:InstallDirectory 'spiker-setup-silent.log')) | Out-Null
        $candidates.Add((Join-Path $script:InstallDirectory 'spiker-downloader-error.txt')) | Out-Null
    }

    foreach ($candidate in @($candidates | Select-Object -Unique)) {
        if ([string]::IsNullOrWhiteSpace($candidate) -or -not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            continue
        }

        try {
            $lines = @(Get-Content -LiteralPath $candidate -Tail 20 -ErrorAction Stop)
            if ($lines.Count -eq 0) {
                continue
            }

            return "Log özeti: $candidate`n" + ($lines -join "`n")
        }
        catch {
        }
    }

    return ''
}

function Format-InstallerFailure {
    param([Parameter(Mandatory = $true)][System.Exception]$Exception)

    $parts = New-Object System.Collections.Generic.List[string]
    $parts.Add('Spiker kurulumu tamamlanamadı.') | Out-Null
    if ($null -ne $script:CurrentInstallerStep) {
        $parts.Add('') | Out-Null
        $parts.Add("Adım: $($script:CurrentInstallerStep.Step)") | Out-Null
        $parts.Add("İşlem: $($script:CurrentInstallerStep.Action)") | Out-Null
        $parts.Add("Beklenen: $($script:CurrentInstallerStep.Expected)") | Out-Null
        if (-not [string]::IsNullOrWhiteSpace([string]$script:CurrentInstallerStep.Detail)) {
            $parts.Add("Ayrıntı: $($script:CurrentInstallerStep.Detail)") | Out-Null
        }
    }

    $parts.Add('') | Out-Null
    $parts.Add('Karşılaşılan durum:') | Out-Null
    $parts.Add((Get-ExceptionMessage -Exception $Exception)) | Out-Null

    if (-not [string]::IsNullOrWhiteSpace($script:InstallDirectory)) {
        $parts.Add('') | Out-Null
        $parts.Add("Geçici kurulum klasörü: $script:InstallDirectory") | Out-Null
    }

    $logSummary = Get-InstallerLogSummary
    if (-not [string]::IsNullOrWhiteSpace($logSummary)) {
        $parts.Add('') | Out-Null
        $parts.Add($logSummary) | Out-Null
    }

    return ($parts -join "`n")
}

function Save-InstallerFailure {
    param([Parameter(Mandatory = $true)][string]$Message)

    if ([string]::IsNullOrWhiteSpace($script:InstallDirectory)) {
        return
    }

    try {
        New-Item -Path $script:InstallDirectory -ItemType Directory -Force | Out-Null
        [System.IO.File]::WriteAllText(
            (Join-Path $script:InstallDirectory 'spiker-downloader-error.txt'),
            $Message,
            $script:Utf8Bom)
    }
    catch {
    }
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
    $localAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    $tempRoot = if (-not [string]::IsNullOrWhiteSpace($localAppData)) {
        Join-Path $localAppData 'Temp'
    }
    else {
        [System.IO.Path]::GetTempPath()
    }

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

    Refresh-SafeInstallDirectory -Path $installDirectory
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

function Clear-SafeInstallDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $false)][switch]$PreserveCurrentScript
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        return
    }

    if (-not (Test-SafeInstallDirectory -Path $Path)) {
        throw "Güvenli olmayan temp içerik temizlik yolu: $Path"
    }

    $currentScriptPath = ''
    if ($PreserveCurrentScript.IsPresent -and -not [string]::IsNullOrWhiteSpace($PSCommandPath)) {
        try {
            $currentScriptPath = [System.IO.Path]::GetFullPath($PSCommandPath)
        }
        catch {
            $currentScriptPath = ''
        }
    }

    foreach ($item in Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue) {
        if (-not [string]::IsNullOrWhiteSpace($currentScriptPath) -and
            [string]::Equals([System.IO.Path]::GetFullPath($item.FullName), $currentScriptPath, [System.StringComparison]::OrdinalIgnoreCase)) {
            continue
        }

        Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction Stop
    }
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
    return ($fileName.Equals('spiker-setup-downloader.ps1', [System.StringComparison]::OrdinalIgnoreCase) -or
        $fileName.StartsWith('spiker-install-', [System.StringComparison]::OrdinalIgnoreCase) -or
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

function Get-DirectoryFileResources {
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

    $resources = @(Get-DirectoryFileResources -Path $Path)
    if ($resources.Count -eq 0) {
        return @()
    }

    Add-RestartManagerType
    return @([SpikerInstaller.RestartManager]::GetLockingProcessIds($resources))
}

function Get-ProcessStopInfo {
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
            throw "Process durdurma bilgisi alınamadı. PID=$processId"
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

function Stop-ProcessesForSetupTempRefresh {
    param([Parameter(Mandatory = $true)][object[]]$Processes)

    foreach ($processInfo in $Processes) {
        Write-Info ("Geçici kurulum klasörünü kullanan process durduruluyor: {0} (PID {1})" -f $processInfo.Name, $processInfo.ProcessId)
        $processIdsToStop = @(Get-DescendantProcessIds -ProcessId $processInfo.ProcessId) + @([int]$processInfo.ProcessId)
        foreach ($processIdToStop in @($processIdsToStop | Select-Object -Unique)) {
            $process = Get-Process -Id $processIdToStop -ErrorAction SilentlyContinue
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

            Stop-Process -Id $processIdToStop -Force -ErrorAction SilentlyContinue
            try {
                $process.WaitForExit(10000) | Out-Null
            }
            catch {
            }
        }

        Start-Sleep -Milliseconds 500
    }
}

function Get-DescendantProcessIds {
    param([Parameter(Mandatory = $true)][int]$ProcessId)

    $result = New-Object System.Collections.Generic.List[int]
    $children = @(Get-CimInstance Win32_Process -Filter "ParentProcessId = $ProcessId" -ErrorAction SilentlyContinue)
    foreach ($child in $children) {
        $childId = [int]$child.ProcessId
        foreach ($descendantId in @(Get-DescendantProcessIds -ProcessId $childId)) {
            $result.Add([int]$descendantId) | Out-Null
        }

        $result.Add($childId) | Out-Null
    }

    return @($result)
}

function Get-SetupTempProcessIds {
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    $ids = New-Object System.Collections.Generic.HashSet[int]
    $processes = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
            $name = [string]$_.Name
            $executablePath = [string]$_.ExecutablePath
            $commandLine = [string]$_.CommandLine
            $isSetupProcess = $name.StartsWith('spiker-setup', [System.StringComparison]::OrdinalIgnoreCase)
            $runsFromTemp = -not [string]::IsNullOrWhiteSpace($executablePath) -and
                [System.IO.Path]::GetFullPath($executablePath).StartsWith($fullPath, [System.StringComparison]::OrdinalIgnoreCase)
            $mentionsTemp = -not [string]::IsNullOrWhiteSpace($commandLine) -and
                $commandLine.IndexOf($fullPath, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
            $isSetupProcess -and ($runsFromTemp -or $mentionsTemp)
        }

    foreach ($processInfo in @($processes)) {
        if ($null -ne $processInfo.ProcessId) {
            $ids.Add([int]$processInfo.ProcessId) | Out-Null
        }
    }

    return @($ids)
}

function Stop-SetupTempProcesses {
    param([Parameter(Mandatory = $true)][string]$Path)

    $processIds = New-Object System.Collections.Generic.HashSet[int]
    foreach ($processId in @(Get-LockingProcessIds -Path $Path)) {
        $processIds.Add([int]$processId) | Out-Null
    }

    foreach ($processId in @(Get-SetupTempProcessIds -Path $Path)) {
        $processIds.Add([int]$processId) | Out-Null
    }

    if ($processIds.Count -eq 0) {
        return
    }

    $processInfos = @(Get-ProcessStopInfo -ProcessIds @($processIds))
    if ($processInfos.Count -gt 0) {
        Stop-ProcessesForSetupTempRefresh -Processes $processInfos
    }
}

function Refresh-SafeInstallDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-SafeInstallDirectory -Path $Path)) {
        throw "Güvenli olmayan temp yenileme yolu: $Path"
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    Write-Info "Geçici kurulum klasörü yenileniyor: $Path"
    Stop-SetupTempProcesses -Path $Path
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        try {
            Clear-SafeInstallDirectory -Path $Path -PreserveCurrentScript
            return
        }
        catch {
            if ($attempt -eq 5) {
                throw
            }

            Stop-SetupTempProcesses -Path $Path
            Start-Sleep -Milliseconds (500 * $attempt)
        }
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
    $installDirectory = Get-SafeInstallDirectory
    $script:InstallDirectory = $installDirectory
    $script:SetupLogPath = Join-Path $installDirectory 'spiker-setup-silent.log'
    $scriptPath = Join-Path $installDirectory 'spiker-setup-downloader.ps1'
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
    if ($SetupArguments.Count -gt 0) {
        $startArguments.ArgumentList += @(
            '-SetupArgumentsBase64',
            (ConvertTo-SetupArgumentsBase64 -Arguments $SetupArguments)
        )
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
    Write-Info 'En son Spiker kurulum paketi hazırlanıyor...'
    return [pscustomobject]@{
        ReleaseName = 'Spiker Setup latest'
        ReleaseTag = 'latest'
        DownloadUrl = $latestSetupAssetUrl
        Size = [int64]0
        Digest = ''
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
    Set-InstallerStep `
        -Step 'Kurulum argümanlarını okuma' `
        -Action 'Wrapper veya relaunch sürecinden gelen kurulum argümanları çözümleniyor.' `
        -Expected 'Base64 argüman paketi geçerli JSON içermeli veya boş olmalı.'
    $SetupArguments = @(ConvertFrom-SetupArgumentsBase64 -Value $SetupArgumentsBase64) + @($rawSetupArguments)

    Set-InstallerStep `
        -Step 'Ağ hazırlığı' `
        -Action 'GitHub API ve indirme bağlantıları için TLS/proxy ayarları hazırlanıyor.' `
        -Expected 'GitHub release bilgisi ve kurulum paketi HTTPS üzerinden erişilebilir olmalı.'
    Initialize-Network

    Set-InstallerStep `
        -Step 'PowerShell ve yönetici izni doğrulaması' `
        -Action 'Windows PowerShell 5.1 ve yönetici hakları kontrol ediliyor; gerekirse script yeniden başlatılıyor.' `
        -Expected 'Kurulum Windows PowerShell 5.1 altında ve yönetici yetkisiyle devam etmeli.'
    if (Start-RequiredPowerShellHost) {
        $script:DownloaderSucceeded = $true
        return
    }

    Write-Info 'Windows PowerShell 5.1 ve yönetici izni doğrulandı.'

    Set-InstallerStep `
        -Step 'Geçici kurulum klasörü yenileme' `
        -Action 'Deterministic temp klasörü hazırlanıyor; klasörü kilitleyen eski processler kapatılıyor.' `
        -Expected '%LOCALAPPDATA%\Temp\spiker-setup temizlenebilmeli ve yeniden yazılabilir olmalı.'
    $installDirectory = Get-SafeInstallDirectory
    $script:InstallDirectory = $installDirectory
    $setupPath = Join-Path $installDirectory $assetName
    $setupExitCodePath = Join-Path $installDirectory 'spiker-setup-exit-code.txt'
    $script:SetupLogPath = Join-Path $installDirectory 'spiker-setup-silent.log'

    Set-InstallerStep `
        -Step 'GitHub latest kurulum adresini hazırlama' `
        -Action "hasan-ozdemir/spiker-setup latest kurulum paketi adresi hazırlanıyor." `
        -Expected "Sabit latest adresinden indirilebilir $assetName asset'i bulunmalı."
    $asset = Get-LatestSetupAsset

    Set-InstallerStep `
        -Step 'Kurulum paketini indirme' `
        -Action "$assetName indiriliyor ve boyut/hash doğrulaması yapılıyor." `
        -Expected 'Dosya eksiksiz inmeli; GitHub digest bilgisi varsa SHA256 doğrulaması geçmeli.' `
        -Detail "Hedef dosya: $setupPath"
    Save-SetupAsset -Asset $asset -Destination $setupPath

    Set-InstallerStep `
        -Step 'Kurulum asistanını başlatma' `
        -Action "$assetName process olarak başlatılıyor." `
        -Expected 'Spiker kurulum asistanı açılmalı ve process başarıyla başlamalı.' `
        -Detail "Çalışma klasörü: $installDirectory"
    Write-Info 'Kurulum asistanı başlatılıyor. PowerShell penceresi gizlenecek.'
    $setupProcessArguments = @($SetupArguments) + @(
        '--spiker-sfx-exit-file',
        "`"$setupExitCodePath`""
    )
    $process = Start-Process -FilePath $setupPath -ArgumentList $setupProcessArguments -WorkingDirectory $installDirectory -WindowStyle Normal -PassThru
    Hide-ConsoleWindow

    Set-InstallerStep `
        -Step 'Kurulum asistanının sonucunu bekleme' `
        -Action 'Spiker kurulum asistanı processinin kapanması bekleniyor.' `
        -Expected 'Kurulum asistanı 0 veya 3010 çıkış koduyla sonuçlanmalı.' `
        -Detail "ProcessId: $($process.Id)"
    $process.WaitForExit()

    Set-InstallerStep `
        -Step 'Kurulum sonucunu okuma' `
        -Action 'Kurulum asistanının process çıkış kodu ve SFX exit-code dosyası okunuyor.' `
        -Expected 'Çıkış kodu 0 veya 3010 olmalı; diğer kodlar gerçek kurulum hatası kabul edilir.' `
        -Detail "Exit-code dosyası: $setupExitCodePath"
    $exitCode = Get-SetupExitCode -Process $process -ExitCodePath $setupExitCodePath
    if (@(0, 3010) -notcontains $exitCode) {
        throw "Spiker kurulumu $exitCode çıkış koduyla sonlandı."
    }

    $script:DownloaderSucceeded = $true
}
catch {
    $failureMessage = Format-InstallerFailure -Exception $_.Exception
    Save-InstallerFailure -Message $failureMessage

    if (-not $script:SuppressTopLevelUserMessage) {
        Show-UserMessage -Message $failureMessage -Icon 16
    }

    throw $failureMessage
}
finally {
    $ProgressPreference = $originalProgressPreference
    if ($null -ne $installDirectory) {
        if ($script:DownloaderSucceeded) {
            try {
                Remove-SafeInstallDirectory -Path $installDirectory
            }
            catch {
                try {
                    Stop-SetupTempProcesses -Path $installDirectory
                    Clear-SafeInstallDirectory -Path $installDirectory
                }
                catch {
                    $remainingItems = @(Get-ChildItem -LiteralPath $installDirectory -Force -ErrorAction SilentlyContinue)
                    if ($remainingItems.Count -gt 0) {
                        Show-UserMessage -Message "Geçici Spiker kurulum dosyaları temizlenemedi:`n$installDirectory`n`n$($_.Exception.Message)" -Icon 48
                    }
                }
            }
        }
        else {
            Write-Info "Kurulum tanılama dosyaları inceleme için bırakıldı: $installDirectory"
        }
    }

    if ($script:DownloaderSucceeded -and $PSCommandPath) {
        Remove-TemporaryInstallerScript -Path $PSCommandPath
    }
}
