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
        [Parameter(Mandatory)]$Stage,
        [switch]$Demo
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
    $restartPrompt = $Policy.UseToolkitRestartPrompt -and $Stage.MinutesBefore -le $lastReminder
    if ($restartPrompt -and -not $Demo) {
        Show-ADTInstallationRestartPrompt -Title $Policy.Title.Replace('[', ('[' + [char]0x2060)) `
            -Subtitle 'RestartPolicy' -CountdownSeconds ($lastReminder * 60) `
            -CountdownNoHideSeconds 30 -ErrorAction Stop
        return 'RestartPromptReturned'
    }
    if ($restartPrompt -and $Demo) {
        return Show-RestartPolicyRestartPreview -Policy $Policy
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
    if ($Demo) {
        $parameters.Subtitle = 'RestartPolicy - DEMO'
        $parameters.Message = "DEMO: Ingen omstart sker och ingen kvittering sparas.`n`n$($parameters.Message)"
    }
    $result = Show-ADTInstallationPrompt @parameters
    if ($Demo -and $result -ceq $parameters.ButtonRightText) {
        return 'DemoClosed'
    }
    if ($result -ceq $Policy.AcknowledgeButtonText) {
        return 'Acknowledged'
    }
    if ($result -eq 'Timeout') {
        return 'Timeout'
    }
    throw "Unexpected toolkit dialog result: '$result'. The reminder was not acknowledged."
}

