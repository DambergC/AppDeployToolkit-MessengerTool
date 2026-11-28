Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Import-RestartPolicy {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $resolvedPath = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath
    $settings = [System.Xml.XmlReaderSettings]::new()
    $settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver = $null
    $settings.ValidationType = [System.Xml.ValidationType]::Schema
    $null = $settings.Schemas.Add($null, (Join-Path $PSScriptRoot 'RestartPolicy.xsd'))
    $reader = [System.Xml.XmlReader]::Create($resolvedPath, $settings)
    try {
        $document = [System.Xml.XmlDocument]::new()
        $document.XmlResolver = $null
        $document.Load($reader)
    } finally {
        $reader.Dispose()
    }

    $root = $document.DocumentElement
    if ($root.Name -cne 'RestartPolicy' -or $root.NamespaceURI) {
        throw 'Expected a RestartPolicy root element without an XML namespace.'
    }
    $hours = [int]$root.RestartAfterHours
    $pollSeconds = [int]$root.PollSeconds
    if ($pollSeconds % 60 -ne 0) {
        throw 'PollSeconds must be a whole number of minutes for Windows Task Scheduler.'
    }
    $reminders = @(
        foreach ($node in $root.Reminders.Reminder) {
            $minutes = [int]$node.MinutesBefore
            if ($minutes -ge ($hours * 60) -or $minutes -gt 1440) {
                throw 'Each reminder must be within the last 24 hours and before the restart deadline.'
            }
            [pscustomobject]@{ MinutesBefore = $minutes; Message = $node.InnerText.Trim() }
        }
    )
    $button = $root.AcknowledgeButtonText.Trim()
    if ($button -eq 'Timeout' -or $button.Length -gt 200) {
        throw 'AcknowledgeButtonText must be at most 200 characters and cannot be Timeout.'
    }
    $toolkitPath = $root.ToolkitModulePath.Trim()
    if (-not [System.IO.Path]::IsPathRooted($toolkitPath)) {
        $toolkitPath = Join-Path (Split-Path -Parent $resolvedPath) $toolkitPath
    }
    $restartPromptNode = $root.SelectSingleNode('UseToolkitRestartPrompt')
    [pscustomobject]@{
        ToolkitModulePath = $toolkitPath
        RestartAfterHours = $hours
        PollSeconds = $pollSeconds
        DialogTimeoutSeconds = [int]$root.DialogTimeoutSeconds
        UseToolkitRestartPrompt = ($null -ne $restartPromptNode -and [System.Xml.XmlConvert]::ToBoolean($restartPromptNode.InnerText.Trim()))
        Title = $root.Title.Trim()
        AcknowledgeButtonText = $button
        OverdueMessage = $root.OverdueMessage.Trim()
        Reminders = $reminders
    }
}

function Assert-RestartPolicyExecutionContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][bool]$IsSystem,
        [Parameter(Mandatory)][bool]$IsAdministrator
    )

    if (-not $IsSystem -and -not $IsAdministrator) {
        throw 'Run RestartPolicy as SYSTEM or from an elevated administrator PowerShell session.'
    }
}

