#Requires -RunAsAdministrator
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'RestartPolicy.xml'),
    [string]$TaskName = 'RestartPolicy',
    [switch]$Log
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([Environment]::OSVersion.Platform -ne 'Win32NT' -or -not [Environment]::Is64BitProcess) {
    throw 'Register the task using elevated 64-bit Windows PowerShell.'
}
Import-Module (Join-Path $PSScriptRoot 'RestartPolicy.psm1') -Force -ErrorAction Stop
$ConfigPath = (Resolve-Path -LiteralPath $ConfigPath -ErrorAction Stop).ProviderPath
$scriptPath = Join-Path $PSScriptRoot 'Start-RestartPolicy.ps1'
foreach ($path in @($ConfigPath, $scriptPath)) {
    if (-not [System.IO.Path]::IsPathRooted($path) -or $path.Contains('"') -or -not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Task paths must be existing absolute file paths without quotes: '$path'."
    }
}
$policy = Import-RestartPolicy -Path $ConfigPath
$manifest = Test-ModuleManifest -Path $policy.ToolkitModulePath -ErrorAction Stop
if ($manifest.Name -ne 'PSAppDeployToolkit' -or $manifest.Version -ne [version]'4.1.8') {
    throw 'RestartPolicy requires the locally packaged PSAppDeployToolkit 4.1.8 manifest.'
}
$powerShellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$arguments = "-NoProfile -NonInteractive -WindowStyle Hidden -STA -ExecutionPolicy Bypass -File `"$scriptPath`" -ConfigPath `"$ConfigPath`""
if ($Log) { $arguments += ' -Log' }
$action = New-ScheduledTaskAction -Execute $powerShellPath `
    -Argument $arguments
$triggers = @(New-RestartPolicyTaskTrigger -PollSeconds $policy.PollSeconds)
$principal = New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit ([timespan]::Zero) `
    -StartWhenAvailable -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
if ($PSCmdlet.ShouldProcess($TaskName, 'Register and start the SYSTEM restart reminder task')) {
    $null = Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $triggers -Principal $principal `
        -Settings $settings -Description 'Standalone XML-configured PSAppDeployToolkit restart reminders.' -Force
    Start-ScheduledTask -TaskName $TaskName
}
