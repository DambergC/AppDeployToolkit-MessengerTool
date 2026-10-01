[CmdletBinding()]
param([string]$TaskName='AppDeployToolkit Toast SQL Client',[Parameter(Mandatory)][string]$ScriptPath,[Parameter(Mandatory)][string]$ConfigPath)
$action=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -STA -ExecutionPolicy Bypass -File `"$ScriptPath`" -ConfigPath `"$ConfigPath`" -PollSeconds 30"
$trigger=New-ScheduledTaskTrigger -AtLogOn
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Description 'Displays SQL-backed AppDeployToolkit notifications in the interactive user session.' -Force