function New-RestartPolicyRestartPreviewImage {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Policy)

    if ([Environment]::OSVersion.Platform -ne 'Win32NT' -or [System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
        throw 'Restart preview requires Windows PowerShell in STA mode. Start powershell.exe -STA or pwsh.exe -STA.'
    }
    $toolkitModule = (Get-Command Get-ADTStringTable -Module PSAppDeployToolkit -ErrorAction Stop).Module
    if ($toolkitModule.Version -ne [version]'4.1.8') {
        throw 'Restart preview requires the locally packaged PSAppDeployToolkit 4.1.8.'
    }
    $language = & $toolkitModule { $Script:ADT.Language }
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing -ErrorAction Stop
    if ($null -eq [System.Windows.Application]::Current) {
        $application = [System.Windows.Application]::new()
        $application.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown
    }
    $config = Get-ADTConfig -ErrorAction Stop
    $strings = Get-ADTStringTable -ErrorAction Stop
    $countdown = [timespan]::FromMinutes(($Policy.Reminders | Measure-Object -Property MinutesBefore -Minimum).Minimum)
    $options = @{
        AppTitle = $Policy.Title.Replace('[', ('[' + [char]0x2060))
        Subtitle = 'RestartPolicy'
        AppIconImage = $config.Assets.Logo
        AppIconDarkImage = $config.Assets.LogoDark
        AppBannerImage = $config.Assets.Banner
        DialogTopMost = $false
        Language = $language
        Strings = $strings.RestartPrompt
        CountdownDuration = $countdown
        CountdownNoMinimizeDuration = [timespan]::FromSeconds(30)
    }
    if ($null -ne $config.UI.FluentAccentColor) {
        $options.FluentAccentColor = $config.UI.FluentAccentColor
    }
    $options = [PSADT.UserInterface.DialogOptions.RestartDialogOptions]::new([PSADT.Module.DeploymentType]::Install, $options)
    $style = [string]$config.UI.DialogStyle
    if ($style -notin @('Fluent', 'Classic')) {
        throw "Unsupported toolkit dialog style for restart preview: '$style'."
    }
    $flags = [System.Reflection.BindingFlags]'Instance, NonPublic'
    $type = $options.GetType().Assembly.GetType("PSADT.UserInterface.Dialogs.$style.RestartDialog", $true)
    $constructor = $type.GetConstructor($flags, $null, @($options.GetType()), $null)
    if ($null -eq $constructor) {
        throw 'The packaged toolkit restart dialog does not match the expected 4.1.8 constructor.'
    }
    $dialog = $constructor.Invoke(@($options))
    try {
        # Render an unshown dialog to pixels only. Dispose its dormant timer before any layout.
        # The original controls are never attached to the preview or given a message loop.
        $timerType = if ($style -eq 'Fluent') { $type.BaseType } else { $type }
        $timerName = if ($style -eq 'Fluent') { '_countdownTimer' } else { 'countdownTimer' }
        $timerField = $timerType.GetField($timerName, $flags)
        if ($null -eq $timerField -or $null -eq ($timer = $timerField.GetValue($dialog))) {
            throw 'The packaged toolkit restart timer does not match the expected 4.1.8 preview contract.'
        }
        $timer.Dispose()
        $countdownText = $countdown.ToString('hh\:mm\:ss')
        if ($style -eq 'Fluent') {
            $null = $type.BaseType.GetMethod('UpdateCountdownDisplay', $flags).Invoke($dialog, @())
            $null = $type.BaseType.GetMethod('UpdateButtonLayout', $flags).Invoke($dialog, @())
            $null = $type.BaseType.GetMethod('UpdateRowDefinition', $flags).Invoke($dialog, @())
            $visual = $dialog.Content
            $width = if ([double]::IsNaN($dialog.Width)) { $dialog.MinWidth } else { $dialog.Width }
            if ($width -le 0 -or [double]::IsInfinity($width)) {
                throw 'The packaged Fluent restart dialog has no finite preview width.'
            }
            $visual.Measure([System.Windows.Size]::new($width, [double]::PositiveInfinity))
            $bounds = [System.Windows.Rect]::new(0, 0, $width, $visual.DesiredSize.Height)
            $visual.Arrange($bounds)
            $drawing = [System.Windows.Media.DrawingVisual]::new()
            $context = $drawing.RenderOpen()
            try {
                $context.DrawRectangle($dialog.Background, $null, $bounds)
                $context.DrawRectangle([System.Windows.Media.VisualBrush]::new($visual), $null, $bounds)
            } finally {
                $context.Close()
            }
            $image = [System.Windows.Media.Imaging.RenderTargetBitmap]::new(
                [int][math]::Ceiling($bounds.Width), [int][math]::Ceiling($bounds.Height), 96, 96,
                [System.Windows.Media.PixelFormats]::Pbgra32)
            $image.Render($drawing)
        } else {
            $type.GetField('labelCountdown', $flags).GetValue($dialog).Text = $countdownText
            $dialog.PerformLayout()
            $bitmap = [System.Drawing.Bitmap]::new($dialog.Width, $dialog.Height)
            $stream = [System.IO.MemoryStream]::new()
            try {
                $dialog.DrawToBitmap($bitmap, [System.Drawing.Rectangle]::new(0, 0, $bitmap.Width, $bitmap.Height))
                $bitmap.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
                $stream.Position = 0
                $image = [System.Windows.Media.Imaging.BitmapImage]::new()
                $image.BeginInit()
                $image.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
                $image.StreamSource = $stream
                $image.EndInit()
            } finally {
                $bitmap.Dispose()
                $stream.Dispose()
            }
        }
        $image.Freeze()
        return $image
    } finally {
        if ($style -eq 'Classic') { $dialog.Dispose() } else { $dialog.Close() }
    }
}

