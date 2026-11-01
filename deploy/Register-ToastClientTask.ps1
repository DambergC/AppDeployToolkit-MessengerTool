[CmdletBinding()]
param([string]$TaskName='AppDeployToolkit Toast SQL Client',[Parameter(Mandatory)][string]$ScriptPath,[Parameter(Mandatory)][string]$ConfigPath)
$action=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -STA -ExecutionPolicy Bypass -File `"$ScriptPath`" -ConfigPath `"$ConfigPath`" -PollSeconds 30"
$identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$user = $identity.Name
if (-not $PSBoundParameters.ContainsKey('TaskName')) { $TaskName += " ($($identity.User.Value))" }
$trigger=New-ScheduledTaskTrigger -AtLogOn -User $user
$principal=New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
$settings=New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit ([timespan]::Zero)
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description 'Displays SQL-backed AppDeployToolkit notifications in the interactive user session.' -Force
