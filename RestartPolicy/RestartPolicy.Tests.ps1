BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'RestartPolicy.psm1') -Force
    $script:exampleXml = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'RestartPolicy.xml') -Raw -Encoding UTF8
    $script:policy = Import-RestartPolicy -Path (Join-Path $PSScriptRoot 'RestartPolicy.xml')
    $script:boot = [datetimeoffset]'2026-01-01T00:00:00Z'
}

Describe 'RestartPolicy XML configuration' {
    It 'rejects invalid XML settings: <Name>' -ForEach @(
        @{ Name = 'zero uptime'; Old = '<RestartAfterHours>72</RestartAfterHours>'; New = '<RestartAfterHours>0</RestartAfterHours>' }
        @{ Name = 'fractional uptime'; Old = '<RestartAfterHours>72</RestartAfterHours>'; New = '<RestartAfterHours>1.5</RestartAfterHours>' }
        @{ Name = 'zero poll interval'; Old = '<PollSeconds>60</PollSeconds>'; New = '<PollSeconds>0</PollSeconds>' }
        @{ Name = 'sub-minute poll interval'; Old = '<PollSeconds>60</PollSeconds>'; New = '<PollSeconds>30</PollSeconds>' }
        @{ Name = 'fractional minute poll interval'; Old = '<PollSeconds>60</PollSeconds>'; New = '<PollSeconds>90</PollSeconds>' }
        @{ Name = 'missing field'; Old = '<PollSeconds>60</PollSeconds>'; New = '' }
        @{ Name = 'unknown field'; Old = '</RestartPolicy>'; New = '<Unknown>1</Unknown></RestartPolicy>' }
        @{ Name = 'blank title'; Old = '<Title>Omstart av datorn</Title>'; New = '<Title> </Title>' }
        @{ Name = 'long timeout'; Old = '<DialogTimeoutSeconds>120</DialogTimeoutSeconds>'; New = '<DialogTimeoutSeconds>301</DialogTimeoutSeconds>' }
        @{ Name = 'invalid restart prompt option'; Old = '<UseToolkitRestartPrompt>true</UseToolkitRestartPrompt>'; New = '<UseToolkitRestartPrompt>yes</UseToolkitRestartPrompt>' }
        @{ Name = 'duplicate reminder'; Old = 'MinutesBefore="180"'; New = 'MinutesBefore="360"' }
        @{ Name = 'negative reminder'; Old = 'MinutesBefore="180"'; New = 'MinutesBefore="-1"' }
        @{ Name = 'outside last day'; Old = 'MinutesBefore="360"'; New = 'MinutesBefore="1441"' }
        @{ Name = 'before boot'; Old = 'MinutesBefore="360"'; New = 'MinutesBefore="4320"' }
        @{ Name = 'reserved button text'; Old = '<AcknowledgeButtonText>Jag har l' + [char]0x00e4 + 'st</AcknowledgeButtonText>'; New = '<AcknowledgeButtonText>Timeout</AcknowledgeButtonText>' }
    ) {
        $path = Join-Path $TestDrive 'invalid.xml'
        $script:exampleXml.Replace($Old, $New) | Set-Content -LiteralPath $path -Encoding UTF8
        { Import-RestartPolicy -Path $path } | Should -Throw
    }

    It 'rejects DTDs without resolving external entities' {
        $path = Join-Path $TestDrive 'dtd.xml'
        $script:exampleXml.Replace('<RestartPolicy>', '<!DOCTYPE RestartPolicy [<!ENTITY x "test">]><RestartPolicy>') |
            Set-Content -LiteralPath $path -Encoding UTF8
        { Import-RestartPolicy -Path $path } | Should -Throw
    }

    It 'resolves a relative toolkit path against the configuration directory' {
        $script:policy.ToolkitModulePath | Should -Be (Join-Path $PSScriptRoot '..\Dependencies\PSAppDeployToolkit\4.1.8\PSAppDeployToolkit.psd1')
    }

    It 'supports the restart prompt option and defaults to false for older configurations' {
        $script:policy.UseToolkitRestartPrompt | Should -BeTrue
        $path = Join-Path $TestDrive 'prompt.xml'
        $script:exampleXml.Replace('<UseToolkitRestartPrompt>true</UseToolkitRestartPrompt>', '<UseToolkitRestartPrompt>false</UseToolkitRestartPrompt>') |
            Set-Content -LiteralPath $path -Encoding UTF8
        (Import-RestartPolicy -Path $path).UseToolkitRestartPrompt | Should -BeFalse
        $script:exampleXml.Replace('<UseToolkitRestartPrompt>true</UseToolkitRestartPrompt>', '') |
            Set-Content -LiteralPath $path -Encoding UTF8
        (Import-RestartPolicy -Path $path).UseToolkitRestartPrompt | Should -BeFalse
    }

    It 'uses configured times and text rather than hardcoded defaults' {
        $path = Join-Path $TestDrive 'custom.xml'
        $customXml = $script:exampleXml.Replace('<RestartAfterHours>72</RestartAfterHours>', '<RestartAfterHours>48</RestartAfterHours>')
        $customXml = $customXml.Replace('MinutesBefore="360"', 'MinutesBefore="240"').Replace('Det ', 'CUSTOM ')
        $customXml | Set-Content -LiteralPath $path -Encoding UTF8
        $custom = Import-RestartPolicy -Path $path
        $stage = Get-RestartPolicyStage -Policy $custom -BootTimeUtc $script:boot -NowUtc $script:boot.AddHours(44)
        $stage.MinutesBefore | Should -Be 240
        $stage.Message | Should -Match 'CUSTOM'
        $stage.DeadlineUtc | Should -Be $script:boot.AddHours(48)
    }
}