function Show-RestartPolicyRestartPreview {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Policy)

    $image = New-RestartPolicyRestartPreviewImage -Policy $Policy
    $window = [System.Windows.Window]::new()
    $window.Title = 'RestartPolicy - DEMO'
    $window.SizeToContent = [System.Windows.SizeToContent]::WidthAndHeight
    $window.WindowStartupLocation = [System.Windows.WindowStartupLocation]::CenterScreen
    $window.Tag = 'DemoClosed'
    $panel = [System.Windows.Controls.StackPanel]::new()
    $notice = [System.Windows.Controls.TextBlock]::new()
    $notice.Text = "DEMO: Statisk bild av omstartsdialogen.`nIngen aktiv nedräkning, omstart eller sparad kvittering."
    $notice.Margin = [System.Windows.Thickness]::new(12)
    $panel.Children.Add($notice) | Out-Null
    $picture = [System.Windows.Controls.Image]::new()
    $picture.Source = $image
    $picture.IsHitTestVisible = $false
    $scroll = [System.Windows.Controls.ScrollViewer]::new()
    $scroll.MaxWidth = [System.Windows.SystemParameters]::WorkArea.Width - 80
    $scroll.MaxHeight = [System.Windows.SystemParameters]::WorkArea.Height - 160
    $scroll.Content = $picture
    $panel.Children.Add($scroll) | Out-Null
    $close = [System.Windows.Controls.Button]::new()
    $close.Content = 'Stäng demo'
    $close.Margin = [System.Windows.Thickness]::new(12)
    $close.Add_Click({ $window.Close() })
    $panel.Children.Add($close) | Out-Null
    $window.Content = $panel
    $timeout = [System.Windows.Threading.DispatcherTimer]::new()
    $timeout.Interval = [timespan]::FromSeconds($Policy.DialogTimeoutSeconds)
    $timeout.Add_Tick({ $window.Tag = 'Timeout'; $window.Close() })
    try {
        $timeout.Start()
        $null = $window.ShowDialog()
        return $window.Tag
    } finally {
        $timeout.Stop()
        $window.Close()
    }
}

