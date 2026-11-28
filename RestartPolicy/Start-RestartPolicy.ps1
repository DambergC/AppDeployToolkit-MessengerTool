<#
.SYNOPSIS
Displays XML-configured uptime reminders through PSAppDeployToolkit as SYSTEM or an elevated administrator.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'RestartPolicy.xml'),
    [switch]$Once
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([Environment]::OSVersion.Platform -ne 'Win32NT' -or -not [Environment]::Is64BitProcess) {
    throw 'RestartPolicy requires 64-bit PowerShell on Windows.'
}
Import-Module (Join-Path $PSScriptRoot 'RestartPolicy.psm1') -Force -ErrorAction Stop
$identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$isAdministrator = $identity.IsSystem
if (-not $isAdministrator) {
    $principal = [System.Security.Principal.WindowsPrincipal]::new($identity)
    $isAdministrator = $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}
Assert-RestartPolicyExecutionContext -IsSystem $identity.IsSystem -IsAdministrator $isAdministrator
if (-not $identity.IsSystem) {
    Write-Verbose 'Running RestartPolicy as an elevated administrator; HKLM state is machine-wide.'
}
$policy = Import-RestartPolicy -Path $ConfigPath
$manifest = Test-ModuleManifest -Path $policy.ToolkitModulePath -ErrorAction Stop
if ($manifest.Name -ne 'PSAppDeployToolkit' -or $manifest.Version -ne [version]'4.1.8') {
    throw 'RestartPolicy requires the locally packaged PSAppDeployToolkit 4.1.8 manifest.'
}
Import-Module -Name $policy.ToolkitModulePath -Force -ErrorAction Stop
foreach ($command in @('Show-ADTInstallationPrompt', 'Show-ADTInstallationRestartPrompt', 'Get-ADTLoggedOnUser', 'Initialize-ADTModule', 'Get-ADTEnvironmentTable', 'Get-ADTConfig', 'Write-ADTLogEntry')) {
    $null = Get-Command -Name $command -Module PSAppDeployToolkit -ErrorAction Stop
}
Initialize-ADTModule -ErrorAction Stop
$toolkitConfig = Get-ADTConfig -ErrorAction Stop
if ($policy.DialogTimeoutSeconds -gt $toolkitConfig.UI.DefaultTimeout) {
    throw 'DialogTimeoutSeconds cannot exceed the toolkit UI.DefaultTimeout.'
}
$logParameters = @{
    Source = 'RestartPolicy'
    LogFileDirectory = $toolkitConfig.Toolkit.LogPath
    LogFileName = 'RestartPolicy.log'
    LogType = $toolkitConfig.Toolkit.LogStyle
}

$mutex = [System.Threading.Mutex]::new($false, 'Global\RestartPolicy')
$ownsMutex = $false
try {
    try {
        $ownsMutex = $mutex.WaitOne(0)
    } catch [System.Threading.AbandonedMutexException] {
        $ownsMutex = $true
    }
    if (-not $ownsMutex) { throw 'Another RestartPolicy instance is already running.' }
    Write-ADTLogEntry @logParameters -Message "RestartPolicy started. Toolkit restart prompt enabled: $($policy.UseToolkitRestartPrompt)."
    do {
        try {
            # LastBootUpTime also includes sleep/hibernate time and is not reset by Fast Startup.
            $boot = (Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime
            $bootUtc = [datetimeoffset]($boot.ToUniversalTime())
            $result = Invoke-RestartPolicyPass -Policy $policy -BootTimeUtc $bootUtc
            if ($result -ne 'NotDue' -and $result -ne 'NoActiveSession') {
                Write-ADTLogEntry @logParameters -Message "RestartPolicy dialog result: $result."
            }
        } catch {
            Write-ADTLogEntry @logParameters -Message "RestartPolicy pass failed: $($_.Exception.Message)" -Severity 3
            throw
        }
        if ($Once) { break }
        Start-Sleep -Seconds $policy.PollSeconds
    } while ($true)
} finally {
    if ($ownsMutex) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