Describe 'RestartPolicy execution context' {
    It 'allows SYSTEM and elevated administrators but rejects standard users' {
        { Assert-RestartPolicyExecutionContext -IsSystem $true -IsAdministrator $false } | Should -Not -Throw
        { Assert-RestartPolicyExecutionContext -IsSystem $false -IsAdministrator $true } | Should -Not -Throw
        { Assert-RestartPolicyExecutionContext -IsSystem $false -IsAdministrator $false } |
            Should -Throw '*elevated administrator*'
    }
}

Describe 'RestartPolicy scheduled triggers' {
    It 'creates startup, logon and daily repeating triggers with the configured interval' -Skip:([Environment]::OSVersion.Platform -ne 'Win32NT') {
        $triggers = @(New-RestartPolicyTaskTrigger -PollSeconds 300)
        $triggers.Count | Should -Be 3
        $triggers[0].CimClass.CimClassName | Should -Be 'MSFT_TaskBootTrigger'
        $triggers[1].CimClass.CimClassName | Should -Be 'MSFT_TaskLogonTrigger'
        $triggers[2].CimClass.CimClassName | Should -Be 'MSFT_TaskDailyTrigger'
        $triggers[2].Repetition.Interval | Should -Be 'PT5M'
        $triggers[2].Repetition.Duration | Should -Be 'P1D'
    }
}