function New-RestartPolicyTaskTrigger {
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$PollSeconds)

    $dailyTrigger = New-ScheduledTaskTrigger -Daily -At '00:00'
    $repeatingTrigger = New-ScheduledTaskTrigger -Once -At '00:00' `
        -RepetitionInterval (New-TimeSpan -Seconds $PollSeconds) -RepetitionDuration (New-TimeSpan -Days 1)
    $dailyTrigger.Repetition = $repeatingTrigger.Repetition
    New-ScheduledTaskTrigger -AtStartup
    New-ScheduledTaskTrigger -AtLogOn
    $dailyTrigger
}

function Get-RestartPolicyStage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Policy,
        [Parameter(Mandatory)][datetimeoffset]$BootTimeUtc,
        [datetimeoffset]$NowUtc = [datetimeoffset]::UtcNow,
        [ValidateRange(0, 2147483647)][int]$LastStageMinutes = [int]::MaxValue
    )

    if ($NowUtc -lt $BootTimeUtc) {
        throw 'The current time is earlier than the boot time. Check the system clock.'
    }
    $deadline = $BootTimeUtc.AddHours($Policy.RestartAfterHours)
    $remaining = ($deadline - $NowUtc).TotalMinutes
    $stage = if ($remaining -le 0) {
        [pscustomobject]@{ MinutesBefore = 0; Message = $Policy.OverdueMessage }
    } else {
        $Policy.Reminders | Where-Object { $remaining -le $_.MinutesBefore } |
            Sort-Object MinutesBefore | Select-Object -First 1
    }
    # A decreasing watermark prevents stale warnings after sleep or clock changes.
    if ($null -ne $stage -and $stage.MinutesBefore -lt $LastStageMinutes) {
        [pscustomobject]@{
            MinutesBefore = $stage.MinutesBefore
            Message = $stage.Message.Replace('{DeadlineLocal}', $deadline.ToLocalTime().ToString('yyyy-MM-dd HH:mm'))
            DeadlineUtc = $deadline
        }
    }
}

function Show-RestartPolicyReminder {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Policy,
        [Parameter(Mandatory)]$Stage
    )

    if (@(Get-ADTLoggedOnUser -ErrorAction Stop | Where-Object IsActiveUserSession).Count -eq 0) {
        return 'NoActiveSession'
    }
    # ADT caches the target session; refresh it after logon and fast user switching.
    Initialize-ADTModule -ErrorAction Stop
    $target = (Get-ADTEnvironmentTable -ErrorAction Stop).RunAsActiveUser
    if ($null -eq $target -or @(Get-ADTLoggedOnUser -ErrorAction Stop | Where-Object {
        $_.IsActiveUserSession -and $_.SessionId -eq $target.SessionId -and $_.SID -eq $target.SID
    }).Count -eq 0) {
        return 'NoActiveSession'
    }

    $lastReminder = ($Policy.Reminders | Measure-Object -Property MinutesBefore -Minimum).Minimum
    if ($Policy.UseToolkitRestartPrompt -and $Stage.MinutesBefore -le $lastReminder) {
        Show-ADTInstallationRestartPrompt -Title $Policy.Title.Replace('[', ('[' + [char]0x2060)) `
            -Subtitle 'RestartPolicy' -CountdownSeconds ($lastReminder * 60) `
            -CountdownNoHideSeconds 30 -ErrorAction Stop
        return 'RestartPromptReturned'
    }

    $parameters = @{
        Title = $Policy.Title.Replace('[', ('[' + [char]0x2060))
        Subtitle = 'RestartPolicy'
        Message = $Stage.Message.Replace('[', ('[' + [char]0x2060))
        ButtonRightText = $Policy.AcknowledgeButtonText
        Timeout = $Policy.DialogTimeoutSeconds
        NoExitOnTimeout = $true
        ErrorAction = 'Stop'
    }
    $result = Show-ADTInstallationPrompt @parameters
    if ($result -ceq $Policy.AcknowledgeButtonText) {
        return 'Acknowledged'
    }
    if ($result -eq 'Timeout') {
        return 'Timeout'
    }
    throw "Unexpected toolkit dialog result: '$result'. The reminder was not acknowledged."
}

function Write-RestartPolicyDiagnosticLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Message
    )

    $timestamp = [datetimeoffset]::Now.ToString('yyyy-MM-dd HH:mm:ss zzz')
    Add-Content -LiteralPath $Path -Value "[$timestamp] $Message" -Encoding UTF8 -ErrorAction Stop
}

function Invoke-RestartPolicyPass {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Policy,
        [Parameter(Mandatory)][datetimeoffset]$BootTimeUtc,
        [datetimeoffset]$NowUtc = [datetimeoffset]::UtcNow,
        [string]$LogPath
    )

    $statePath = 'HKLM:\SOFTWARE\RestartPolicy'
    $bootId = $BootTimeUtc.ToUniversalTime().ToString('o')
    $lastStage = [int]::MaxValue
    if (Test-Path -LiteralPath $statePath) {
        $state = Get-ItemProperty -LiteralPath $statePath -ErrorAction Stop
        if ($null -ne $state.PSObject.Properties['BootTimeUtc'] -and $state.BootTimeUtc -eq $bootId) {
            if ($null -ne $state.PSObject.Properties['LastStageMinutes']) {
                $lastStage = [int]$state.LastStageMinutes
            }
        }
    }
    $stage = Get-RestartPolicyStage -Policy $Policy -BootTimeUtc $BootTimeUtc -NowUtc $NowUtc -LastStageMinutes $lastStage
    if ($LogPath) {
        $deadline = $BootTimeUtc.AddHours($Policy.RestartAfterHours)
        $deadlineLocal = $deadline.ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss zzz')
        $bootLocal = $BootTimeUtc.ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss zzz')
        if ($null -eq $stage) {
            $nextMinutes = @($Policy.Reminders.MinutesBefore | Where-Object { $_ -lt $lastStage } | Sort-Object -Descending) + @(0)
            if ($lastStage -eq 0) {
                $status = 'No further reminders until the next Windows restart; the final reminder was acknowledged.'
            } else {
                $nextLocal = $deadline.AddMinutes(-$nextMinutes[0]).ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss zzz')
                $status = "No reminder due. Next eligible reminder: $nextLocal."
            }
        } else {
            $status = "Reminder due: $($stage.MinutesBefore) minutes before the restart deadline."
        }
        Write-RestartPolicyDiagnosticLog -Path $LogPath -Message "Boot: $bootLocal. Restart deadline: $deadlineLocal. $status"
    }
    if ($null -eq $stage) { return 'NotDue' }

    $result = Show-RestartPolicyReminder -Policy $Policy -Stage $stage
    if ($result -eq 'Acknowledged') {
        $null = New-Item -Path $statePath -Force -ErrorAction Stop
        # Write the watermark first: a partial update must never acknowledge a new boot.
        $null = New-ItemProperty -LiteralPath $statePath -Name LastStageMinutes -Value $stage.MinutesBefore -PropertyType DWord -Force -ErrorAction Stop
        $null = New-ItemProperty -LiteralPath $statePath -Name BootTimeUtc -Value $bootId -PropertyType String -Force -ErrorAction Stop
    }
    if ($LogPath) {
        $message = "Reminder result: $result."
        if ($result -eq 'NoActiveSession' -or $result -eq 'Timeout' -or $result -eq 'RestartPromptReturned') {
            $message += ' The next scheduled run can try again.'
        }
        Write-RestartPolicyDiagnosticLog -Path $LogPath -Message $message
    }
    return $result
}

Export-ModuleMember -Function Assert-RestartPolicyExecutionContext, Import-RestartPolicy, New-RestartPolicyTaskTrigger, Get-RestartPolicyStage, Show-RestartPolicyReminder, Invoke-RestartPolicyPass, Write-RestartPolicyDiagnosticLog
