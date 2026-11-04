[CmdletBinding()]
param(
    [string]$TaskName = 'AppDeployToolkit Toast SQL Client',
    [Parameter(Mandatory)][string]$ScriptPath,
    [Parameter(Mandatory)][string]$ConfigPath,
    [switch]$RunAsSystem
)
$ErrorActionPreference = 'Stop'
foreach ($path in @($ScriptPath, $ConfigPath)) {
    if (-not [System.IO.Path]::IsPathRooted($path) -or $path.Contains('"') -or -not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Task paths must be existing, absolute file paths without quotes: '$path'."
    }
}
$powerShellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$action = New-ScheduledTaskAction -Execute $powerShellPath -Argument "-NoProfile -STA -ExecutionPolicy Bypass -File `"$ScriptPath`" -ConfigPath `"$ConfigPath`" -PollSeconds 30"
if ($RunAsSystem) {
    if (-not $PSBoundParameters.ContainsKey('TaskName')) { $TaskName += ' (SYSTEM)' }
    $trigger = @(New-ScheduledTaskTrigger -AtStartup; New-ScheduledTaskTrigger -AtLogOn)
    $principal = New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit ([timespan]::Zero) `
        -StartWhenAvailable -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
} else {
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    if ($identity.IsSystem) { throw 'Specify -RunAsSystem when registering from SYSTEM.' }
    $user = $identity.Name
    if (-not $PSBoundParameters.ContainsKey('TaskName')) { $TaskName += " ($($identity.User.Value))" }
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit ([timespan]::Zero)
}
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description 'Displays SQL-backed AppDeployToolkit notifications in an active user session.' -Force