Describe 'RestartPolicy timing' {
    It 'selects the most urgent due stage at <Hours> hours' -ForEach @(
        @{ Hours = 48; Expected = -1 }
        @{ Hours = 65.999; Expected = -1 }
        @{ Hours = 66; Expected = 360 }
        @{ Hours = 68.999; Expected = 360 }
        @{ Hours = 69; Expected = 180 }
        @{ Hours = 71.499; Expected = 180 }
        @{ Hours = 71.5; Expected = 30 }
        @{ Hours = 71.999; Expected = 30 }
        @{ Hours = 72; Expected = 0 }
        @{ Hours = 100; Expected = 0 }
    ) {
        $stage = Get-RestartPolicyStage -Policy $script:policy -BootTimeUtc $script:boot -NowUtc $script:boot.AddHours($Hours)
        if ($Expected -eq -1) {
            $stage | Should -BeNullOrEmpty
        } else {
            $stage.MinutesBefore | Should -Be $Expected
        }
    }

    It 'does not repeat acknowledged or older stages, including after clock rollback' {
        Get-RestartPolicyStage -Policy $script:policy -BootTimeUtc $script:boot -NowUtc $script:boot.AddHours(66) -LastStageMinutes 360 |
            Should -BeNullOrEmpty
        Get-RestartPolicyStage -Policy $script:policy -BootTimeUtc $script:boot -NowUtc $script:boot.AddHours(66) -LastStageMinutes 30 |
            Should -BeNullOrEmpty
        Get-RestartPolicyStage -Policy $script:policy -BootTimeUtc $script:boot -NowUtc $script:boot.AddHours(100) -LastStageMinutes 0 |
            Should -BeNullOrEmpty
    }

    It 'advances to the next stage and replaces the local deadline placeholder' {
        $stage = Get-RestartPolicyStage -Policy $script:policy -BootTimeUtc $script:boot -NowUtc $script:boot.AddHours(69) -LastStageMinutes 360
        $stage.MinutesBefore | Should -Be 180
        $stage.Message | Should -Not -Match '\{DeadlineLocal\}'
        $stage.Message | Should -Match ([regex]::Escape($script:boot.AddHours(72).ToLocalTime().ToString('yyyy-MM-dd HH:mm')))
    }

    It 'rejects a future boot timestamp' {
        { Get-RestartPolicyStage -Policy $script:policy -BootTimeUtc $script:boot -NowUtc $script:boot.AddSeconds(-1) } |
            Should -Throw '*system clock*'
    }
}