function Show-RestartPolicyDemo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Policy,
        [ValidateSet('Reminder', 'RestartPrompt')][string]$Dialog = 'Reminder',
        [ValidateRange(-1, 2147483647)][int]$MinutesBefore = -1,
        [string]$LogPath
    )

    $demoPolicy = $Policy.PSObject.Copy()
    $demoPolicy.UseToolkitRestartPrompt = $Dialog -eq 'RestartPrompt'
    if ($Dialog -eq 'RestartPrompt') {
        $MinutesBefore = ($Policy.Reminders | Measure-Object -Property MinutesBefore -Minimum).Minimum
    } elseif ($MinutesBefore -eq -1) {
        $MinutesBefore = ($Policy.Reminders | Measure-Object -Property MinutesBefore -Maximum).Maximum
    }
    if ($MinutesBefore -ne 0 -and $MinutesBefore -notin $Policy.Reminders.MinutesBefore) {
        throw 'DemoMinutesBefore must match a configured reminder or be 0 for the overdue message.'
    }
    $now = [datetimeoffset]::UtcNow
    $demoBoot = $now.AddHours(-$Policy.RestartAfterHours).AddMinutes($MinutesBefore)
    $stage = Get-RestartPolicyStage -Policy $demoPolicy -BootTimeUtc $demoBoot -NowUtc $now
    if ($LogPath) {
        Write-RestartPolicyDiagnosticLog -Path $LogPath -Message "DEMO: $Dialog, stage $MinutesBefore minutes before deadline. Synthetic timing; real boot and acknowledgement state are not read or changed. No restart will be requested."
        if ($Dialog -eq 'RestartPrompt') {
            Write-RestartPolicyDiagnosticLog -Path $LogPath -Message 'DEMO: Static image of the packaged toolkit restart dialog. Countdown timer is disposed before rendering; original buttons are not interactive.'
        }
    }
    $result = Show-RestartPolicyReminder -Policy $demoPolicy -Stage $stage -Demo
    if ($LogPath) {
        Write-RestartPolicyDiagnosticLog -Path $LogPath -Message "DEMO result: $result."
    }
    return $result
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
    $stateStatus = 'No acknowledgement for this Windows boot.'
    if (Test-Path -LiteralPath $statePath) {
        $state = Get-ItemProperty -LiteralPath $statePath -ErrorAction Stop
        if ($null -ne $state.PSObject.Properties['BootTimeUtc'] -and $state.BootTimeUtc -eq $bootId) {
            if ($null -ne $state.PSObject.Properties['LastStageMinutes']) {
                $lastStage = [int]$state.LastStageMinutes
                $stateStatus = "Acknowledgement matches this Windows boot; last stage: $lastStage minutes before deadline."
            }
        } else {
            $stateStatus = 'Stored acknowledgement belongs to another Windows boot or has no boot ID; ignored.'
        }
    }
    $stage = Get-RestartPolicyStage -Policy $Policy -BootTimeUtc $BootTimeUtc -NowUtc $NowUtc -LastStageMinutes $lastStage
    if ($LogPath) {
        $deadline = $BootTimeUtc.AddHours($Policy.RestartAfterHours)
        $deadlineLocal = $deadline.ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss zzz')
        $bootLocal = $BootTimeUtc.ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss zzz')
        $nowLocal = $NowUtc.ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss zzz')
        $uptimeHours = ($NowUtc - $BootTimeUtc).TotalHours.ToString('F2', [cultureinfo]::InvariantCulture)
        $remainingMinutes = ($deadline - $NowUtc).TotalMinutes.ToString('F2', [cultureinfo]::InvariantCulture)
        Write-RestartPolicyDiagnosticLog -Path $LogPath -Message "Evaluation: $nowLocal. Uptime: $uptimeHours hours. RestartAfterHours: $($Policy.RestartAfterHours). Remaining: $remainingMinutes minutes (negative = overdue). PollSeconds: $($Policy.PollSeconds)."
        Write-RestartPolicyDiagnosticLog -Path $LogPath -Message "State: $stateStatus"
        $allMinutes = @($Policy.Reminders.MinutesBefore | Sort-Object -Descending) + @(0)
        foreach ($minutes in $allMinutes) {
            $threshold = $deadline.AddMinutes(-$minutes)
            $thresholdLocal = $threshold.ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss zzz')
            $reached = $NowUtc -ge $threshold
            $eligible = $minutes -lt $lastStage
            $stageStatus = if (-not $eligible) {
                'AcknowledgedOrSuperseded'
            } elseif (-not $reached) {
                'NotReached'
            } elseif ($null -ne $stage -and $stage.MinutesBefore -eq $minutes) {
                'Selected'
            } else {
                'SupersededByMoreUrgentStage'
            }
            Write-RestartPolicyDiagnosticLog -Path $LogPath -Message "Stage: $minutes minutes before deadline. Due at: $thresholdLocal. Reached: $reached. Eligible after acknowledgement: $eligible. Status: $stageStatus."
        }
        $dialog = if ($null -eq $stage) {
            'None'
        } elseif ($Policy.UseToolkitRestartPrompt -and $stage.MinutesBefore -le ($Policy.Reminders | Measure-Object -Property MinutesBefore -Minimum).Minimum) {
            'RestartPrompt'
        } else {
            'Reminder'
        }
        Write-RestartPolicyDiagnosticLog -Path $LogPath -Message "Restart decision: deadline reached: $($NowUtc -ge $deadline). Toolkit restart prompt enabled: $($Policy.UseToolkitRestartPrompt). Selected dialog: $dialog."
        if ($dialog -eq 'RestartPrompt') {
            $countdownSeconds = ($Policy.Reminders | Measure-Object -Property MinutesBefore -Minimum).Minimum * 60
            Write-RestartPolicyDiagnosticLog -Path $LogPath -Message "Restart prompt countdown: $countdownSeconds seconds from dialog launch, not from the deadline. Requires an active session at the policy check; the toolkit can restart silently if that session disappears."
        }
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

Export-ModuleMember -Function Assert-RestartPolicyExecutionContext, Import-RestartPolicy, New-RestartPolicyTaskTrigger, Get-RestartPolicyStage, Show-RestartPolicyReminder, Show-RestartPolicyDemo, Invoke-RestartPolicyPass, Write-RestartPolicyDiagnosticLog
