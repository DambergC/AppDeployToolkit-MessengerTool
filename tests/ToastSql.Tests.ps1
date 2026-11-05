BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../src/Module/ToastLogging.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '../src/Module/ToastSql.psm1') -Force
}

Describe 'ToastSql module' {
    It 'does not export removed image-handling functions' {
        (Get-Command -Name 'Resolve-ToastImageInput' -Module ToastSql -ErrorAction SilentlyContinue) | Should -BeNullOrEmpty
    }

    It 'builds a valid SQL connection string for integrated security' {
        $config = @{
            SqlServer = 'sql01'
            SqlPort = 1433
            SqlDatabase = 'ToastNotifications'
            UseIntegratedSecurity = $true
            Encrypt = $true
            TrustServerCertificate = $false
            ConnectTimeoutSeconds = 15
        }

        $connectionString = Get-ToastConnectionString $config
        $connectionString | Should -Match 'Data Source=tcp:sql01,1433'
        $connectionString | Should -Match 'Initial Catalog=ToastNotifications'
        $connectionString | Should -Match 'Integrated Security=True'
    }

    It 'builds a valid SQL connection string for SQL credential auth' {
        $config = @{
            SqlServer = 'sql01'
            SqlPort = 1433
            SqlDatabase = 'ToastNotifications'
            UseIntegratedSecurity = $false
            Encrypt = $true
            TrustServerCertificate = $false
            ConnectTimeoutSeconds = 15
        }

        $connectionString = Get-ToastConnectionString $config
        $connectionString | Should -Match 'Integrated Security=False'
    }

    It 'rejects non-boolean connection flags when building a connection string' {
        $config = @{
            SqlServer = 'sql01'
            SqlPort = 1433
            SqlDatabase = 'ToastNotifications'
            UseIntegratedSecurity = $true
            Encrypt = 'false'
            TrustServerCertificate = $false
            CommandTimeoutSeconds = 15
        }

        { Get-ToastConnectionString $config } | Should -Throw '*Config setting Encrypt must be $true or $false*'
    }

    It 'rejects an unreachable SQL port' {
        InModuleScope ToastSql {
            function Test-NetConnection { $false }
            try {
                { Test-ToastSqlPort -Server 'invalid.example' -Port 1433 } | Should -Throw
            } finally {
                Remove-Item Function:\Test-NetConnection -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'SQL configuration and parameters' {
        It 'validates static config and resolves the computer name' {
            $path = Join-Path $TestDrive 'config.psd1'
            "@{ UseIntegratedSecurity = 'false' }" | Set-Content $path
            { Import-ToastConfig -Path $path } | Should -Throw '*must be $true or $false*'
            '@{ CommandTimeoutSeconds = 0 }' | Set-Content $path
            { Import-ToastConfig -Path $path } | Should -Throw '*positive integer*'
            '@{}' | Set-Content $path
            { Import-ToastConfig -Path $path -RequiredProperties SqlServer } | Should -Throw '*missing required*'
            '@{ UseIntegratedSecurity = $false }' | Set-Content $path
            { Import-ToastConfig -Path $path } | Should -Throw '*SqlCredential*'
            "@{ ClientName = 'PC01' }" | Set-Content $path
            (Import-ToastConfig -Path $path -ResolveClientName).ClientName | Should -Be 'PC01'
        }

        It 'supports integrated authentication and explicit SQL credential forms' {
            Get-ToastSqlCredential -Config @{ UseIntegratedSecurity = $true } | Should -BeNullOrEmpty
            { Get-ToastSqlCredential -Config @{} } | Should -Throw '*UseIntegratedSecurity is required*'
            { Get-ToastSqlCredential -Config @{ UseIntegratedSecurity = $false } } | Should -Throw '*SqlCredential is required*'
            $secure = ConvertTo-SecureString 'example-password' -AsPlainText -Force
            $credentials = @(
                [pscredential]::new('example-user', $secure),
                @{ UserName = 'example-user'; Password = 'example-password' }
            )
            foreach ($credential in $credentials) {
                $result = Get-ToastSqlCredential -Config @{ UseIntegratedSecurity = $false; SqlCredential = $credential }
                $result | Should -BeOfType ([System.Data.SqlClient.SqlCredential])
                $result.UserId | Should -Be 'example-user'
                $result.Password.IsReadOnly() | Should -BeTrue
            }
            foreach ($credential in @(@{}, @{ UserName = 'name' }, @{ UserName = ''; Password = 'example-password' }, 'invalid')) {
                { Get-ToastSqlCredential -Config @{ UseIntegratedSecurity = $false; SqlCredential = $credential } } | Should -Throw '*SqlCredential*'
            }
        }

        It 'validates nullable client names collections and required empty settings' {
            $path = Join-Path $TestDrive 'nullable-config.psd1'
            "@{ SqlServer = ' '; ClientName = `$null; Groups = @() }" | Set-Content $path
            { Import-ToastConfig -Path $path -RequiredProperties SqlServer } | Should -Throw '*empty required*'
            { Import-ToastConfig -Path $path -NonEmptyProperties Groups } | Should -Throw '*at least one value*'
            $oldName = $env:COMPUTERNAME
            try {
                $env:COMPUTERNAME = 'ENV-PC'
                (Import-ToastConfig -Path $path -RequiredProperties ClientName -NullableProperties ClientName -ResolveClientName).ClientName | Should -Be 'ENV-PC'
                $env:COMPUTERNAME = ''
                { Import-ToastConfig -Path $path -ResolveClientName } | Should -Throw '*COMPUTERNAME*'
            } finally { $env:COMPUTERNAME = $oldName }
            "@{ ClientName = '' }" | Set-Content $path
            { Import-ToastConfig -Path $path -ResolveClientName } | Should -Throw '*non-empty string*'
            '@{ ClientName = 42 }' | Set-Content $path
            { Import-ToastConfig -Path $path -ResolveClientName } | Should -Throw '*string or $null*'
        }

        It 'uses typed nullable parameters and UTC datetime2 values' {
            InModuleScope ToastSql {
                $command = [System.Data.SqlClient.SqlCommand]::new()
                try {
                    foreach ($name in @('ExpiresUtc','ActiveDuration','DurationUnit','AcknowledgeButtonText','Subtitle','RepeatIntervalSeconds','RepeatCount')) {
                        Add-ToastSqlParameter -Command $command -Name $name -Value $null
                        $command.Parameters["@$name"].Value | Should -Be ([DBNull]::Value)
                        $command.Parameters["@$name"].SqlDbType | Should -Be $script:ToastSqlNullParameterDefinitions[$name].SqlDbType
                    }
                    $command.Parameters['@AcknowledgeButtonText'].Size | Should -Be 200
                    $command.Parameters['@Subtitle'].Size | Should -Be 200
                    $command.Parameters.Clear()
                    $utc = [datetime]::UtcNow.AddDays(1)
                    Add-ToastSqlParameter -Command $command -Name ExpiresUtc -Value $utc
                    $command.Parameters['@ExpiresUtc'].SqlDbType | Should -Be ([System.Data.SqlDbType]::DateTime2)
                    $command.Parameters['@ExpiresUtc'].Value | Should -Be $utc
                    $script:ToastSqlNullParameterDefinitions.Keys | Should -Not -Contain 'Sound'
                } finally { $command.Dispose() }
            }
        }

        It 'normalizes queue result shapes and rejects missing identifiers' {
            (Resolve-ToastQueueResult -Result ([pscustomobject]@{ MessageId = 42 })).MessageId | Should -Be 42
            $table = [System.Data.DataTable]::new()
            [void]$table.Columns.Add('MessageId', [long])
            [void]$table.Rows.Add(42)
            (Resolve-ToastQueueResult -Result $table).MessageId | Should -Be 42
            (Resolve-ToastQueueResult -Result $table.Rows[0]).MessageId | Should -Be 42
            { Resolve-ToastQueueResult -Result $null } | Should -Throw '*no result*'
            { Resolve-ToastQueueResult -Result ([pscustomobject]@{}) } | Should -Throw '*MessageId*'
            { Resolve-ToastQueueResult -Result ([pscustomobject]@{ MessageId = [DBNull]::Value }) } | Should -Throw '*null MessageId*'
            $table.Clear()
            { Resolve-ToastQueueResult -Result $table } | Should -Throw '*no rows*'
        }
    }

    Context 'repeat settings' {
        It 'keeps one-time messages unchanged when repeat settings are omitted' {
            $result = Resolve-ToastRepeatSettings

            $result.RepeatIntervalSeconds | Should -Be $null
            $result.RepeatCount | Should -Be $null
        }

        It 'normalizes minute-based repeats to seconds' {
            $result = Resolve-ToastRepeatSettings -RepeatIntervalMinutes 5 -RepeatCount 3

            $result.RepeatIntervalSeconds | Should -Be 300
            $result.RepeatCount | Should -Be 3
        }

        It 'preserves second-based repeats unchanged' {
            $result = Resolve-ToastRepeatSettings -RepeatIntervalSeconds 45 -RepeatCount 3

            $result.RepeatIntervalSeconds | Should -Be 45
            $result.RepeatCount | Should -Be 3
        }

        It 'rejects repeat counts without an interval' {
            { Resolve-ToastRepeatSettings -RepeatCount 2 } | Should -Throw '*RepeatIntervalSeconds or RepeatIntervalMinutes is required*'
        }

        It 'rejects interval-based repeats without a repeat count' {
            { Resolve-ToastRepeatSettings -RepeatIntervalSeconds 60 } | Should -Throw '*RepeatCount is required*'
        }

        It 'rejects repeat counts smaller than two' {
            { Resolve-ToastRepeatSettings -RepeatIntervalSeconds 60 -RepeatCount 1 } | Should -Throw '*RepeatCount must be 2 or greater*'
        }

        It 'rejects multiple repeat interval units at the same time' {
            { Resolve-ToastRepeatSettings -RepeatIntervalSeconds 60 -RepeatIntervalMinutes 1 -RepeatCount 2 } | Should -Throw '*either RepeatIntervalSeconds or RepeatIntervalMinutes*'
        }

        It 'rejects oversized repeat intervals in minutes' {
            { Resolve-ToastRepeatSettings -RepeatIntervalMinutes 35791395 -RepeatCount 2 } | Should -Throw '*RepeatIntervalMinutes is too large*'
        }
    }

    Context 'explicit expiry settings' {
        It 'converts zoned strings and DateTimeOffset to UTC datetime for SQL' {
            foreach ($value in @('2099-01-02T03:04:05+02:00', [datetimeoffset]'2099-01-02T03:04:05+02:00')) {
                $result = Resolve-ToastExpirySettings -ExpiresUtc $value
                $result.ExpiresUtc | Should -Be ([datetime]'2099-01-02T01:04:05Z')
                $result.ExpiresUtc.Kind | Should -Be ([DateTimeKind]::Utc)
                $result.ActiveDuration | Should -BeNullOrEmpty
                $result.DurationUnit | Should -BeNullOrEmpty
            }
            (Resolve-ToastExpirySettings -ExpiresUtc '2099-01-02T01:04:05Z').ExpiresUtc.Hour | Should -Be 1
            (Resolve-ToastExpirySettings -ExpiresUtc ([datetime]::UtcNow.AddDays(1))).ExpiresUtc.Kind | Should -Be ([DateTimeKind]::Utc)
        }

        It 'requires exactly one expiry choice and both duration fields' {
            { Resolve-ToastExpirySettings } | Should -Throw '*exactly one*'
            { Resolve-ToastExpirySettings -ExpiresUtc '2099-01-01T00:00:00Z' -ActiveDuration 1 -DurationUnit Days } | Should -Throw '*exactly one*'
            { Resolve-ToastExpirySettings -ExpiresUtc '2099-01-01T00:00:00Z' -DurationUnit Days } | Should -Throw '*exactly one*'
            { Resolve-ToastExpirySettings -ActiveDuration 1 } | Should -Throw '*required together*'
            { Resolve-ToastExpirySettings -DurationUnit Hours } | Should -Throw '*required together*'
        }

        It 'rejects unzoned ambiguous invalid and nonfuture absolute dates' {
            foreach ($value in @('2099-01-01', '2099-01-01T00:00:00', [datetime]::SpecifyKind([datetime]'2099-01-01', [DateTimeKind]::Unspecified), 'badZ', '', 42)) {
                { Resolve-ToastExpirySettings -ExpiresUtc $value } | Should -Throw
            }
            $now = [datetimeoffset]'2030-01-01T12:00:00Z'
            { Resolve-ToastExpirySettings -ExpiresUtc $now -Now $now } | Should -Throw '*future*'
            { Resolve-ToastExpirySettings -ExpiresUtc $now.AddTicks(-1) -Now $now } | Should -Throw '*future*'
            (Resolve-ToastExpirySettings -ExpiresUtc $now.AddTicks(1) -Now $now).ExpiresUtc | Should -Be $now.AddTicks(1).UtcDateTime
        }

        It 'passes positive integer duration units through without calculating client expiry' {
            foreach ($unit in @('Days','Hours','Minutes')) {
                $result = Resolve-ToastExpirySettings -ActiveDuration 3 -DurationUnit $unit
                $result.ActiveDuration | Should -Be 3
                $result.DurationUnit | Should -Be $unit
                $result.ExpiresUtc | Should -BeNullOrEmpty
            }
            foreach ($value in @(0, -1, 1.5, '2', $true, ([long][int]::MaxValue + 1))) {
                { Resolve-ToastExpirySettings -ActiveDuration $value -DurationUnit Days } | Should -Throw '*positive integer*'
            }
            { Resolve-ToastExpirySettings -ActiveDuration 1 -DurationUnit Weeks } | Should -Throw '*Days, Hours, or Minutes*'
        }
    }

    Context 'single-button plain-text rendering' {
        It 'exports no obsolete feature helpers and exposes no obsolete sender options' {
            foreach ($name in @('Resolve-ToastImageInput','Resolve-ToastButtonSettings','Resolve-ToastScenario','Resolve-ToastDisplayMode','Invoke-ToastProtocolAction')) {
                Get-Command $name -Module ToastSql -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
            }
            $parameters = (Get-Command "$PSScriptRoot/../src/Server/Send-ToastMessage.ps1").Parameters.Keys
            foreach ($name in @('Urgent','Scenario','DisplayMode','ButtonText','ButtonArguments','ButtonActivationType','Sound','AppLogoPath','HeroImagePath')) {
                $parameters | Should -Not -Contain $name
            }
            foreach ($name in @('Title','Subtitle','Body','AcknowledgeButtonText','ExpiresUtc','ActiveDuration','DurationUnit','RepeatCount','RepeatIntervalSeconds','RepeatIntervalMinutes')) {
                $parameters | Should -Contain $name
            }
        }

        It 'defaults and validates the only button label' {
            Resolve-ToastAcknowledgeButtonText | Should -Be 'Stäng'
            Resolve-ToastAcknowledgeButtonText -AcknowledgeButtonText '  ' | Should -Be 'Stäng'
            Resolve-ToastAcknowledgeButtonText -AcknowledgeButtonText '  Close  ' | Should -Be 'Close'
            { Resolve-ToastAcknowledgeButtonText -AcknowledgeButtonText ('x' * 201) } | Should -Throw '*200 characters*'
            { Resolve-ToastAcknowledgeButtonText -AcknowledgeButtonText ' timeout ' } | Should -Throw '*reserved*'
        }

        It 'recognizes only explicit clicked button text and never timeout or ambiguous results' {
            InModuleScope ToastSql {
                Resolve-ToastAppDeployToolkitPromptSelection -Result 'Stäng' | Should -Be 'Acknowledge'
                Resolve-ToastAppDeployToolkitPromptSelection -Result ([pscustomobject]@{ SelectedButton = 'Close' }) -AcknowledgeButtonText Close | Should -Be 'Acknowledge'
                foreach ($result in @($null, 0, 1, 'Right', 'OK', 'Acknowledge', 'Action', 'Dismiss', 'Unexpected')) {
                    Resolve-ToastAppDeployToolkitPromptSelection -Result $result | Should -Be 'Unknown'
                }
                Resolve-ToastAppDeployToolkitPromptSelection -Result 'Timeout' -AcknowledgeButtonText Timeout | Should -Be 'Timeout'
            }
        }

        It 'passes an independent title subtitle body and exactly one button' {
            InModuleScope ToastSql {
                function Show-ADTInstallationPrompt {
                    param([string]$Title, [Parameter(Mandatory)][string]$Subtitle, [string]$Message, [string]$ButtonRightText, [string]$ButtonLeftText, [string]$ButtonMiddleText, [string]$Icon)
                    $script:captured = $PSBoundParameters
                    $ButtonRightText
                }
                try {
                    $result = Show-ToastAppDeployToolkitPrompt -MessageId 42 -Title 'Title' -Subtitle 'Subtitle' -Body '<a href="https://example.com">Body & text</a>'
                    $result.ResultType | Should -Be 'Acknowledge'
                    $script:captured.Title | Should -Be 'Title'
                    $script:captured.Subtitle | Should -Be 'Subtitle'
                    $script:captured.Message | Should -Be '<a href="https://example.com">Body & text</a>'
                    $script:captured.ButtonRightText | Should -Be 'Stäng'
                    @($script:captured.Keys | Where-Object { $_ -like 'Button*' }).Count | Should -Be 1
                    $script:captured.ContainsKey('Icon') | Should -BeFalse
                    Show-ToastAppDeployToolkitPrompt -Title 'Unrelated title' -Body 'Unrelated body' | Out-Null
                    $script:captured.Subtitle | Should -Be 'Meddelande'
                } finally { Remove-Item Function:\Show-ADTInstallationPrompt }
            }
        }

        It 'neutralizes toolkit bracket markup and links in every message field' {
            InModuleScope ToastSql {
                function Show-ADTInstallationPrompt {
                    param([string]$Title, [string]$Subtitle, [string]$Message, [string]$ButtonRightText)
                    $script:captured = $PSBoundParameters
                    $ButtonRightText
                }
                try {
                    $content = '[url=https://example.com]Link[/url] [url]https://example.com[/url] [bold]Bold[/bold] [accent]Accent[/accent] [italic]Italic[/italic] <text> & plain'
                    Show-ToastAppDeployToolkitPrompt -Title $content -Subtitle $content -Body $content | Out-Null
                    foreach ($parameter in @('Title','Subtitle','Message')) {
                        $script:captured[$parameter].Replace([string][char]0x2060, '') | Should -Be $content
                        $script:captured[$parameter] | Should -Not -Match '\[/?(?:url|bold|accent|italic)'
                    }
                } finally { Remove-Item Function:\Show-ADTInstallationPrompt }
            }
        }

        It 'preserves subtitle for older prompt variants and surfaces display errors' {
            InModuleScope ToastSql {
                function Show-InstallationPrompt {
                    param([string]$Title, [string]$Message, [string]$ButtonRightText)
                    $script:captured = $PSBoundParameters
                    $ButtonRightText
                }
                try {
                    Show-ToastAppDeployToolkitPrompt -Title 'Title' -Subtitle 'Subtitle' -Body 'Body' -AcknowledgeButtonText Close | Out-Null
                    $script:captured.Title | Should -Be 'Title'
                    $script:captured.Message | Should -Be "Subtitle`r`n`r`nBody"
                    $script:captured.ButtonRightText | Should -Be 'Close'
                } finally { Remove-Item Function:\Show-InstallationPrompt }
                function Show-InstallationPrompt { param([string]$Title, [string]$Message, [string]$ButtonRightText) throw 'display failed' }
                try { { Show-ToastAppDeployToolkitPrompt -Title T -Body B } | Should -Throw '*prompt execution failed*' }
                finally { Remove-Item Function:\Show-InstallationPrompt }
            }
        }

        It 'stops on nonterminating toolkit errors and prevents toolkit timeout exits' {
            InModuleScope ToastSql {
                function Show-ADTInstallationPrompt {
                    [CmdletBinding()]
                    param([string]$Title, [string]$Subtitle, [string]$Message, [string]$ButtonRightText, [switch]$NoExitOnTimeout)
                    $script:captured = $PSBoundParameters
                    Write-Error 'Toolkit display failed'
                    $ButtonRightText
                }
                try {
                    { Show-ToastAppDeployToolkitPrompt -Title T -Body B } | Should -Throw '*prompt execution failed*'
                    $script:captured.NoExitOnTimeout | Should -BeTrue
                    $script:captured.ErrorAction | Should -Be 'Stop'
                } finally { Remove-Item Function:\Show-ADTInstallationPrompt }
            }
        }

        It 'fails closed for missing acknowledgement support and expired rows after dependency loading' {
            InModuleScope ToastSql {
                function Show-InstallationPrompt { param([string]$Title, [string]$Message) throw 'must not display' }
                try { { Show-ToastAppDeployToolkitPrompt -Title T -Body B } | Should -Throw '*ButtonRightText*' }
                finally { Remove-Item Function:\Show-InstallationPrompt }
                function Show-InstallationPrompt { param([string]$Title, [string]$Message, [string]$ButtonRightText) throw 'must not display' }
                try {
                    (Show-ToastAppDeployToolkitPrompt -Title T -Body B -ExpiresUtc ([datetime]::UtcNow.AddSeconds(-1))).ResultType | Should -Be 'Expired'
                } finally { Remove-Item Function:\Show-InstallationPrompt }
            }
        }
    }

    Context 'local toolkit dependency integrity' {
        It 'requires a local dependency path when toolkit commands are unavailable' {
            InModuleScope ToastSql {
                Set-ToastClientDependencyOptions
                Mock Get-ToastAppDeployToolkitPromptCommand { $null }
                { Ensure-ToastNotificationDependencies } | Should -Throw '*AppDeployToolkitModulePath*'
            }
        }

        It 'imports a packaged toolkit by folder or manifest without network installation' {
            $root = Join-Path $TestDrive 'toolkit'
            New-Item $root -ItemType Directory -Force | Out-Null
            "function Show-InstallationPrompt { param([string]`$Message) }" | Set-Content (Join-Path $root 'PSAppDeployToolkit.psm1')
            "@{ RootModule = 'PSAppDeployToolkit.psm1'; ModuleVersion = '1.0.0'; GUID = '11111111-1111-1111-1111-111111111111' }" | Set-Content (Join-Path $root 'PSAppDeployToolkit.psd1')
            InModuleScope ToastSql -Parameters @{ Root = $root } {
                param($Root)
                foreach ($path in @($Root, (Join-Path $Root 'PSAppDeployToolkit.psd1'))) {
                    try {
                        Set-ToastClientDependencyOptions -AppDeployToolkitModulePath $path
                        Ensure-ToastNotificationDependencies
                        Get-ToastAppDeployToolkitPromptCommand | Should -Not -BeNullOrEmpty
                    } finally { Remove-Module PSAppDeployToolkit -ErrorAction SilentlyContinue }
                }
                Set-ToastClientDependencyOptions
            }
        }
    }

    Context 'SYSTEM dialog session handling' {
        BeforeAll {
            InModuleScope ToastSql {
                function script:Get-ADTLoggedOnUser { [CmdletBinding()]param() }
                function script:Initialize-ADTModule { [CmdletBinding()]param() }
                function script:Get-ADTEnvironmentTable { [CmdletBinding()]param() }
                function script:Show-ADTInstallationPrompt {
                    [CmdletBinding()]
                    param([string]$Title, [string]$Message, [string]$ButtonRightText, [switch]$NoWait)
                    $ButtonRightText
                }
            }
        }

        BeforeEach {
            InModuleScope ToastSql {
                Set-ToastClientDependencyOptions -RunAsSystem
                $script:systemSessions = @([pscustomobject]@{ SessionId = 2; SID = 'S-1-5-21-100'; IsActiveUserSession = $true })
                $script:systemTarget = $script:systemSessions[0]
                Mock Get-ADTLoggedOnUser { $script:systemSessions }
                Mock Initialize-ADTModule {}
                Mock Get-ADTEnvironmentTable { @{ RunAsActiveUser = $script:systemTarget } }
                Mock Show-ADTInstallationPrompt { $ButtonRightText }
            }
        }

        AfterEach {
            InModuleScope ToastSql { Set-ToastClientDependencyOptions }
        }

        AfterAll {
            InModuleScope ToastSql {
                foreach ($name in @('Get-ADTLoggedOnUser','Initialize-ADTModule','Get-ADTEnvironmentTable','Show-ADTInstallationPrompt')) {
                    Remove-Item "Function:\$name"
                }
            }
        }

        It 'waits for the bridged dialog and recognizes only the acknowledgement' {
            InModuleScope ToastSql {
                (Show-ToastAppDeployToolkitPrompt -Title T -Body B -AcknowledgeButtonText Close).ResultType | Should -Be 'Acknowledge'
                Should -Invoke Initialize-ADTModule -Times 1 -Exactly
                Should -Invoke Show-ADTInstallationPrompt -Times 1 -Exactly -ParameterFilter { -not $NoWait -and $ButtonRightText -eq 'Close' -and $ErrorAction -eq 'Stop' }
            }
        }

        It 'does not initialize or display without an active user and retries after logon' {
            InModuleScope ToastSql {
                $activeSession = $script:systemSessions[0]
                $script:systemSessions = @()
                (Show-ToastAppDeployToolkitPrompt -Title T -Body B).ResultType | Should -Be 'NoActiveSession'
                $script:systemSessions = @([pscustomobject]@{ SessionId = 3; SID = 'S-1-5-21-200'; IsActiveUserSession = $false })
                (Show-ToastAppDeployToolkitPrompt -Title T -Body B).ResultType | Should -Be 'NoActiveSession'
                Should -Invoke Initialize-ADTModule -Times 0
                Should -Invoke Show-ADTInstallationPrompt -Times 0
                $script:systemSessions = @($activeSession)
                (Show-ToastAppDeployToolkitPrompt -Title T -Body B).ResultType | Should -Be 'Acknowledge'
            }
        }

        It 'refreshes the selected session after user switching between dialogs' {
            InModuleScope ToastSql {
                Mock Initialize-ADTModule { $script:systemTarget = $script:systemSessions[0] }
                Test-ToastSystemUserSession | Should -BeTrue
                $script:systemSessions = @([pscustomobject]@{ SessionId = 4; SID = 'S-1-5-21-300'; IsActiveUserSession = $true })
                Test-ToastSystemUserSession | Should -BeTrue
                $script:systemTarget.SessionId | Should -Be 4
                Should -Invoke Initialize-ADTModule -Times 2 -Exactly
            }
        }

        It 'postpones when the user logs off or changes session during selection' {
            InModuleScope ToastSql {
                Mock Initialize-ADTModule { $script:systemTarget = $null }
                (Show-ToastAppDeployToolkitPrompt -Title T -Body B).ResultType | Should -Be 'NoActiveSession'
                Mock Initialize-ADTModule {
                    $script:systemTarget = [pscustomobject]@{ SessionId = 5; SID = 'S-1-5-21-100' }
                }
                (Show-ToastAppDeployToolkitPrompt -Title T -Body B).ResultType | Should -Be 'NoActiveSession'
                Mock Initialize-ADTModule { $script:systemSessions[0].IsActiveUserSession = $false }
                (Show-ToastAppDeployToolkitPrompt -Title T -Body B).ResultType | Should -Be 'NoActiveSession'
                Should -Invoke Show-ADTInstallationPrompt -Times 0
            }
        }

        It 'surfaces session enumeration and initialization failures without displaying' {
            InModuleScope ToastSql {
                Mock Initialize-ADTModule { throw 'Session initialization failed' }
                { Show-ToastAppDeployToolkitPrompt -Title T -Body B } | Should -Throw '*Session initialization failed*'
                Mock Get-ADTLoggedOnUser { throw 'Session enumeration failed' }
                { Show-ToastAppDeployToolkitPrompt -Title T -Body B } | Should -Throw '*Session enumeration failed*'
                Should -Invoke Show-ADTInstallationPrompt -Times 0
            }
        }

        It 'rejects the legacy prompt and missing session bridge APIs for SYSTEM' {
            InModuleScope ToastSql {
                function Show-InstallationPrompt { param([string]$Title, [string]$Message, [string]$ButtonRightText) }
                try {
                    Mock Get-Command { $null } -ParameterFilter { $Name -eq 'Show-ADTInstallationPrompt' }
                    Get-ToastAppDeployToolkitPromptCommand | Should -BeNullOrEmpty
                    Set-ToastClientDependencyOptions
                    (Get-ToastAppDeployToolkitPromptCommand).Name | Should -Be 'Show-InstallationPrompt'
                    Set-ToastClientDependencyOptions -RunAsSystem
                    Mock Get-Command { $null } -ParameterFilter { $Name -eq 'Initialize-ADTModule' }
                    { Test-ToastSystemUserSession } | Should -Throw '*SYSTEM session handling requires Initialize-ADTModule*'
                } finally { Remove-Item Function:\Show-InstallationPrompt }
            }
        }
    }

    Context 'SYSTEM scheduled task registration' {
        BeforeAll {
            function New-ScheduledTaskAction { param($Execute, $Argument) }
            function New-ScheduledTaskTrigger { param([switch]$AtStartup, [switch]$AtLogOn, $User) }
            function New-ScheduledTaskPrincipal { param($UserId, $LogonType, $RunLevel) }
            function New-ScheduledTaskSettingsSet {
                param($MultipleInstances, $ExecutionTimeLimit, [switch]$StartWhenAvailable, $RestartCount, $RestartInterval,
                    [switch]$AllowStartIfOnBatteries, [switch]$DontStopIfGoingOnBatteries)
            }
            function Register-ScheduledTask { param($TaskName, $Action, $Trigger, $Principal, $Settings, $Description, [switch]$Force) }
        }

        BeforeEach {
            $script:previousSystemRoot = $env:SystemRoot
            $env:SystemRoot = $TestDrive
            $script:registrationArgs = @{
                ScriptPath = (Resolve-Path "$PSScriptRoot/../src/Client/Start-ToastClient.ps1").Path
                ConfigPath = (Resolve-Path "$PSScriptRoot/../config/config.example.psd1").Path
                RunAsSystem = $true
            }
            Mock New-ScheduledTaskAction { [pscustomobject]@{ Execute = $Execute; Argument = $Argument } }
            Mock New-ScheduledTaskTrigger { [pscustomobject]@{ AtStartup = [bool]$AtStartup; AtLogOn = [bool]$AtLogOn; User = $User } }
            Mock New-ScheduledTaskPrincipal { [pscustomobject]@{ UserId = $UserId; LogonType = $LogonType } }
            Mock New-ScheduledTaskSettingsSet { [pscustomobject]@{ MultipleInstances = $MultipleInstances } }
            Mock Register-ScheduledTask {}
        }

        AfterEach {
            $env:SystemRoot = $script:previousSystemRoot
        }

        It 'registers SYSTEM without a password with startup and all-user logon triggers' {
            & "$PSScriptRoot/../deploy/Register-ToastClientTask.ps1" @script:registrationArgs
            Should -Invoke New-ScheduledTaskPrincipal -Times 1 -Exactly -ParameterFilter { $UserId -eq 'S-1-5-18' -and $LogonType -eq 'ServiceAccount' -and $RunLevel -eq 'Highest' }
            Should -Invoke New-ScheduledTaskTrigger -Times 1 -Exactly -ParameterFilter { $AtStartup }
            Should -Invoke New-ScheduledTaskTrigger -Times 1 -Exactly -ParameterFilter { $AtLogOn -and -not $User }
            Should -Invoke New-ScheduledTaskAction -Times 1 -Exactly -ParameterFilter {
                $Execute -eq (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -and
                $Argument -match '-STA .* -File "[^"]+" -ConfigPath "[^"]+" -PollSeconds 30'
            }
            Should -Invoke New-ScheduledTaskSettingsSet -Times 1 -Exactly -ParameterFilter {
                $MultipleInstances -eq 'IgnoreNew' -and $ExecutionTimeLimit -eq [timespan]::Zero -and
                $StartWhenAvailable -and $RestartCount -eq 3 -and $RestartInterval -eq [timespan]::FromMinutes(1) -and
                $AllowStartIfOnBatteries -and $DontStopIfGoingOnBatteries
            }
            Should -Invoke Register-ScheduledTask -Times 1 -Exactly -ParameterFilter {
                $TaskName -eq 'AppDeployToolkit Toast SQL Client (SYSTEM)' -and $Force -and $Trigger.Count -eq 2 -and
                $Principal.UserId -eq 'S-1-5-18' -and $Action.Argument -match '-ConfigPath'
            }
        }

        It 'preserves an explicitly supplied task name' {
            & "$PSScriptRoot/../deploy/Register-ToastClientTask.ps1" @script:registrationArgs -TaskName 'Custom client'
            Should -Invoke Register-ScheduledTask -Times 1 -Exactly -ParameterFilter { $TaskName -eq 'Custom client' }
        }

        It 'rejects missing relative or quoted paths before registering a privileged task' {
            foreach ($path in @('relative.ps1', (Join-Path $TestDrive 'missing.ps1'), ($script:registrationArgs.ScriptPath + '"'))) {
                $arguments = $script:registrationArgs.Clone()
                $arguments.ScriptPath = $path
                { & "$PSScriptRoot/../deploy/Register-ToastClientTask.ps1" @arguments } | Should -Throw '*existing, absolute file paths without quotes*'
            }
            Should -Invoke Register-ScheduledTask -Times 0
            Should -Invoke New-ScheduledTaskAction -Times 0
        }
    }

    Context 'machine-wide registry read state' {
        It 'uses HKLM and isolates database server computer and port with case normalization' {
            $scope = @{ Server = 'sql01'; Port = 1433; Database = 'Toast'; ComputerName = 'PC01' }
            $path = Get-ToastReadStatePath @scope
            $path | Should -Match '^HKLM:\\Software\\AppDeployToolkit-MessengerTool\\ReadState\\[A-F0-9]{64}$'
            foreach ($key in @('Server','Database','ComputerName','Port')) {
                $changed = $scope.Clone()
                $changed[$key] = if ($key -eq 'Port') { 1434 } else { $scope[$key] + 'other' }
                Get-ToastReadStatePath @changed | Should -Not -Be $path
            }
            $scope.Server = 'SQL01'
            Get-ToastReadStatePath @scope | Should -Be $path
        }

        It 'round trips atomic JSON registry state' {
            InModuleScope ToastSql {
                $script:registryValue = $null
                Mock Test-Path { $true }
                Mock Write-ToastReadStateValue { $script:registryValue = $Value }
                Mock Get-ItemProperty { [pscustomobject]@{ '42' = $script:registryValue } }
                $next = [datetime]::UtcNow.AddMinutes(5)
                Set-ToastReadState -StatePath 'HKLM:\Test' -MessageId 42 -State ([pscustomobject]@{ Read = $true; ShowCount = 2; NextShowUtc = $next })
                $state = Get-ToastReadState -StatePath 'HKLM:\Test' -MessageId 42
                $state.Read | Should -BeTrue
                $state.ShowCount | Should -Be 2
                $state.NextShowUtc.ToString('o') | Should -Be $next.ToString('o')
                Should -Invoke Write-ToastReadStateValue -Times 1 -ParameterFilter { $Name -eq '42' -and $StatePath -eq 'HKLM:\Test' }
            }
        }

        It 'defaults missing state and rejects corrupt or inaccessible state' {
            InModuleScope ToastSql {
                Mock Test-Path { $false }
                (Get-ToastReadState -StatePath 'HKLM:\Test' -MessageId 42).ShowCount | Should -Be 0
                Mock Test-Path { $true }
                Mock Get-ItemProperty { [pscustomobject]@{ '42' = '{"Read":true,"ShowCount":-1,"NextShowUtc":null}' } }
                { Get-ToastReadState -StatePath 'HKLM:\Test' -MessageId 42 } | Should -Throw '*Invalid local read state*'
                Mock Get-ItemProperty { throw 'Access denied' }
                { Get-ToastReadState -StatePath 'HKLM:\Test' -MessageId 42 } | Should -Throw '*Access denied*'
            }
        }

        It 'requires administrator provisioning and never creates registry keys as the user' {
            InModuleScope ToastSql {
                Mock Test-Path { $false }
                Mock New-Item {}
                Mock Write-ToastReadStateValue { throw 'Access denied' }
                { Set-ToastReadState -StatePath 'HKLM:\Test' -MessageId 42 -State ([pscustomobject]@{ Read = $false; ShowCount = 0; NextShowUtc = $null }) } | Should -Throw '*Initialize-ToastReadState.ps1*'
                Should -Invoke New-Item -Times 0
                Should -Invoke Write-ToastReadStateValue -Times 0
                Mock Test-Path { $true }
                { Set-ToastReadState -StatePath 'HKLM:\Test' -MessageId 42 -State ([pscustomobject]@{ Read = $false; ShowCount = 0; NextShowUtc = $null }) } | Should -Throw '*Access denied*'
            }
            Test-Path "$PSScriptRoot/../deploy/Initialize-ToastReadState.ps1" | Should -BeTrue
        }

        It 'rejects writes outside a hashed HKLM read-state scope' {
            InModuleScope ToastSql {
                foreach ($path in @('HKCU:\Test', 'HKLM:\Software', 'HKLM:\Software\AppDeployToolkit-MessengerTool\ReadState')) {
                    { Write-ToastReadStateValue -StatePath $path -Name '42' -Value '{}' } | Should -Throw '*provisioned HKLM read-state scope*'
                }
            }
        }

        It 'opens a writable handle in the 64-bit registry view with only SetValue rights' {
            InModuleScope ToastSql {
                $source = (Get-Command Write-ToastReadStateValue).Definition
                $source | Should -Match '\[Microsoft.Win32.RegistryView\]::Registry64'
                $source | Should -Match 'OpenSubKey\(\$StatePath.Substring\(6\), \[Microsoft.Win32.RegistryKeyPermissionCheck\]::ReadWriteSubTree, \[System.Security.AccessControl.RegistryRights\]::SetValue\)'
                $source | Should -Not -Match 'CreateSubKey\('
            }
        }

        It 'persists and updates values through a real SetValue-only registry handle' -Tag 'WindowsRegistry' -Skip:(
            [Environment]::OSVersion.Platform -ne 'Win32NT' -or
            -not [Environment]::Is64BitProcess -or
            -not ([System.Security.Principal.WindowsPrincipal]::new(
                [System.Security.Principal.WindowsIdentity]::GetCurrent()
            )).IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
        ) {
            InModuleScope ToastSql {
                $statePath = Get-ToastReadStatePath -Server 'registry-test' -Port 1433 -Database 'test' -ComputerName ([guid]::NewGuid().ToString('N'))
                $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
                $key = $null
                try {
                    $key = $baseKey.CreateSubKey($statePath.Substring(6))
                    $key.Dispose()
                    $key = $null
                    foreach ($read in @($false, $true)) {
                        $next = [datetime]::UtcNow.AddMinutes(5)
                        Set-ToastReadState -StatePath $statePath -MessageId 42 -State ([pscustomobject]@{ Read = $read; ShowCount = 2; NextShowUtc = $next })
                        $state = Get-ToastReadState -StatePath $statePath -MessageId 42
                        $state.Read | Should -Be $read
                        $state.ShowCount | Should -Be 2
                        $state.NextShowUtc | Should -Be $next
                    }
                    $key = $baseKey.OpenSubKey($statePath.Substring(6))
                    $key.GetValueKind('42') | Should -Be ([Microsoft.Win32.RegistryValueKind]::String)
                } finally {
                    if ($null -ne $key) { $key.Dispose() }
                    try { $baseKey.DeleteSubKey($statePath.Substring(6), $false) }
                    finally { $baseKey.Dispose() }
                }
            }
        }
    }

    Context 'machine-wide read-state provisioning' {
        BeforeAll {
            $provisionPath = Join-Path $PSScriptRoot '../deploy/Initialize-ToastReadState.ps1'
            $provisionSource = Get-Content -LiteralPath $provisionPath -Raw
            $provisionAst = [System.Management.Automation.Language.Parser]::ParseFile($provisionPath, [ref]$null, [ref]$null)
        }

        It 'requires elevation and 64-bit provisioning and guards the client registry view' {
            $provisionAst.ScriptRequirements.IsElevationRequired | Should -BeTrue
            $provisionSource | Should -Match 'if \(-not \[Environment\]::Is64BitProcess\)'
            $clientSource = Get-Content (Join-Path $PSScriptRoot '../src/Client/Start-ToastClient.ps1') -Raw
            $clientSource | Should -Match 'if \(-not \[Environment\]::Is64BitProcess\)'
            $clientSource | Should -Match 'Initialize-ToastReadState.ps1'
        }

        It 'changes ACL only on the configured hash scope, preserving existing values' {
            $aclCommands = @($provisionAst.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Set-Acl'
            }, $true))
            $aclCommands.Count | Should -Be 1
            $aclCommands[0].Extent.Text | Should -Be 'Set-Acl -LiteralPath $statePath -AclObject $acl'
            $provisionSource | Should -Match 'Get-ToastReadStatePath -Server \$config.SqlServer -Port \$config.SqlPort -Database \$config.SqlDatabase -ComputerName \$config.ClientName'
            $provisionSource | Should -Match 'if \(-not \(Test-Path -LiteralPath \$statePath\)\)'
            $provisionSource | Should -Not -Match 'Remove-Item|New-ItemProperty|Set-ItemProperty'
        }

        It 'limits interactive rights to reading and setting values on the protected scope' {
            $provisionSource | Should -Match '\$acl.SetAccessRuleProtection\(\$true, \$false\)'
            $provisionSource | Should -Match ("\[System.Security.Principal.SecurityIdentifier\]::new\('S-1-5-4'\), " + '\$rights')
            $provisionSource | Should -Match '\$rights = \[System.Security.AccessControl.RegistryRights\]::ReadKey -bor \[System.Security.AccessControl.RegistryRights\]::SetValue'
            $provisionSource | Should -Not -Match 'RegistryRights\]::(WriteKey|CreateSubKey|ChangePermissions|TakeOwnership)'
        }

        It 'constructs the expected Windows ACL' -Skip:([Environment]::OSVersion.Platform -ne 'Win32NT') {
            $start = $provisionSource.IndexOf('$acl = ')
            $end = $provisionSource.IndexOf('Set-Acl -LiteralPath')
            $acl = & ([scriptblock]::Create($provisionSource.Substring($start, $end - $start) + '; $acl'))
            $acl.AreAccessRulesProtected | Should -BeTrue
            $acl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value | Should -Be 'S-1-5-32-544'
            $rules = @($acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]))
            $rules.Count | Should -Be 3
            $interactive = $rules | Where-Object { $_.IdentityReference.Value -eq 'S-1-5-4' }
            [int]$interactive.RegistryRights | Should -Be ([int][System.Security.AccessControl.RegistryRights]::ReadKey -bor [int][System.Security.AccessControl.RegistryRights]::SetValue)
            $interactive.InheritanceFlags | Should -Be 'None'
            foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
                ($rules | Where-Object { $_.IdentityReference.Value -eq $sid }).RegistryRights | Should -Be 'FullControl'
            }
        }
    }

    Context 'machine-wide Windows mutex' {
        It 'opens a shared Windows mutex with only synchronize and modify rights' -Skip:([Environment]::OSVersion.Platform -ne 'Win32NT') {
            InModuleScope ToastSql {
                $name = 'Global\ToastSql-Test-' + [guid]::NewGuid().ToString('N')
                $first = New-ToastClientMutex -Name $name
                $second = $null
                try {
                    $second = New-ToastClientMutex -Name $name
                    $first.WaitOne(0) | Should -BeTrue
                    $first.ReleaseMutex()
                    $second.WaitOne(0) | Should -BeTrue
                    $second.ReleaseMutex()
                } finally {
                    if ($null -ne $second) { $second.Dispose() }
                    $first.Dispose()
                }
            }
        }

    }

    Context 'machine-wide polling concurrency' {
        BeforeEach {
            InModuleScope ToastSql {
                $script:lockAvailable = $true
                $script:releaseCount = 0
                $script:disposeCount = 0
                $script:passArgs = @{ ConnectionString = 'test'; ComputerName = 'PC01'; StatePath = 'HKLM:\ReadState\scope' }
                Mock New-ToastClientMutex {
                    $lock = [pscustomobject]@{}
                    $lock | Add-Member ScriptMethod WaitOne { param($timeout) return $script:lockAvailable }
                    $lock | Add-Member ScriptMethod ReleaseMutex { $script:releaseCount++ }
                    $lock | Add-Member ScriptMethod Dispose { $script:disposeCount++ }
                    return $lock
                }
                Mock Invoke-ToastClientPoll {}
            }
        }

        It 'skips a busy machine scope and uses the same lock for all users' {
            InModuleScope ToastSql {
                $script:lockAvailable = $false
                Invoke-ToastClientPass @script:passArgs
                Should -Invoke Invoke-ToastClientPoll -Times 0
                $script:lockAvailable = $true
                Invoke-ToastClientPass @script:passArgs
                Invoke-ToastClientPass @script:passArgs
                Should -Invoke Invoke-ToastClientPoll -Times 2
                Should -Invoke New-ToastClientMutex -Times 3 -ParameterFilter { $Name -eq 'Global\ToastSql-scope' }
                $script:releaseCount | Should -Be 2
                $script:disposeCount | Should -Be 3
            }
        }

        It 'releases the machine lock when polling fails' {
            InModuleScope ToastSql {
                Mock Invoke-ToastClientPoll { throw 'Persistence failed' }
                { Invoke-ToastClientPass @script:passArgs } | Should -Throw '*Persistence failed*'
                $script:releaseCount | Should -Be 1
                $script:disposeCount | Should -Be 1
            }
        }
    }

    Context 'read-only client polling and expiry boundaries' {
        BeforeEach {
            InModuleScope ToastSql {
                $script:pollRows = @([pscustomobject]@{ MessageId = 42; RepeatCount = $null; RepeatIntervalSeconds = $null; ExpiresUtc = [datetime]::UtcNow.AddDays(1) })
                $script:localStates = @{}
                $script:pollArgs = @{ ConnectionString = 'test'; ComputerName = 'PC01'; StatePath = 'HKLM:\Test' }
                Mock Invoke-ToastSql {
                    if ($null -eq $Parameters.MessageId) { return $script:pollRows }
                    return $script:pollRows | Where-Object MessageId -eq $Parameters.MessageId
                }
                Mock Get-ToastReadState {
                    if ($script:localStates.ContainsKey([long]$MessageId)) { return $script:localStates[[long]$MessageId] }
                    return [pscustomobject]@{ Read = $false; ShowCount = 0; NextShowUtc = $null }
                }
                Mock Set-ToastReadState {
                    $script:localStates[[long]$MessageId] = [pscustomobject]@{ Read = $State.Read; ShowCount = $State.ShowCount; NextShowUtc = $State.NextShowUtc }
                }
                Mock Invoke-ToastNotification { [pscustomobject]@{ ResultType = 'Acknowledge' } }
            }
        }

        It 'suppresses an acknowledged one-time message without database writes' {
            InModuleScope ToastSql {
                Invoke-ToastClientPoll @script:pollArgs
                Invoke-ToastClientPoll @script:pollArgs
                $script:localStates[42L].Read | Should -BeTrue
                $script:localStates[42L].ShowCount | Should -Be 1
                Should -Invoke Invoke-ToastNotification -Times 1
                Should -Invoke Invoke-ToastSql -Times 3 -Exactly -ParameterFilter { -not $NonQuery -and $CommandText -eq 'EXEC dbo.usp_GetPendingToast @ComputerName, @MessageId' }
            }
        }

        It 'persists independent repeat schedules and stops after the total' {
            InModuleScope ToastSql {
                $script:pollRows[0].RepeatCount = 2
                $script:pollRows[0].RepeatIntervalSeconds = 600
                Invoke-ToastClientPoll @script:pollArgs
                $script:localStates[42L].NextShowUtc | Should -BeGreaterThan ([datetime]::UtcNow.AddMinutes(9))
                Invoke-ToastClientPoll @script:pollArgs
                Should -Invoke Invoke-ToastNotification -Times 1
                $script:localStates[42L].NextShowUtc = [datetime]::UtcNow.AddSeconds(-1)
                Invoke-ToastClientPoll @script:pollArgs
                Invoke-ToastClientPoll @script:pollArgs
                $script:localStates[42L].ShowCount | Should -Be 2
                $script:localStates[42L].NextShowUtc | Should -BeNullOrEmpty
                Should -Invoke Invoke-ToastNotification -Times 2
            }
        }

        It 'never acknowledges timeout null unknown or removed action outcomes' {
            InModuleScope ToastSql {
                foreach ($outcome in @('Timeout','Unknown','Action','Dismiss','Expired','NoActiveSession')) {
                    Mock Invoke-ToastNotification { [pscustomobject]@{ ResultType = $outcome } }
                    Invoke-ToastClientPoll @script:pollArgs -WarningAction SilentlyContinue
                    $script:localStates[42L].ShowCount | Should -Be 0
                    $script:localStates[42L].Read | Should -BeFalse
                }
                Mock Invoke-ToastNotification { $null }
                Invoke-ToastClientPoll @script:pollArgs -WarningAction SilentlyContinue
                $script:localStates[42L].ShowCount | Should -Be 0
            }
        }

        It 'keeps acknowledgement state authoritative when local logging fails' {
            InModuleScope ToastSql -Parameters @{ LogPath = (Join-Path $TestDrive 'missing\Client.log') } {
                Invoke-ToastClientPoll @script:pollArgs -LogPath $LogPath -RunId 'test-run' -WarningAction SilentlyContinue
                $script:localStates[42L].Read | Should -BeTrue
                $script:localStates[42L].ShowCount | Should -Be 1
            }
        }

        It 'leaves render failures unread and continues with subsequent messages' {
            InModuleScope ToastSql {
                $script:pollRows += [pscustomobject]@{ MessageId = 43; RepeatCount = $null; RepeatIntervalSeconds = $null; ExpiresUtc = [datetime]::UtcNow.AddDays(1) }
                Mock Invoke-ToastNotification { throw 'Render failed' } -ParameterFilter { $ToastRow.MessageId -eq 42 }
                Invoke-ToastClientPoll @script:pollArgs -WarningAction SilentlyContinue
                $script:localStates[42L].ShowCount | Should -Be 0
                $script:localStates[43L].ShowCount | Should -Be 1
            }
        }

        It 'rechecks SQL membership cancellation and expiry for every queued message' {
            InModuleScope ToastSql {
                Mock Invoke-ToastSql { $null } -ParameterFilter { $null -ne $Parameters.MessageId }
                Invoke-ToastClientPoll @script:pollArgs
                Should -Invoke Invoke-ToastNotification -Times 0
                Should -Invoke Set-ToastReadState -Times 0
            }
        }

        It 'treats SQL datetime2 as UTC and expires exactly at the boundary' {
            InModuleScope ToastSql {
                $now = [datetime]'2030-01-01T12:00:00Z'
                foreach ($value in @($now, $now.AddTicks(-1), [datetimeoffset]'2030-01-01T14:00:00+02:00', $null, 'unparseable', '2030-01-01T13:00:00')) {
                    Test-ToastRowUnexpired -ToastRow ([pscustomobject]@{ ExpiresUtc = $value }) -Now $now | Should -BeFalse
                }
                $value = [datetime]::SpecifyKind($now.AddTicks(1), [DateTimeKind]::Unspecified)
                Test-ToastRowUnexpired -ToastRow ([pscustomobject]@{ ExpiresUtc = $value }) -Now $now | Should -BeTrue
                Test-ToastRowUnexpired -ToastRow ([pscustomobject]@{ ExpiresUtc = '2030-01-01T14:00:01+02:00' }) -Now $now | Should -BeTrue
            }
        }

        It 'skips a later queued row that expires while an earlier prompt blocks' {
            InModuleScope ToastSql {
                $script:pollRows += [pscustomobject]@{ MessageId = 43; RepeatCount = $null; RepeatIntervalSeconds = $null; ExpiresUtc = [datetime]::UtcNow.AddDays(1) }
                Mock Invoke-ToastNotification {
                    $script:pollRows[1].ExpiresUtc = [datetime]::UtcNow.AddTicks(-1)
                    [pscustomobject]@{ ResultType = 'Acknowledge' }
                }
                Invoke-ToastClientPoll @script:pollArgs
                Should -Invoke Invoke-ToastSql -Times 1 -ParameterFilter { $Parameters.MessageId -eq 43 }
                Should -Invoke Invoke-ToastNotification -Times 1 -Exactly -ParameterFilter { $ToastRow.MessageId -eq 42 }
                $script:localStates[43L].ShowCount | Should -Be 0
            }
        }

        It 'checks expiry again after persistence immediately before displaying' {
            InModuleScope ToastSql {
                Mock Set-ToastReadState { $script:pollRows[0].ExpiresUtc = [datetime]::UtcNow.AddSeconds(-1) }
                Invoke-ToastClientPoll @script:pollArgs
                Should -Invoke Invoke-ToastNotification -Times 0
            }
        }

        It 'displays only the refreshed SQL row and ignores stale queued content' {
            InModuleScope ToastSql {
                Mock Invoke-ToastSql {
                    [pscustomobject]@{ MessageId = 42; Title = 'Refreshed title'; ExpiresUtc = [datetime]::UtcNow.AddMinutes(1); RepeatCount = $null; RepeatIntervalSeconds = $null }
                } -ParameterFilter { $Parameters.MessageId -eq 42 }
                Invoke-ToastClientPoll @script:pollArgs
                Should -Invoke Invoke-ToastNotification -Times 1 -Exactly -ParameterFilter { $ToastRow.Title -eq 'Refreshed title' }
            }
        }

        It 'finds unread messages beyond twenty-five suppressed SQL DataTable rows' {
            InModuleScope ToastSql {
                Mock Invoke-ToastSql {
                    $table = [System.Data.DataTable]::new()
                    [void]$table.Columns.Add('MessageId', [long])
                    [void]$table.Columns.Add('RepeatCount', [int])
                    [void]$table.Columns.Add('RepeatIntervalSeconds', [int])
                    [void]$table.Columns.Add('ExpiresUtc', [datetime])
                    foreach ($id in 1..26) {
                        if ($null -eq $Parameters.MessageId -or $id -eq $Parameters.MessageId) {
                            [void]$table.Rows.Add($id, [DBNull]::Value, [DBNull]::Value, [datetime]::UtcNow.AddDays(1))
                        }
                    }
                    Write-Output -NoEnumerate $table
                }
                foreach ($id in 1..25) { $script:localStates[[long]$id] = [pscustomobject]@{ Read = $true; ShowCount = 1; NextShowUtc = $null } }
                Invoke-ToastClientPoll @script:pollArgs
                Should -Invoke Invoke-ToastNotification -Times 1 -Exactly -ParameterFilter { $ToastRow -is [System.Data.DataRow] -and $ToastRow.MessageId -eq 26 }
                $script:localStates[26L].Read | Should -BeTrue
                $script:localStates.Clear()
                Mock Invoke-ToastSql { Write-Output -NoEnumerate ([System.Data.DataTable]::new()) } -ParameterFilter { $null -ne $Parameters.MessageId }
                Invoke-ToastClientPoll @script:pollArgs
                Should -Invoke Invoke-ToastNotification -Times 1
            }
        }

        It 'fails visibly on registry errors before or after acknowledgement' {
            InModuleScope ToastSql {
                Mock Set-ToastReadState { throw 'Cannot persist state' }
                { Invoke-ToastClientPoll @script:pollArgs } | Should -Throw '*Cannot persist state*'
                Should -Invoke Invoke-ToastNotification -Times 0
                Mock Set-ToastReadState { if ($State.Read) { throw 'Cannot save acknowledgement' } }
                { Invoke-ToastClientPoll @script:pollArgs } | Should -Throw '*Cannot save acknowledgement*'
                Should -Invoke Invoke-ToastNotification -Times 1
            }
        }
    }

    Context 'sender SQL contract' {
        BeforeEach {
            Mock Import-Module {}
            Mock New-ToastLogRunId { '0123456789abcdef0123456789abcdef' }
            Mock Get-ToastServerLogPath { 'test.log' }
            Mock Write-ToastLog {}
            Mock Import-ToastConfig { @{ SqlServer = 'sql01'; SqlPort = 1433; CommandTimeoutSeconds = 15 } }
            Mock Test-ToastSqlPort {}
            Mock Get-ToastConnectionString { 'test' }
            Mock Get-ToastSqlCredential { $null }
            Mock Invoke-ToastSql { [pscustomobject]@{ MessageId = 42 } }
        }

        It 'sends exactly the ten queue parameters and converts absolute expiry to UTC' {
            & "$PSScriptRoot/../src/Server/Send-ToastMessage.ps1" -ConfigPath admin.psd1 -GroupName IT -Title Title -Subtitle Subtitle -Body Body -ExpiresUtc '2099-01-01T02:00:00+02:00' | Should -Match 'Queued message 42'
            Should -Invoke Invoke-ToastSql -Times 1 -ParameterFilter {
                $Parameters.Count -eq 10 -and $Parameters.AcknowledgeButtonText -eq 'Stäng' -and
                $Parameters.ExpiresUtc -eq [datetime]'2099-01-01T00:00:00Z' -and $Parameters.ExpiresUtc.Kind -eq [DateTimeKind]::Utc -and
                $null -eq $Parameters.ActiveDuration -and $null -eq $Parameters.DurationUnit -and
                $Parameters.Subtitle -eq 'Subtitle' -and $CommandText -notmatch 'Urgent|Scenario|DisplayMode|ButtonArguments'
            }
        }

        It 'passes duration calculation to SQL and preserves custom label and repeats' {
            & "$PSScriptRoot/../src/Server/Send-ToastMessage.ps1" -ConfigPath admin.psd1 -GroupName IT -Title Title -Body Body -ActiveDuration 2 -DurationUnit Hours -AcknowledgeButtonText Close -RepeatIntervalMinutes 5 -RepeatCount 3 | Out-Null
            Should -Invoke Invoke-ToastSql -Times 1 -ParameterFilter {
                $Parameters.Count -eq 10 -and $null -eq $Parameters.ExpiresUtc -and $Parameters.ActiveDuration -eq 2 -and $Parameters.DurationUnit -eq 'Hours' -and
                $Parameters.AcknowledgeButtonText -eq 'Close' -and $Parameters.RepeatIntervalSeconds -eq 300 -and $Parameters.RepeatCount -eq 3
            }
        }

        It 'rejects missing expiry before contacting SQL' {
            { & "$PSScriptRoot/../src/Server/Send-ToastMessage.ps1" -ConfigPath admin.psd1 -GroupName IT -Title Title -Body Body } | Should -Throw '*exactly one*'
            Should -Invoke Invoke-ToastSql -Times 0
            Should -Invoke Test-ToastSqlPort -Times 0
        }
    }

    Context 'AD computer import' {
        BeforeEach {
            function Get-ADComputer { param($Filter, $SearchBase) }
            function Get-ADObject { param($Identity, $Properties) }
            function Get-ADGroupMember { param($Identity, [switch]$Recursive) }
            Mock Import-Module {}
            Mock Get-ADObject { [pscustomobject]@{ ObjectClass = 'organizationalUnit' } }
            Mock Get-ADGroupMember {}
            Mock Get-ADComputer { [pscustomobject]@{ Name = 'PC01' }; [pscustomobject]@{ Name = 'PC01' }; [pscustomobject]@{ Name = "PC'02" } }
            Mock New-ToastLogRunId { '0123456789abcdef0123456789abcdef' }
            Mock Get-ToastServerLogPath { 'test.log' }
            Mock Write-ToastLog {}
            Mock Import-ToastConfig { @{ CommandTimeoutSeconds = 15 } }
            Mock Get-ToastConnectionString { 'test' }
            Mock Get-ToastSqlCredential { $null }
            Mock Invoke-ToastSql {
                $table = [System.Data.DataTable]::new()
                [void]$table.Columns.Add('Changes', [int])
                [void]$table.Rows.Add(1)
                Write-Output -NoEnumerate $table
            }
        }
        It 'uses OU and AD filter and parameterized idempotent membership inserts' {
            $result = & "$PSScriptRoot/../src/Server/Import-ToastADComputers.ps1" -ConfigPath admin.psd1 -Tag ' IT ' -SearchBase 'OU=PC,DC=test' -Filter 'Enabled -eq $true'
            $result.Count | Should -Be 2
            Should -Invoke Get-ADComputer -Times 1 -ParameterFilter { $Filter -eq 'Enabled -eq $true' -and $SearchBase -eq 'OU=PC,DC=test' }
            Should -Invoke Invoke-ToastSql -Times 2 -ParameterFilter {
                -not $NonQuery -and $Parameters.GroupName -eq 'IT' -and $CommandText -match 'UPDLOCK, HOLDLOCK' -and
                $CommandText -match 'BEGIN TRAN' -and $CommandText -match 'SELECT @Changes AS Changes' -and
                $CommandText -notmatch "PC'02" -and $CommandText -notmatch 'ToastDelivery'
            }
        }
        It 'supports WhatIf without database writes' {
            & "$PSScriptRoot/../src/Server/Import-ToastADComputers.ps1" -ConfigPath admin.psd1 -Tag IT -WhatIf
            Should -Invoke Invoke-ToastSql -Times 0
        }
        It 'imports recursive group computers while excluding noncomputer members' {
            Mock Get-ADObject { [pscustomobject]@{ ObjectClass = 'group' } }
            Mock Get-ADGroupMember {
                [pscustomobject]@{ Name = 'PC01'; ObjectClass = 'computer' }
                [pscustomobject]@{ Name = 'PC01'; ObjectClass = 'computer' }
                [pscustomobject]@{ Name = 'Person'; ObjectClass = 'user' }
            }
            $result = & "$PSScriptRoot/../src/Server/Import-ToastADComputers.ps1" -ConfigPath admin.psd1 -Tag IT -SearchBase 'CN=Computers,DC=test'
            @($result).Count | Should -Be 1
            Should -Invoke Get-ADGroupMember -Times 1 -ParameterFilter { $Recursive -and $Identity -eq 'CN=Computers,DC=test' }
            Should -Invoke Get-ADComputer -Times 0
            Should -Invoke Invoke-ToastSql -Times 1 -ParameterFilter { $Parameters.ComputerName -eq 'PC01' }
        }
        It 'rejects custom filters with group membership selection' {
            Mock Get-ADObject { [pscustomobject]@{ ObjectClass = 'group' } }
            { & "$PSScriptRoot/../src/Server/Import-ToastADComputers.ps1" -ConfigPath admin.psd1 -Tag IT -SearchBase 'CN=Computers,DC=test' -Filter 'Enabled -eq $true' } | Should -Throw '*Filter cannot be used*'
            Should -Invoke Invoke-ToastSql -Times 0
        }
        It 'validates all computer names and tags before writes' {
            { & "$PSScriptRoot/../src/Server/Import-ToastADComputers.ps1" -ConfigPath admin.psd1 -Tag ('a' * 129) } | Should -Throw
            Mock Get-ADComputer { [pscustomobject]@{ Name = 'PC01' }; [pscustomobject]@{ Name = ('x' * 257) } }
            { & "$PSScriptRoot/../src/Server/Import-ToastADComputers.ps1" -ConfigPath admin.psd1 -Tag IT } | Should -Throw '*between 1 and 256*'
            Should -Invoke Invoke-ToastSql -Times 0
        }
    }

    Context 'first-install SQL contracts' {
        It 'creates only the four supported tables and no obsolete runtime contracts' {
            $text = Get-Content "$PSScriptRoot/../sql/Install-ToastDatabase.sql" -Raw
            @([regex]::Matches($text, '(?i)CREATE TABLE dbo\.(\w+)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object) |
                Should -Be @('ToastClient','ToastClientGroup','ToastGroup','ToastMessage')
            $text | Should -Not -Match 'ToastDelivery|LeaseId|LastSeenUtc|IsUrgent|Scenario|DisplayMode|ButtonArguments|ButtonActivationType|AppLogo|HeroImage|\bSound\b|CREATE FUNCTION|CREATE VIEW|ufn_Toast|vw_Toast'
            foreach ($name in @('GroupName','Title','Subtitle','Body','AcknowledgeButtonText','ExpiresUtc','ActiveDuration','DurationUnit','RepeatIntervalSeconds','RepeatCount')) {
                $text | Should -Match "@$name\b"
            }
            $text | Should -Match "N''Stäng''"
            $text | Should -Match 'SYSUTCDATETIME\(\)'
            $text | Should -Not -Match '\bSYSDATETIME\(\)|CURRENT_TIMEZONE|AT TIME ZONE'
        }

        It 'polls with SELECT only and returns the exact read-only client fields' {
            $text = Get-Content "$PSScriptRoot/../sql/Install-ToastDatabase.sql" -Raw
            $proc = [regex]::Match($text, "(?is)CREATE(?: OR ALTER)? PROCEDURE dbo.usp_GetPendingToast.*?\r?\nEND;\r?\n';").Value
            $proc | Should -Not -BeNullOrEmpty
            $proc | Should -Not -Match '(?i)\b(UPDATE|INSERT|DELETE|MERGE|EXEC|TOP|UPDLOCK)\b'
            foreach ($field in @('MessageId','Title','Subtitle','Body','AcknowledgeButtonText','RepeatIntervalSeconds','RepeatCount','ExpiresUtc')) { $proc | Should -Match "m\.$field\b" }
            $proc | Should -Match 'm\.ExpiresUtc\s*>\s*(SYSUTCDATETIME\(\)|@Now)'
            $proc | Should -Match 'm\.IsCancelled\s*=\s*0'
            $proc | Should -Match 'g\.IsActive\s*=\s*1'
            $proc | Should -Match 'c\.IsActive\s*=\s*1'
            $proc | Should -Match 'c\.ComputerName\s*=\s*@ComputerName'
            $proc | Should -Match 'INNER JOIN dbo\.ToastClientGroup'
            $proc | Should -Match 'INNER JOIN dbo\.ToastClient'
            $text | Should -Match 'GRANT EXECUTE ON OBJECT::dbo.usp_GetPendingToast TO ToastClientReader'
            $text | Should -Match 'DENY INSERT, UPDATE, DELETE TO ToastClientReader'
            $text | Should -Match 'DENY EXECUTE ON OBJECT::dbo.usp_QueueToastMessage TO ToastClientReader'
        }

        It 'validates mutually exclusive expiration and calculates durations from the insertion UTC clock' {
            $text = Get-Content "$PSScriptRoot/../sql/Install-ToastDatabase.sql" -Raw
            $declaration = [regex]::Match($text, '(?is)CREATE PROCEDURE dbo.usp_QueueToastMessage(.*?)\r?\nAS').Groups[1].Value
            @([regex]::Matches($declaration, '@(\w+)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object) |
                Should -Be @('AcknowledgeButtonText','ActiveDuration','Body','DurationUnit','ExpiresUtc','GroupName','RepeatCount','RepeatIntervalSeconds','Subtitle','Title')
            $text | Should -Match '@ExpiresUtc IS NOT NULL AND \(@ActiveDuration IS NOT NULL OR @DurationUnit IS NOT NULL\)'
            $text | Should -Match '@ExpiresUtc IS NULL AND \(@ActiveDuration IS NULL OR @DurationUnit IS NULL\)'
            $text | Should -Match '@ActiveDuration\s*<=\s*0'
            $text | Should -Match '@CreatedUtc datetime2\(7\) = SYSUTCDATETIME\(\)'
            foreach ($unit in @('DAY','HOUR','MINUTE')) { $text | Should -Match "DATEADD\($unit, @ActiveDuration, @CreatedUtc\)" }
            $text | Should -Match '@ExpiresUtc\s*<=\s*@CreatedUtc'
            $text | Should -Match 'CHECK \(ExpiresUtc > CreatedUtc\)'
            $text | Should -Match '@AcknowledgeButtonText COLLATE Latin1_General_100_CI_AS = N''''Timeout'''''
            $text | Should -Match 'AcknowledgeButtonText must not be Timeout'
        }

        It 'keeps user task scheduling non-elevated and client database access read-only' {
            $text = Get-Content "$PSScriptRoot/../src/Client/Start-ToastClient.ps1" -Raw
            $text | Should -Not -Match '\$Register|ClientGroups|usp_RecordToastDelivery|NonQuery|LeaseId|LastSeen'
            $text | Should -Match 'Invoke-ToastClientPass'
            $text | Should -Match 'Set-ToastClientDependencyOptions -AppDeployToolkitModulePath'
            $task = Get-Content "$PSScriptRoot/../deploy/Register-ToastClientTask.ps1" -Raw
            $task | Should -Match '-LogonType Interactive -RunLevel Limited'
            $task | Should -Match '-MultipleInstances IgnoreNew'
            $task | Should -Match '-STA'
        }
    }
}