Describe 'RestartPolicy toolkit session bridge' {
    BeforeAll {
        InModuleScope RestartPolicy {
            function script:Get-ADTLoggedOnUser { [CmdletBinding()]param() }
            function script:Initialize-ADTModule { [CmdletBinding()]param() }
            function script:Get-ADTEnvironmentTable { [CmdletBinding()]param() }
            function script:Show-ADTInstallationPrompt {
                [CmdletBinding()]
                param($Title, $Subtitle, $Message, $ButtonRightText, $Timeout, [switch]$NoExitOnTimeout)
            }
            function script:Show-ADTInstallationRestartPrompt {
                [CmdletBinding()]
                param($Title, $Subtitle, $CountdownSeconds, $CountdownNoHideSeconds)
            }
        }
    }

    BeforeEach {
        Mock Get-ADTLoggedOnUser -ModuleName RestartPolicy {
            [pscustomobject]@{ IsActiveUserSession = $true; SessionId = 1; SID = 'test-sid' }
        }
        Mock Initialize-ADTModule -ModuleName RestartPolicy {}
        Mock Get-ADTEnvironmentTable -ModuleName RestartPolicy {
            @{ RunAsActiveUser = [pscustomobject]@{ SessionId = 1; SID = 'test-sid' } }
        }
        Mock Show-ADTInstallationPrompt -ModuleName RestartPolicy { $ButtonRightText }
        Mock Show-ADTInstallationRestartPrompt -ModuleName RestartPolicy {}
        $script:stage = Get-RestartPolicyStage -Policy $script:policy -BootTimeUtc $script:boot -NowUtc $script:boot.AddHours(66)
    }

    It 'uses the toolkit prompt with the configured text and a bounded timeout' {
        Show-RestartPolicyReminder -Policy $script:policy -Stage $script:stage | Should -Be 'Acknowledged'
        Should -Invoke Initialize-ADTModule -ModuleName RestartPolicy -Times 1 -Exactly
        Should -Invoke Show-ADTInstallationPrompt -ModuleName RestartPolicy -Times 1 -Exactly -ParameterFilter {
            $Title -eq 'Omstart av datorn' -and $Subtitle -eq 'RestartPolicy' -and
            $ButtonRightText -eq ('Jag har l' + [char]0x00e4 + 'st') -and
            $Message -match '6 timmar' -and $Timeout -eq 120 -and $NoExitOnTimeout
        }
    }

    It 'postpones when no session is active' {
        Mock Get-ADTLoggedOnUser -ModuleName RestartPolicy {}
        Show-RestartPolicyReminder -Policy $script:policy -Stage $script:stage | Should -Be 'NoActiveSession'
        Should -Invoke Show-ADTInstallationPrompt -ModuleName RestartPolicy -Times 0
    }

    It 'rechecks the selected session after toolkit initialization' {
        Mock Get-ADTEnvironmentTable -ModuleName RestartPolicy {
            @{ RunAsActiveUser = [pscustomobject]@{ SessionId = 2; SID = 'other-sid' } }
        }
        Show-RestartPolicyReminder -Policy $script:policy -Stage $script:stage | Should -Be 'NoActiveSession'
        Should -Invoke Show-ADTInstallationPrompt -ModuleName RestartPolicy -Times 0
    }

    It 'does not treat a timeout as acknowledgement' {
        Mock Show-ADTInstallationPrompt -ModuleName RestartPolicy { 'Timeout' }
        Show-RestartPolicyReminder -Policy $script:policy -Stage $script:stage | Should -Be 'Timeout'
    }

    It 'surfaces unexpected dialog results' {
        Mock Show-ADTInstallationPrompt -ModuleName RestartPolicy { $null }
        { Show-RestartPolicyReminder -Policy $script:policy -Stage $script:stage } | Should -Throw '*not acknowledged*'
    }

    It 'surfaces toolkit errors' {
        Mock Show-ADTInstallationPrompt -ModuleName RestartPolicy { throw 'dialog failed' }
        { Show-RestartPolicyReminder -Policy $script:policy -Stage $script:stage } | Should -Throw '*dialog failed*'
    }

    It 'uses the restart prompt only for the last reminder or overdue stage when enabled: <Hours>' -ForEach @(
        @{ Hours = 71.5 }
        @{ Hours = 72 }
        @{ Hours = 100 }
    ) {
        $enabled = $script:policy.PSObject.Copy()
        $enabled.UseToolkitRestartPrompt = $true
        $stage = Get-RestartPolicyStage -Policy $enabled -BootTimeUtc $script:boot -NowUtc $script:boot.AddHours($Hours)
        Show-RestartPolicyReminder -Policy $enabled -Stage $stage | Should -Be 'RestartPromptReturned'
        Should -Invoke Show-ADTInstallationRestartPrompt -ModuleName RestartPolicy -Times 1 -Exactly -ParameterFilter {
            $Title -eq 'Omstart av datorn' -and $Subtitle -eq 'RestartPolicy' -and
            $CountdownSeconds -eq 1800 -and $CountdownNoHideSeconds -eq 30
        }
        Should -Invoke Show-ADTInstallationPrompt -ModuleName RestartPolicy -Times 0
    }

    It 'retains the normal prompt for earlier stages and when the option is disabled' {
        $enabled = $script:policy.PSObject.Copy()
        $enabled.UseToolkitRestartPrompt = $true
        Show-RestartPolicyReminder -Policy $enabled -Stage $script:stage | Should -Be 'Acknowledged'
        $disabled = $script:policy.PSObject.Copy()
        $disabled.UseToolkitRestartPrompt = $false
        $last = Get-RestartPolicyStage -Policy $disabled -BootTimeUtc $script:boot -NowUtc $script:boot.AddHours(71.5)
        Show-RestartPolicyReminder -Policy $disabled -Stage $last | Should -Be 'Acknowledged'
        Should -Invoke Show-ADTInstallationRestartPrompt -ModuleName RestartPolicy -Times 0
    }

    It 'uses the smallest configured reminder for the countdown regardless of XML order' {
        $enabled = $script:policy.PSObject.Copy()
        $enabled.UseToolkitRestartPrompt = $true
        $enabled.Reminders = @(
            [pscustomobject]@{ MinutesBefore = 5; Message = 'Last' }
            [pscustomobject]@{ MinutesBefore = 60; Message = 'First' }
        )
        $last = Get-RestartPolicyStage -Policy $enabled -BootTimeUtc $script:boot -NowUtc $script:boot.AddHours(72)
        Show-RestartPolicyReminder -Policy $enabled -Stage $last | Should -Be 'RestartPromptReturned'
        Should -Invoke Show-ADTInstallationRestartPrompt -ModuleName RestartPolicy -Times 1 -Exactly -ParameterFilter {
            $CountdownSeconds -eq 300
        }
    }

    It 'does not launch the restart prompt without an active session' {
        $enabled = $script:policy.PSObject.Copy()
        $enabled.UseToolkitRestartPrompt = $true
        Mock Get-ADTLoggedOnUser -ModuleName RestartPolicy {}
        $last = Get-RestartPolicyStage -Policy $enabled -BootTimeUtc $script:boot -NowUtc $script:boot.AddHours(71.5)
        Show-RestartPolicyReminder -Policy $enabled -Stage $last | Should -Be 'NoActiveSession'
        Should -Invoke Show-ADTInstallationRestartPrompt -ModuleName RestartPolicy -Times 0
    }

    It 'surfaces restart prompt errors' {
        $enabled = $script:policy.PSObject.Copy()
        $enabled.UseToolkitRestartPrompt = $true
        Mock Show-ADTInstallationRestartPrompt -ModuleName RestartPolicy { throw 'restart dialog failed' }
        $last = Get-RestartPolicyStage -Policy $enabled -BootTimeUtc $script:boot -NowUtc $script:boot.AddHours(71.5)
        { Show-RestartPolicyReminder -Policy $enabled -Stage $last } | Should -Throw '*restart dialog failed*'
    }
}

Describe 'RestartPolicy per-boot acknowledgement state' {
    BeforeAll {
        InModuleScope RestartPolicy {
            # Registry-provider dynamic parameters are unavailable on non-Windows test hosts.
            function script:New-ItemProperty {
                [CmdletBinding()]
                param($LiteralPath, $Name, $Value, $PropertyType, [switch]$Force)
            }
        }
    }

    BeforeEach {
        Mock Test-Path -ModuleName RestartPolicy { $true }
        Mock Get-ItemProperty -ModuleName RestartPolicy {
            [pscustomobject]@{ BootTimeUtc = '2026-01-01T00:00:00.0000000+00:00'; LastStageMinutes = 360 }
        }
        Mock New-Item -ModuleName RestartPolicy {}
        Mock New-ItemProperty -ModuleName RestartPolicy {}
        Mock Show-RestartPolicyReminder -ModuleName RestartPolicy { 'Acknowledged' }
    }

    It 'does not redisplay an acknowledged stage after process restart' {
        Invoke-RestartPolicyPass -Policy $script:policy -BootTimeUtc $script:boot -NowUtc $script:boot.AddHours(66) |
            Should -Be 'NotDue'
        Should -Invoke Show-RestartPolicyReminder -ModuleName RestartPolicy -Times 0
    }

    It 'records acknowledgement in its own HKLM scope' {
        Invoke-RestartPolicyPass -Policy $script:policy -BootTimeUtc $script:boot -NowUtc $script:boot.AddHours(69) |
            Should -Be 'Acknowledged'
        Should -Invoke New-ItemProperty -ModuleName RestartPolicy -Times 1 -Exactly -ParameterFilter {
            $LiteralPath -eq 'HKLM:\SOFTWARE\RestartPolicy' -and $Name -eq 'LastStageMinutes' -and $Value -eq 180
        }
        Should -Invoke New-ItemProperty -ModuleName RestartPolicy -Times 1 -Exactly -ParameterFilter {
            $LiteralPath -eq 'HKLM:\SOFTWARE\RestartPolicy' -and $Name -eq 'BootTimeUtc' -and $PropertyType -eq 'String'
        }
    }

    It 'does not record an unanswered reminder: <Result>' -ForEach @(
        @{ Result = 'NoActiveSession' }
        @{ Result = 'Timeout' }
        @{ Result = 'RestartPromptReturned' }
    ) {
        Mock Show-RestartPolicyReminder -ModuleName RestartPolicy { $Result }
        Invoke-RestartPolicyPass -Policy $script:policy -BootTimeUtc $script:boot -NowUtc $script:boot.AddHours(69) |
            Should -Be $Result
        Should -Invoke New-ItemProperty -ModuleName RestartPolicy -Times 0
    }

    AfterAll {
        Remove-Module RestartPolicy -Force
    }

    It 'resets acknowledgements after a real reboot' {
        Mock Get-ItemProperty -ModuleName RestartPolicy {
            [pscustomobject]@{ BootTimeUtc = '2025-12-01T00:00:00.0000000+00:00'; LastStageMinutes = 0 }
        }
        Invoke-RestartPolicyPass -Policy $script:policy -BootTimeUtc $script:boot -NowUtc $script:boot.AddHours(66) |
            Should -Be 'Acknowledged'
        Should -Invoke Show-RestartPolicyReminder -ModuleName RestartPolicy -Times 1 -Exactly
    }

    It 'surfaces state-write failures' {
        Mock New-ItemProperty -ModuleName RestartPolicy { throw 'access denied' }
        { Invoke-RestartPolicyPass -Policy $script:policy -BootTimeUtc $script:boot -NowUtc $script:boot.AddHours(69) } |
            Should -Throw '*access denied*'
    }

    It 'logs the next eligible reminder and restart deadline after acknowledgement' {
        $path = Join-Path $TestDrive 'diagnostic.log'
        Invoke-RestartPolicyPass -Policy $script:policy -BootTimeUtc $script:boot -NowUtc $script:boot.AddHours(66) -LogPath $path |
            Should -Be 'NotDue'
        $log = Get-Content -LiteralPath $path -Raw
        $log | Should -Match ([regex]::Escape($script:boot.AddHours(69).ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss zzz')))
        $log | Should -Match ([regex]::Escape($script:boot.AddHours(72).ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss zzz')))
        $log | Should -Match 'No reminder due'
    }

    It 'logs the first reminder before any stage is due' {
        Mock Test-Path -ModuleName RestartPolicy { $false }
        $path = Join-Path $TestDrive 'first.log'
        Invoke-RestartPolicyPass -Policy $script:policy -BootTimeUtc $script:boot -NowUtc $script:boot.AddHours(1) -LogPath $path |
            Should -Be 'NotDue'
        Get-Content -LiteralPath $path -Raw | Should -Match ([regex]::Escape($script:boot.AddHours(66).ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss zzz')))
    }

    It 'logs that no further reminders are scheduled after the final acknowledgement' {
        Mock Get-ItemProperty -ModuleName RestartPolicy {
            [pscustomobject]@{ BootTimeUtc = '2026-01-01T00:00:00.0000000+00:00'; LastStageMinutes = 0 }
        }
        $path = Join-Path $TestDrive 'final.log'
        Invoke-RestartPolicyPass -Policy $script:policy -BootTimeUtc $script:boot -NowUtc $script:boot.AddHours(100) -LogPath $path |
            Should -Be 'NotDue'
        Get-Content -LiteralPath $path -Raw | Should -Match 'No further reminders until the next Windows restart'
    }

    It 'logs a due reminder and a missing active session' {
        Mock Show-RestartPolicyReminder -ModuleName RestartPolicy { 'NoActiveSession' }
        $path = Join-Path $TestDrive 'session.log'
        Invoke-RestartPolicyPass -Policy $script:policy -BootTimeUtc $script:boot -NowUtc $script:boot.AddHours(69) -LogPath $path |
            Should -Be 'NoActiveSession'
        $log = Get-Content -LiteralPath $path -Raw
        $log | Should -Match 'Reminder due: 180 minutes'
        $log | Should -Match 'Reminder result: NoActiveSession'
        $log | Should -Match 'next scheduled run can try again'
    }

    It 'surfaces diagnostic log write errors' {
        $path = Join-Path (Join-Path $TestDrive 'missing') 'diagnostic.log'
        { Invoke-RestartPolicyPass -Policy $script:policy -BootTimeUtc $script:boot -NowUtc $script:boot.AddHours(66) -LogPath $path } |
            Should -Throw
    }
}
