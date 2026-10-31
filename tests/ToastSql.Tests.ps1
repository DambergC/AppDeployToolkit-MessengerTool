$modulePath = Join-Path $PSScriptRoot '..\src\Module\ToastSql.psm1'
Import-Module $modulePath -Force

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

    Context 'button settings' {
        It 'returns nulls when no button data is supplied' {
            $result = Resolve-ToastButtonSettings -ButtonText $null -ButtonArguments $null

            $result.ButtonText | Should -Be $null
            $result.ButtonArguments | Should -Be $null
            $result.ButtonActivationType | Should -Be $null
        }

        It 'rejects invalid button activation type values' {
            { Resolve-ToastButtonSettings -ButtonText 'Open' -ButtonArguments 'https://example.com' -ButtonActivationType 'Bogus' } |
                Should -Throw '*Protocol,Dismiss*'
        }

        It 'requires ButtonArguments for a Protocol action button' {
            { Resolve-ToastButtonSettings -ButtonText 'Open' -ButtonActivationType 'Protocol' } |
                Should -Throw '*ButtonArguments is required when ButtonActivationType is Protocol*'
        }

        It 'requires an absolute URI for protocol action buttons' {
            { Resolve-ToastButtonSettings -ButtonText 'Open' -ButtonArguments 'www.example.com' -ButtonActivationType 'Protocol' } |
                Should -Throw '*ButtonArguments must be a valid absolute URI*'
        }

        It 'accepts a raw absolute http, https, or mailto URL for protocol buttons' {
            foreach ($url in @('https://github.com/DambergC/BurntToast-SQLserver/tree/main', 'http://intranet.contoso.example/status', 'mailto:support@contoso.example')) {
                $result = Resolve-ToastButtonSettings -ButtonText 'Open' -ButtonArguments "  $url  " -ButtonActivationType 'Protocol'
                $result.ButtonArguments | Should -Be $url
                $result.ButtonActivationType | Should -Be 'Protocol'
            }
        }

        It 'normalizes JSON {"url":"..."} protocol button arguments to the raw URL before the SQL call' {
            $result = Resolve-ToastButtonSettings -ButtonText 'Open GitHub' -ButtonArguments '{"url":"https://github.com/DambergC/BurntToast-SQLserver/tree/main"}' -ButtonActivationType 'Protocol'
            $result.ButtonArguments | Should -Be 'https://github.com/DambergC/BurntToast-SQLserver/tree/main'

            $defaulted = Resolve-ToastButtonSettings -ButtonText 'Open GitHub' -ButtonArguments ' { "url" : " https://github.com/DambergC " } '
            $defaulted.ButtonArguments | Should -Be 'https://github.com/DambergC'
            $defaulted.ButtonActivationType | Should -Be 'Protocol'
        }

        It 'rejects malformed JSON protocol button arguments with a clear error' {
            { Resolve-ToastButtonSettings -ButtonText 'Open' -ButtonArguments '{"url":"https://github.com"' -ButtonActivationType 'Protocol' } |
                Should -Throw '*malformed JSON*'
        }

        It 'rejects JSON protocol button arguments without a usable url property' {
            foreach ($json in @('{}', '{"link":"https://github.com"}', '{"url":""}', '{"url":42}', '{"url":null}')) {
                { Resolve-ToastButtonSettings -ButtonText 'Open' -ButtonArguments $json -ButtonActivationType 'Protocol' } |
                    Should -Throw "*non-empty string 'url' property*"
            }
        }

        It 'rejects JSON protocol button arguments whose url is not an absolute http, https, or mailto URI' {
            foreach ($json in @('{"url":"www.github.com"}', '{"url":"/relative"}', '{"url":"file:///C:/Windows/notepad.exe"}', '{"url":"https:github.com"}')) {
                { Resolve-ToastButtonSettings -ButtonText 'Open' -ButtonArguments $json -ButtonActivationType 'Protocol' } |
                    Should -Throw "*JSON 'url' value must be a valid absolute URI using http, https, or mailto*"
            }
        }

        It 'rejects raw protocol button arguments with unsupported schemes at send time' {
            foreach ($url in @('file:///C:/Windows/notepad.exe', 'ftp://files.example.com/file', 'https:///nohost')) {
                { Resolve-ToastButtonSettings -ButtonText 'Open' -ButtonArguments $url -ButtonActivationType 'Protocol' } |
                    Should -Throw '*ButtonArguments must be a valid absolute URI using http, https, or mailto*'
            }
        }

        It 'accepts a valid Dismiss button without arguments' {
            $result = Resolve-ToastButtonSettings -ButtonText 'Dismiss' -ButtonActivationType 'Dismiss'

            $result.ButtonText | Should -Be 'Dismiss'
            $result.ButtonArguments | Should -Be $null
            $result.ButtonActivationType | Should -Be 'Dismiss'
        }
    }

    Context 'scenario settings' {
        It 'defaults empty scenarios to Default' {
            InModuleScope ToastSql {
                Resolve-ToastScenario -Scenario $null | Should -Be 'Default'
                Resolve-ToastScenario -Scenario '   ' | Should -Be 'Default'
            }
        }

        It 'normalizes scenario values case-insensitively' {
            InModuleScope ToastSql {
                Resolve-ToastScenario -Scenario 'reminder' | Should -Be 'Reminder'
            }
        }

        It 'rejects unsupported scenario values' {
            InModuleScope ToastSql {
                { Resolve-ToastScenario -Scenario 'Persistent' } | Should -Throw '*Scenario must be one of*'
            }
        }
    }

    Context 'display mode settings' {
        It 'defaults empty display modes to AppDeployToolkit' {
            InModuleScope ToastSql {
                Resolve-ToastDisplayMode -DisplayMode $null | Should -Be 'AppDeployToolkit'
                Resolve-ToastDisplayMode -DisplayMode '   ' | Should -Be 'AppDeployToolkit'
            }
        }

        It 'normalizes AppDeployToolkit case-insensitively' {
            InModuleScope ToastSql {
                Resolve-ToastDisplayMode -DisplayMode 'appdeploytoolkit' | Should -Be 'AppDeployToolkit'
            }
        }

        It 'rejects unsupported display mode values' {
            InModuleScope ToastSql {
                { Resolve-ToastDisplayMode -DisplayMode 'BurntToast' } | Should -Throw '*DisplayMode must be one of*'
            }
        }
    }

    Context 'AppDeployToolkit helper settings' {
        It 'normalizes AppDeployToolkit protocol buttons and enforces the safe URI allowlist' {
            InModuleScope ToastSql {
                $result = Resolve-ToastAppDeployToolkitButtonSettings `
                    -ButtonText 'Open details' `
                    -ButtonArguments ' https://example.com/details ' `
                    -ButtonActivationType 'Protocol'

                $result.ButtonText | Should -Be 'Open details'
                $result.ButtonArguments | Should -Be 'https://example.com/details'
                $result.ButtonActivationType | Should -Be 'Protocol'
                $result.ProtocolUri.AbsoluteUri | Should -Be 'https://example.com/details'
            }
        }

        It 'rejects AppDeployToolkit protocol buttons with unsupported URI schemes' {
            InModuleScope ToastSql {
                {
                    Resolve-ToastAppDeployToolkitButtonSettings `
                        -ButtonText 'Open file' `
                        -ButtonArguments 'file:///C:/Windows/System32/notepad.exe' `
                        -ButtonActivationType 'Protocol'
                } | Should -Throw '*http, https, or mailto*'
            }
        }

        It 'rejects AppDeployToolkit protocol buttons with relative URIs' {
            InModuleScope ToastSql {
                {
                    Resolve-ToastAppDeployToolkitButtonSettings `
                        -ButtonText 'Open page' `
                        -ButtonArguments '/relative/path' `
                        -ButtonActivationType 'Protocol'
                } | Should -Throw '*absolute URI*'
            }
        }

        It 'maps AppDeployToolkit prompt results to action and acknowledgement outcomes' {
            InModuleScope ToastSql {
                Resolve-ToastAppDeployToolkitPromptSelection -Result 'Left' -ActionButtonText 'Open' | Should -Be 'Action'
                Resolve-ToastAppDeployToolkitPromptSelection -Result 'Primary' -ActionButtonText 'Open' | Should -Be 'Action'
                Resolve-ToastAppDeployToolkitPromptSelection -Result 0 -ActionButtonText 'Open' | Should -Be 'Action'
                Resolve-ToastAppDeployToolkitPromptSelection -Result 'Acknowledge' -ActionButtonText 'Open' | Should -Be 'Acknowledge'
                Resolve-ToastAppDeployToolkitPromptSelection -Result 'Right' -ActionButtonText 'Open' | Should -Be 'Acknowledge'
                Resolve-ToastAppDeployToolkitPromptSelection -Result 1 -ActionButtonText 'Open' | Should -Be 'Acknowledge'
            }
        }

        It 'uses a safe subtitle fallback when the toast title is blank' {
            InModuleScope ToastSql {
                Get-ToastAppDeployToolkitSubtitle -Body "`r`n  First line  `r`nSecond line" | Should -Be 'First line'
                Get-ToastAppDeployToolkitSubtitle -Body '' | Should -Be 'Notification'
            }
        }

        It 'normalizes custom acknowledgement button text and treats blanks as the default' {
            Resolve-ToastAcknowledgeButtonText -AcknowledgeButtonText '  Stäng  ' | Should -Be 'Stäng'
            Resolve-ToastAcknowledgeButtonText -AcknowledgeButtonText '   ' | Should -Be $null
            Resolve-ToastAcknowledgeButtonText -AcknowledgeButtonText $null | Should -Be $null
            Resolve-ToastAcknowledgeButtonText -AcknowledgeButtonText 'Stäng' -ButtonText 'Öppna GitHub' | Should -Be 'Stäng'
        }

        It 'rejects acknowledgement button text that collides with the action button text or is too long' {
            { Resolve-ToastAcknowledgeButtonText -AcknowledgeButtonText 'open' -ButtonText ' Open ' } | Should -Throw '*must differ from ButtonText*'
            { Resolve-ToastAcknowledgeButtonText -AcknowledgeButtonText ('x' * 201) } | Should -Throw '*200 characters*'
        }

        It 'rejects AppDeployToolkit protocol buttons with invalid or host-less URIs' {
            InModuleScope ToastSql {
                foreach ($invalidUri in @('www.github.com', 'not a uri', '{"url":"not a uri"}')) {
                    {
                        Resolve-ToastAppDeployToolkitButtonSettings `
                            -ButtonText 'Öppna GitHub' `
                            -ButtonArguments $invalidUri `
                            -ButtonActivationType 'Protocol'
                    } | Should -Throw '*absolute URI*'
                }
            }
        }

        It 'accepts JSON url protocol buttons on the client and resolves them to the raw URL' {
            InModuleScope ToastSql {
                $result = Resolve-ToastAppDeployToolkitButtonSettings `
                    -ButtonText 'Öppna GitHub' `
                    -ButtonArguments '{"url":"https://github.com/DambergC/BurntToast-SQLserver/tree/main"}' `
                    -ButtonActivationType 'Protocol'

                $result.ButtonArguments | Should -Be 'https://github.com/DambergC/BurntToast-SQLserver/tree/main'
                $result.ProtocolUri.AbsoluteUri | Should -Be 'https://github.com/DambergC/BurntToast-SQLserver/tree/main'
            }
        }

        It 'maps the bundled PSAppDeployToolkit Show-ADTInstallationPrompt return values (clicked button text or Timeout)' {
            InModuleScope ToastSql {
                Resolve-ToastAppDeployToolkitPromptSelection -Result 'Öppna GitHub' -ActionButtonText 'Öppna GitHub' -AcknowledgeButtonText 'Stäng' | Should -Be 'Action'
                Resolve-ToastAppDeployToolkitPromptSelection -Result 'Stäng' -ActionButtonText 'Öppna GitHub' -AcknowledgeButtonText 'Stäng' | Should -Be 'Acknowledge'
                Resolve-ToastAppDeployToolkitPromptSelection -Result 'Timeout' -ActionButtonText 'Öppna GitHub' -AcknowledgeButtonText 'Stäng' | Should -Be 'Timeout'
                Resolve-ToastAppDeployToolkitPromptSelection -Result $null -ActionButtonText 'Öppna GitHub' -AcknowledgeButtonText 'Stäng' | Should -Be 'Unknown'
                Resolve-ToastAppDeployToolkitPromptSelection -Result 'Unexpected result' -ActionButtonText 'Open' | Should -Be 'Unknown'
            }

            # Bundled version documents that the clicked button's text is returned.
            $bundledToolkitModule = Get-ChildItem -Path (Join-Path $PSScriptRoot '..\Dependencies\PSAppDeployToolkit') -Filter 'PSAppDeployToolkit.psm1' -Recurse | Select-Object -First 1
            $bundledToolkitText = Get-Content -Path $bundledToolkitModule.FullName -Raw
            $bundledToolkitText | Should -Match 'The return value of the button clicked by the user is the button text specified'
            $bundledToolkitText | Should -Match "\[System\.String\]\`$ButtonLeftText"
            $bundledToolkitText | Should -Match "\[System\.String\]\`$ButtonRightText"
        }

        It 'maps custom acknowledgement button text results to acknowledgement' {
            InModuleScope ToastSql {
                Resolve-ToastAppDeployToolkitPromptSelection -Result 'Stäng' -ActionButtonText 'Öppna GitHub' -AcknowledgeButtonText 'Stäng' | Should -Be 'Acknowledge'
                Resolve-ToastAppDeployToolkitPromptSelection -Result 'Öppna GitHub' -ActionButtonText 'Öppna GitHub' -AcknowledgeButtonText 'Stäng' | Should -Be 'Action'
            }
        }

        It 'defines a nullable AcknowledgeButtonText SQL parameter with the ButtonText column size' {
            InModuleScope ToastSql {
                $script:ToastSqlNullParameterDefinitions.AcknowledgeButtonText.SqlDbType | Should -Be ([System.Data.SqlDbType]::NVarChar)
                $script:ToastSqlNullParameterDefinitions.AcknowledgeButtonText.Size | Should -Be 200
            }
        }

        It 'defines a nullable Subtitle SQL parameter with the Title column size' {
            InModuleScope ToastSql {
                $script:ToastSqlNullParameterDefinitions.Subtitle.SqlDbType | Should -Be ([System.Data.SqlDbType]::NVarChar)
                $script:ToastSqlNullParameterDefinitions.Subtitle.Size | Should -Be 200
            }
        }

        It 'launches protocol actions in the user context via Start-ADTProcessAsUser and the default handler' {
            InModuleScope ToastSql {
                function Start-ADTProcessAsUser { param([string]$FilePath, [string[]]$ArgumentList, [switch]$NoWait) }
                Mock Test-ToastInteractiveUserSession { $false }
                Mock Start-ADTProcessAsUser {}
                Mock Start-Process {}

                try {
                    Invoke-ToastProtocolAction -ButtonArguments 'https://github.com/DambergC/BurntToast-SQLserver' | Should -Be $null
                    Should -Invoke Start-ADTProcessAsUser -Times 1 -Exactly -ParameterFilter {
                        $FilePath -like '*explorer.exe' -and
                        $FilePath -notmatch 'msedge' -and
                        $ArgumentList.Count -eq 1 -and
                        $ArgumentList[0] -eq 'https://github.com/DambergC/BurntToast-SQLserver' -and
                        $NoWait
                    }
                    Should -Invoke Start-Process -Times 0
                } finally {
                    Remove-Item Function:\Start-ADTProcessAsUser -ErrorAction SilentlyContinue
                }
            }
        }

        It 'uses only Start-ADTProcessAsUser parameters supported by the bundled PSAppDeployToolkit version' {
            $bundledToolkitModule = Get-ChildItem -Path (Join-Path $PSScriptRoot '..\Dependencies\PSAppDeployToolkit') -Filter 'PSAppDeployToolkit.psm1' -Recurse | Select-Object -First 1
            $bundledToolkitModule | Should -Not -BeNullOrEmpty

            $toolkitAst = [System.Management.Automation.Language.Parser]::ParseFile($bundledToolkitModule.FullName, [ref]$null, [ref]$null)
            $startAsUserDefinition = $toolkitAst.Find({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Start-ADTProcessAsUser'
            }, $true)
            $startAsUserDefinition | Should -Not -BeNullOrEmpty

            $supportedParameterNames = @($startAsUserDefinition.Body.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
            foreach ($parameterName in @('FilePath', 'ArgumentList', 'NoWait')) {
                $supportedParameterNames | Should -Contain $parameterName
            }
        }

        It 'launches mailto protocol actions via Start-ADTProcessAsUser' {
            InModuleScope ToastSql {
                function Start-ADTProcessAsUser { param([string]$FilePath, [string[]]$ArgumentList, [switch]$NoWait) }
                Mock Test-ToastInteractiveUserSession { $false }
                Mock Start-ADTProcessAsUser {}

                try {
                    Invoke-ToastProtocolAction -ButtonArguments 'mailto:support@contoso.example' | Should -Be $null
                    Should -Invoke Start-ADTProcessAsUser -Times 1 -Exactly -ParameterFilter {
                        $FilePath -like '*explorer.exe' -and $ArgumentList[0] -eq 'mailto:support@contoso.example' -and $NoWait
                    }
                } finally {
                    Remove-Item Function:\Start-ADTProcessAsUser -ErrorAction SilentlyContinue
                }
            }
        }

        It 'returns an error message when Start-ADTProcessAsUser fails to start the protocol action' {
            InModuleScope ToastSql {
                function Start-ADTProcessAsUser { param([string]$FilePath, [string[]]$ArgumentList, [switch]$NoWait) }
                Mock Test-ToastInteractiveUserSession { $false }
                Mock Start-ADTProcessAsUser { throw 'boom' }

                try {
                    (Invoke-ToastProtocolAction -ButtonArguments 'https://example.com') | Should -Match 'boom'
                } finally {
                    Remove-Item Function:\Start-ADTProcessAsUser -ErrorAction SilentlyContinue
                }
            }
        }

        It 'rejects invalid, relative, or unsupported URIs in the protocol launcher without starting a process' {
            InModuleScope ToastSql {
                function Start-ADTProcessAsUser { param([string]$FilePath, [string[]]$ArgumentList, [switch]$NoWait) }
                Mock Test-ToastInteractiveUserSession { $false }
                Mock Start-ADTProcessAsUser {}
                Mock Start-Process {}

                try {
                    foreach ($invalidUri in @('/intranet/status', 'www.contoso.com', 'ftp://files.example.com/file', '{"url":"ftp://files.example.com/file"}')) {
                        (Invoke-ToastProtocolAction -ButtonArguments $invalidUri) | Should -Match 'http, https, or mailto'
                    }
                    (Invoke-ToastProtocolAction -ButtonArguments '{"url":') | Should -Match 'malformed JSON'
                    (Invoke-ToastProtocolAction -ButtonArguments '{"link":"https://example.com"}') | Should -Match "non-empty string 'url'"
                    Should -Invoke Start-ADTProcessAsUser -Times 0
                    Should -Invoke Start-Process -Times 0
                } finally {
                    Remove-Item Function:\Start-ADTProcessAsUser -ErrorAction SilentlyContinue
                }
            }
        }

        It 'opens the URL with Start-Process when already running in the interactive user session' {
            InModuleScope ToastSql {
                function Start-ADTProcessAsUser { param([string]$FilePath, [string[]]$ArgumentList, [switch]$NoWait) }
                Mock Test-ToastInteractiveUserSession { $true }
                Mock Start-ADTProcessAsUser {}
                Mock Start-Process {}

                try {
                    Invoke-ToastProtocolAction -ButtonArguments 'https://github.com/DambergC/BurntToast-SQLserver/tree/main' | Should -Be $null
                    Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter {
                        $FilePath -eq 'https://github.com/DambergC/BurntToast-SQLserver/tree/main'
                    }
                    Should -Invoke Start-ADTProcessAsUser -Times 0
                } finally {
                    Remove-Item Function:\Start-ADTProcessAsUser -ErrorAction SilentlyContinue
                }
            }
        }

        It 'launches a JSON url protocol action with the raw URL via Start-ADTProcessAsUser when running as SYSTEM' {
            InModuleScope ToastSql {
                function Start-ADTProcessAsUser { param([string]$FilePath, [string[]]$ArgumentList, [switch]$NoWait) }
                Mock Test-ToastInteractiveUserSession { $false }
                Mock Start-ADTProcessAsUser {}
                Mock Start-Process {}

                try {
                    Invoke-ToastProtocolAction -ButtonArguments '{"url":"https://github.com/DambergC/BurntToast-SQLserver/tree/main"}' | Should -Be $null
                    Should -Invoke Start-ADTProcessAsUser -Times 1 -Exactly -ParameterFilter {
                        $FilePath -like '*explorer.exe' -and
                        $ArgumentList.Count -eq 1 -and
                        $ArgumentList[0] -eq 'https://github.com/DambergC/BurntToast-SQLserver/tree/main' -and
                        $NoWait
                    }
                    Should -Invoke Start-Process -Times 0
                } finally {
                    Remove-Item Function:\Start-ADTProcessAsUser -ErrorAction SilentlyContinue
                }
            }
        }

        It 'returns and logs an error instead of silently succeeding when running outside the user session without Start-ADTProcessAsUser' {
            InModuleScope ToastSql {
                Mock Test-ToastInteractiveUserSession { $false }
                Mock Get-Command { $null } -ParameterFilter { $Name -eq 'Start-ADTProcessAsUser' }
                Mock Start-Process {}

                $launchError = Invoke-ToastProtocolAction -ButtonArguments 'https://example.com' -WarningVariable launchWarnings -WarningAction SilentlyContinue
                $launchError | Should -Match 'Start-ADTProcessAsUser'
                Should -Invoke Start-Process -Times 0
                ($launchWarnings -join ' ') | Should -Match 'Failed to open protocol action'
            }
        }

        It 'returns and logs Start-Process failures in the interactive user session' {
            InModuleScope ToastSql {
                Mock Test-ToastInteractiveUserSession { $true }
                Mock Start-Process { throw 'no handler' }

                $launchError = Invoke-ToastProtocolAction -ButtonArguments 'https://example.com' -WarningVariable launchWarnings -WarningAction SilentlyContinue
                $launchError | Should -Match 'no handler'
                ($launchWarnings -join ' ') | Should -Match 'no handler'
            }
        }
    }

    Context 'AppDeployToolkit prompt construction' {
        It 'passes an explicit Subtitle separately from Title when Subtitle is required' {
            InModuleScope ToastSql {
                function Show-ADTInstallationPrompt {
                    param(
                        [string]$Title,
                        [Parameter(Mandatory)][string]$Subtitle,
                        [string]$Message,
                        [string]$ButtonRightText,
                        [string]$Icon
                    )

                    $script:capturedPromptParameters = $PSBoundParameters
                    'Acknowledge'
                }

                try {
                    $result = Show-ToastAppDeployToolkitPrompt -MessageId 42 -Title 'Toast title' -Subtitle 'Toast subtitle' -Body 'Toast body'

                    $result.ResultType | Should -Be 'Acknowledge'
                    $script:capturedPromptParameters.Title | Should -Be 'Toast title'
                    $script:capturedPromptParameters.Subtitle | Should -Be 'Toast subtitle'
                    $script:capturedPromptParameters.Message | Should -Be 'Toast body'
                    $script:capturedPromptParameters.ButtonRightText | Should -Be 'Acknowledge'
                } finally {
                    Remove-Item Function:\Show-ADTInstallationPrompt -ErrorAction SilentlyContinue
                    Remove-Variable -Name capturedPromptParameters -Scope Script -ErrorAction SilentlyContinue
                }
            }
        }

        It 'uses the body-derived fallback rather than Title when a required Subtitle is omitted' {
            InModuleScope ToastSql {
                function Show-ADTInstallationPrompt {
                    param(
                        [string]$Title,
                        [Parameter(Mandatory)][string]$Subtitle,
                        [string]$Message,
                        [string]$ButtonRightText,
                        [string]$Icon
                    )

                    $script:capturedPromptParameters = $PSBoundParameters
                    'Acknowledge'
                }

                try {
                    Show-ToastAppDeployToolkitPrompt -MessageId 42 -Title 'Toast title' -Body "`r`nBody subtitle`nMore body" | Out-Null

                    $script:capturedPromptParameters.Title | Should -Be 'Toast title'
                    $script:capturedPromptParameters.Subtitle | Should -Be 'Body subtitle'
                    $script:capturedPromptParameters.Message | Should -Be "`r`nBody subtitle`nMore body"
                } finally {
                    Remove-Item Function:\Show-ADTInstallationPrompt -ErrorAction SilentlyContinue
                    Remove-Variable -Name capturedPromptParameters -Scope Script -ErrorAction SilentlyContinue
                }
            }
        }

        It 'does not duplicate the title into Subtitle when Subtitle is optional' {
            InModuleScope ToastSql {
                function Show-ADTInstallationPrompt {
                    param(
                        [string]$Title,
                        [string]$Subtitle,
                        [string]$Message,
                        [string]$ButtonRightText,
                        [string]$Icon
                    )

                    $script:capturedPromptParameters = $PSBoundParameters
                    'Acknowledge'
                }

                try {
                    $result = Show-ToastAppDeployToolkitPrompt -MessageId 42 -Title 'Toast title' -Body 'Toast body'

                    $result.ResultType | Should -Be 'Acknowledge'
                    $script:capturedPromptParameters.Title | Should -Be 'Toast title'
                    $script:capturedPromptParameters.ContainsKey('Subtitle') | Should -BeFalse
                    $script:capturedPromptParameters.Message | Should -Be 'Toast body'
                } finally {
                    Remove-Item Function:\Show-ADTInstallationPrompt -ErrorAction SilentlyContinue
                    Remove-Variable -Name capturedPromptParameters -Scope Script -ErrorAction SilentlyContinue
                }
            }
        }

        It 'passes an explicit Subtitle when the prompt supports an optional Subtitle' {
            InModuleScope ToastSql {
                function Show-ADTInstallationPrompt {
                    param(
                        [string]$Title,
                        [string]$Subtitle,
                        [string]$Message,
                        [string]$ButtonRightText,
                        [string]$Icon
                    )

                    $script:capturedPromptParameters = $PSBoundParameters
                    'Acknowledge'
                }

                try {
                    Show-ToastAppDeployToolkitPrompt -MessageId 42 -Title 'Toast title' -Subtitle 'Toast subtitle' -Body 'Toast body' | Out-Null

                    $script:capturedPromptParameters.Title | Should -Be 'Toast title'
                    $script:capturedPromptParameters.Subtitle | Should -Be 'Toast subtitle'
                    $script:capturedPromptParameters.Message | Should -Be 'Toast body'
                } finally {
                    Remove-Item Function:\Show-ADTInstallationPrompt -ErrorAction SilentlyContinue
                    Remove-Variable -Name capturedPromptParameters -Scope Script -ErrorAction SilentlyContinue
                }
            }
        }

        It 'treats a blank explicit Subtitle as absent for an optional prompt parameter' {
            InModuleScope ToastSql {
                function Show-ADTInstallationPrompt {
                    param(
                        [string]$Title,
                        [string]$Subtitle,
                        [string]$Message,
                        [string]$ButtonRightText,
                        [string]$Icon
                    )

                    $script:capturedPromptParameters = $PSBoundParameters
                    'Acknowledge'
                }

                try {
                    Show-ToastAppDeployToolkitPrompt -MessageId 42 -Title 'Toast title' -Subtitle '  ' -Body 'Toast body' | Out-Null
                    $script:capturedPromptParameters.ContainsKey('Subtitle') | Should -BeFalse
                } finally {
                    Remove-Item Function:\Show-ADTInstallationPrompt -ErrorAction SilentlyContinue
                    Remove-Variable -Name capturedPromptParameters -Scope Script -ErrorAction SilentlyContinue
                }
            }
        }

        It 'does not pass Subtitle to older prompt variants that do not support it' {
            InModuleScope ToastSql {
                function Show-InstallationPrompt {
                    param(
                        [string]$Title,
                        [string]$Message,
                        [string]$ButtonRightText,
                        [string]$Icon
                    )

                    $script:capturedPromptParameters = $PSBoundParameters
                    'Acknowledge'
                }

                try {
                    $result = Show-ToastAppDeployToolkitPrompt -MessageId 42 -Title 'Toast title' -Subtitle 'Toast subtitle' -Body 'Toast body'

                    $result.ResultType | Should -Be 'Acknowledge'
                    $script:capturedPromptParameters.Title | Should -Be 'Toast title'
                    $script:capturedPromptParameters.Message | Should -Be 'Toast body'
                    $script:capturedPromptParameters.ContainsKey('Subtitle') | Should -BeFalse
                } finally {
                    Remove-Item Function:\Show-InstallationPrompt -ErrorAction SilentlyContinue
                    Remove-Variable -Name capturedPromptParameters -Scope Script -ErrorAction SilentlyContinue
                }
            }
        }

        It 'uses the body as a subtitle fallback when Subtitle is supported and Title is blank' {
            InModuleScope ToastSql {
                function Show-ADTInstallationPrompt {
                    param(
                        [string]$Title,
                        [Parameter(Mandatory)][string]$Subtitle,
                        [string]$Message,
                        [string]$ButtonRightText,
                        [string]$Icon
                    )

                    $script:capturedPromptParameters = $PSBoundParameters
                    'Acknowledge'
                }

                try {
                    $body = "`r`nFirst body line`r`nSecond body line"
                    Show-ToastAppDeployToolkitPrompt -MessageId 42 -Title '' -Body $body | Out-Null

                    $script:capturedPromptParameters.ContainsKey('Title') | Should -BeFalse
                    $script:capturedPromptParameters.Subtitle | Should -Be 'First body line'
                    $script:capturedPromptParameters.Message | Should -Be $body
                } finally {
                    Remove-Item Function:\Show-ADTInstallationPrompt -ErrorAction SilentlyContinue
                    Remove-Variable -Name capturedPromptParameters -Scope Script -ErrorAction SilentlyContinue
                }
            }
        }

        It 'launches the protocol action only when the action button is selected' {
            InModuleScope ToastSql {
                function Show-ADTInstallationPrompt {
                    param(
                        [string]$Title,
                        [string]$Subtitle,
                        [string]$Message,
                        [string]$ButtonLeftText,
                        [string]$ButtonRightText,
                        [string]$Icon
                    )

                    'Left'
                }

                function Start-ADTProcessAsUser { param([string]$FilePath, [string[]]$ArgumentList, [switch]$NoWait) }
                Mock Test-ToastInteractiveUserSession { $false }
                Mock Start-ADTProcessAsUser {}

                try {
                    $result = Show-ToastAppDeployToolkitPrompt `
                        -MessageId 42 `
                        -Title 'Toast title' `
                        -Body 'Toast body' `
                        -ButtonText 'Open' `
                        -ButtonArguments 'https://example.com/details' `
                        -ButtonActivationType 'Protocol'

                    $result.Selection | Should -Be 'Action'
                    $result.ResultType | Should -Be 'Action'
                    Should -Invoke Start-ADTProcessAsUser -Times 1 -ParameterFilter { $FilePath -like '*explorer.exe' -and $ArgumentList[0] -eq 'https://example.com/details' -and $NoWait }
                } finally {
                    Remove-Item Function:\Show-ADTInstallationPrompt -ErrorAction SilentlyContinue
                }
            }
        }

        It 'treats acknowledgement selections as acknowledgement without launching the protocol action' {
            InModuleScope ToastSql {
                function Show-ADTInstallationPrompt {
                    param(
                        [string]$Title,
                        [string]$Subtitle,
                        [string]$Message,
                        [string]$ButtonLeftText,
                        [string]$ButtonRightText,
                        [string]$Icon
                    )

                    'Right'
                }

                function Start-ADTProcessAsUser { param([string]$FilePath, [string[]]$ArgumentList, [switch]$NoWait) }
                Mock Test-ToastInteractiveUserSession { $false }
                Mock Start-ADTProcessAsUser {}

                try {
                    $result = Show-ToastAppDeployToolkitPrompt `
                        -MessageId 42 `
                        -Title 'Toast title' `
                        -Body 'Toast body' `
                        -ButtonText 'Open' `
                        -ButtonArguments 'https://example.com/details' `
                        -ButtonActivationType 'Protocol'

                    $result.Selection | Should -Be 'Acknowledge'
                    $result.ResultType | Should -Be 'Acknowledge'
                    Should -Invoke Start-ADTProcessAsUser -Times 0
                } finally {
                    Remove-Item Function:\Show-ADTInstallationPrompt -ErrorAction SilentlyContinue
                }
            }
        }

        It 'supports dismiss-style action buttons without launching a protocol' {
            InModuleScope ToastSql {
                function Show-ADTInstallationPrompt {
                    param(
                        [string]$Title,
                        [string]$Subtitle,
                        [string]$Message,
                        [string]$ButtonLeftText,
                        [string]$ButtonRightText,
                        [string]$Icon
                    )

                    'Left'
                }

                function Start-ADTProcessAsUser { param([string]$FilePath, [string[]]$ArgumentList, [switch]$NoWait) }
                Mock Test-ToastInteractiveUserSession { $false }
                Mock Start-ADTProcessAsUser {}

                try {
                    $result = Show-ToastAppDeployToolkitPrompt `
                        -MessageId 42 `
                        -Title 'Toast title' `
                        -Body 'Toast body' `
                        -ButtonText 'Dismiss' `
                        -ButtonActivationType 'Dismiss'

                    $result.Selection | Should -Be 'Action'
                    $result.ResultType | Should -Be 'Dismiss'
                    Should -Invoke Start-ADTProcessAsUser -Times 0
                } finally {
                    Remove-Item Function:\Show-ADTInstallationPrompt -ErrorAction SilentlyContinue
                }
            }
        }

        It 'passes custom acknowledgement text on the right and a separate left protocol button that opens the default browser' {
            InModuleScope ToastSql {
                function Show-ADTInstallationPrompt {
                    param(
                        [string]$Title,
                        [string]$Subtitle,
                        [string]$Message,
                        [string]$ButtonLeftText,
                        [string]$ButtonRightText,
                        [string]$Icon
                    )

                    $script:capturedPromptParameters = $PSBoundParameters
                    $ButtonLeftText
                }

                function Start-ADTProcessAsUser { param([string]$FilePath, [string[]]$ArgumentList, [switch]$NoWait) }
                Mock Test-ToastInteractiveUserSession { $false }
                Mock Start-ADTProcessAsUser {}

                try {
                    $result = Show-ToastAppDeployToolkitPrompt `
                        -MessageId 42 `
                        -Title 'Information' `
                        -Body 'Öppna projektet på GitHub.' `
                        -ButtonText 'Öppna GitHub' `
                        -ButtonArguments 'https://github.com/DambergC/BurntToast-SQLserver' `
                        -ButtonActivationType 'Protocol' `
                        -AcknowledgeButtonText 'Stäng'

                    $script:capturedPromptParameters.ButtonLeftText | Should -Be 'Öppna GitHub'
                    $script:capturedPromptParameters.ButtonRightText | Should -Be 'Stäng'
                    $result.Selection | Should -Be 'Action'
                    $result.ResultType | Should -Be 'Action'
                    Should -Invoke Start-ADTProcessAsUser -Times 1 -ParameterFilter { $FilePath -like '*explorer.exe' -and $ArgumentList[0] -eq 'https://github.com/DambergC/BurntToast-SQLserver' -and $NoWait }
                } finally {
                    Remove-Item Function:\Show-ADTInstallationPrompt -ErrorAction SilentlyContinue
                    Remove-Variable -Name capturedPromptParameters -Scope Script -ErrorAction SilentlyContinue
                }
            }
        }

        It 'treats a click on the custom acknowledgement button as acknowledgement without opening the browser' {
            InModuleScope ToastSql {
                function Show-ADTInstallationPrompt {
                    param(
                        [string]$Title,
                        [string]$Message,
                        [string]$ButtonLeftText,
                        [string]$ButtonRightText
                    )

                    $ButtonRightText
                }

                function Start-ADTProcessAsUser { param([string]$FilePath, [string[]]$ArgumentList, [switch]$NoWait) }
                Mock Test-ToastInteractiveUserSession { $false }
                Mock Start-ADTProcessAsUser {}

                try {
                    $result = Show-ToastAppDeployToolkitPrompt `
                        -MessageId 42 `
                        -Title 'Information' `
                        -Body 'Body' `
                        -ButtonText 'Öppna GitHub' `
                        -ButtonArguments 'https://github.com/DambergC/BurntToast-SQLserver' `
                        -ButtonActivationType 'Protocol' `
                        -AcknowledgeButtonText 'Stäng'

                    $result.Selection | Should -Be 'Acknowledge'
                    $result.ResultType | Should -Be 'Acknowledge'
                    Should -Invoke Start-ADTProcessAsUser -Times 0
                } finally {
                    Remove-Item Function:\Show-ADTInstallationPrompt -ErrorAction SilentlyContinue
                }
            }
        }

        It 'defaults the acknowledgement button text to Acknowledge and omits the left button when no action is configured' {
            InModuleScope ToastSql {
                function Show-ADTInstallationPrompt {
                    param(
                        [string]$Title,
                        [string]$Message,
                        [string]$ButtonLeftText,
                        [string]$ButtonRightText
                    )

                    $script:capturedPromptParameters = $PSBoundParameters
                    'Acknowledge'
                }

                try {
                    $result = Show-ToastAppDeployToolkitPrompt -MessageId 42 -Title 'Title' -Body 'Body' -AcknowledgeButtonText '  '

                    $result.ResultType | Should -Be 'Acknowledge'
                    $script:capturedPromptParameters.ButtonRightText | Should -Be 'Acknowledge'
                    $script:capturedPromptParameters.ContainsKey('ButtonLeftText') | Should -BeFalse
                } finally {
                    Remove-Item Function:\Show-ADTInstallationPrompt -ErrorAction SilentlyContinue
                    Remove-Variable -Name capturedPromptParameters -Scope Script -ErrorAction SilentlyContinue
                }
            }
        }

        It 'passes custom acknowledgement text and a dismiss action button to older Show-InstallationPrompt variants' {
            InModuleScope ToastSql {
                function Show-InstallationPrompt {
                    param(
                        [string]$Title,
                        [string]$Message,
                        [string]$ButtonLeftText,
                        [string]$ButtonRightText,
                        [string]$Icon
                    )

                    $script:capturedPromptParameters = $PSBoundParameters
                    $ButtonLeftText
                }

                function Start-ADTProcessAsUser { param([string]$FilePath, [string[]]$ArgumentList, [switch]$NoWait) }
                Mock Test-ToastInteractiveUserSession { $false }
                Mock Start-ADTProcessAsUser {}

                try {
                    $result = Show-ToastAppDeployToolkitPrompt `
                        -MessageId 42 `
                        -Title 'Title' `
                        -Body 'Body' `
                        -ButtonText 'Senare' `
                        -ButtonActivationType 'Dismiss' `
                        -AcknowledgeButtonText 'Stäng'

                    $script:capturedPromptParameters.ButtonLeftText | Should -Be 'Senare'
                    $script:capturedPromptParameters.ButtonRightText | Should -Be 'Stäng'
                    $result.ResultType | Should -Be 'Dismiss'
                    Should -Invoke Start-ADTProcessAsUser -Times 0
                } finally {
                    Remove-Item Function:\Show-InstallationPrompt -ErrorAction SilentlyContinue
                    Remove-Variable -Name capturedPromptParameters -Scope Script -ErrorAction SilentlyContinue
                }
            }
        }

        It 'only passes button parameters supported by the prompt command' {
            InModuleScope ToastSql {
                function Show-InstallationPrompt {
                    param(
                        [string]$Title,
                        [string]$Message
                    )

                    $script:capturedPromptParameters = $PSBoundParameters
                    'OK'
                }

                function Start-ADTProcessAsUser { param([string]$FilePath, [string[]]$ArgumentList, [switch]$NoWait) }
                Mock Test-ToastInteractiveUserSession { $false }
                Mock Start-ADTProcessAsUser {}

                try {
                    $result = Show-ToastAppDeployToolkitPrompt `
                        -MessageId 42 `
                        -Title 'Title' `
                        -Body 'Body' `
                        -ButtonText 'Öppna GitHub' `
                        -ButtonArguments 'https://github.com/DambergC/BurntToast-SQLserver' `
                        -ButtonActivationType 'Protocol' `
                        -AcknowledgeButtonText 'Stäng' `
                        -WarningAction SilentlyContinue

                    $script:capturedPromptParameters.ContainsKey('ButtonLeftText') | Should -BeFalse
                    $script:capturedPromptParameters.ContainsKey('ButtonRightText') | Should -BeFalse
                    $result.ResultType | Should -Be 'Acknowledge'
                    Should -Invoke Start-ADTProcessAsUser -Times 0
                } finally {
                    Remove-Item Function:\Show-InstallationPrompt -ErrorAction SilentlyContinue
                    Remove-Variable -Name capturedPromptParameters -Scope Script -ErrorAction SilentlyContinue
                }
            }
        }

        It 'rejects unsupported protocol URI schemes before showing the prompt' {
            InModuleScope ToastSql {
                function Show-ADTInstallationPrompt {
                    param([string]$Title, [string]$Message, [string]$ButtonLeftText, [string]$ButtonRightText)
                    $script:promptShown = $true
                }

                $script:promptShown = $false
                try {
                    {
                        Show-ToastAppDeployToolkitPrompt `
                            -MessageId 42 `
                            -Title 'Title' `
                            -Body 'Body' `
                            -ButtonText 'Öppna' `
                            -ButtonArguments 'ftp://files.example.com/file' `
                            -ButtonActivationType 'Protocol' `
                            -AcknowledgeButtonText 'Stäng'
                    } | Should -Throw '*http, https, or mailto*'
                    $script:promptShown | Should -BeFalse
                } finally {
                    Remove-Item Function:\Show-ADTInstallationPrompt -ErrorAction SilentlyContinue
                    Remove-Variable -Name promptShown -Scope Script -ErrorAction SilentlyContinue
                }
            }
        }

        It 'surfaces AppDeployToolkit protocol-launch failures instead of treating them as acknowledged' {
            InModuleScope ToastSql {
                function Show-ADTInstallationPrompt {
                    param(
                        [string]$Title,
                        [string]$Subtitle,
                        [string]$Message,
                        [string]$ButtonLeftText,
                        [string]$ButtonRightText,
                        [string]$Icon
                    )

                    'Left'
                }

                Mock Invoke-ToastProtocolAction { 'boom' }

                try {
                    {
                        Show-ToastAppDeployToolkitPrompt `
                            -MessageId 42 `
                            -Title 'Title' `
                            -Body 'Body' `
                            -ButtonText 'Open' `
                            -ButtonArguments 'https://example.com' `
                            -ButtonActivationType 'Protocol'
                    } | Should -Throw '*boom*'
                } finally {
                    Remove-Item Function:\Show-ADTInstallationPrompt -ErrorAction SilentlyContinue
                }
            }
        }
    }

    Context 'Send-ToastMessage public interface and AppDeployToolkit-only behavior' {
        It 'does not expose image or sound parameters on Send-ToastMessage.ps1' {
            $serverScriptPath = Join-Path $PSScriptRoot '..\src\Server\Send-ToastMessage.ps1'
            $command = Get-Command -Name $serverScriptPath
            $parameterNames = $command.Parameters.Keys

            $parameterNames | Should -Not -Contain 'AppLogoPath'
            $parameterNames | Should -Not -Contain 'HeroImagePath'
            $parameterNames | Should -Not -Contain 'AppLogoFilePath'
            $parameterNames | Should -Not -Contain 'HeroImageFilePath'
            $parameterNames | Should -Not -Contain 'AppLogoBytes'
            $parameterNames | Should -Not -Contain 'HeroImageBytes'
            $parameterNames | Should -Not -Contain 'AppLogoContentType'
            $parameterNames | Should -Not -Contain 'HeroImageContentType'
            $parameterNames | Should -Not -Contain 'Sound'
        }

        It 'exposes expected title, body, repeat, button, and AppDeployToolkit parameters on Send-ToastMessage.ps1' {
            $serverScriptPath = Join-Path $PSScriptRoot '..\src\Server\Send-ToastMessage.ps1'
            $command = Get-Command -Name $serverScriptPath
            $parameterNames = $command.Parameters.Keys

            $parameterNames | Should -Contain 'ConfigPath'
            $parameterNames | Should -Contain 'GroupName'
            $parameterNames | Should -Contain 'Title'
            $parameterNames | Should -Contain 'Body'
            $parameterNames | Should -Contain 'Subtitle'
            $parameterNames | Should -Contain 'ExpiresUtc'
            $parameterNames | Should -Contain 'Urgent'
            $parameterNames | Should -Contain 'RepeatIntervalSeconds'
            $parameterNames | Should -Contain 'RepeatIntervalMinutes'
            $parameterNames | Should -Contain 'RepeatCount'
            $parameterNames | Should -Contain 'ButtonText'
            $parameterNames | Should -Contain 'ButtonArguments'
            $parameterNames | Should -Contain 'ButtonActivationType'
            $parameterNames | Should -Contain 'AcknowledgeButtonText'
            $parameterNames | Should -Contain 'Scenario'
            $parameterNames | Should -Contain 'DisplayMode'
        }

        It 'restricts DisplayMode parameter to AppDeployToolkit only and defaults to AppDeployToolkit' {
            $serverScriptPath = Join-Path $PSScriptRoot '..\src\Server\Send-ToastMessage.ps1'
            $command = Get-Command -Name $serverScriptPath
            $displayModeParam = $command.Parameters['DisplayMode']

            $displayModeParam | Should -Not -BeNullOrEmpty
            $validateSet = $displayModeParam.Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] }
            $validateSet.ValidValues | Should -Be @('AppDeployToolkit')
        }

        It 'does not pass image or sound arguments in Send-ToastMessage.ps1 SQL invocation' {
            $serverScriptPath = Join-Path $PSScriptRoot '..\src\Server\Send-ToastMessage.ps1'
            $serverScriptText = Get-Content -Path $serverScriptPath -Raw

            $serverScriptText | Should -Not -Match '@AppLogoPath'
            $serverScriptText | Should -Not -Match '@HeroImagePath'
            $serverScriptText | Should -Not -Match '@AppLogoBytes'
            $serverScriptText | Should -Not -Match '@HeroImageBytes'
            $serverScriptText | Should -Not -Match '@AppLogoContentType'
            $serverScriptText | Should -Not -Match '@HeroImageContentType'
            $serverScriptText | Should -Not -Match '@Sound'
            $serverScriptText | Should -Match '@Subtitle = @Subtitle'
            $serverScriptText | Should -Match '@AcknowledgeButtonText = @AcknowledgeButtonText'
            $serverScriptText | Should -Match 'Resolve-ToastAcknowledgeButtonText'
            $serverScriptText | Should -Not -Match 'Resolve-ToastImageInput'
            $serverScriptText | Should -Not -Match 'Assert-ToastImageResolutionResult'
        }
    }

    Context 'AppDeployToolkit dependency handling' {
        It 'requires an explicit local AppDeployToolkit dependency path when the prompt command is unavailable' {
            InModuleScope ToastSql {
                Set-ToastClientDependencyOptions -AppDeployToolkitModulePath $null

                { Ensure-ToastNotificationDependencies -DisplayMode 'AppDeployToolkit' } |
                    Should -Throw '*AppDeployToolkitModulePath*'
            }
        }

        It 'imports AppDeployToolkit from the configured local dependency path' {
            InModuleScope ToastSql {
                $dependencyRoot = Join-Path ([System.IO.Path]::GetTempPath()) "toastsql-adt-$([guid]::NewGuid().ToString('N'))"
                $dependencyFile = Join-Path $dependencyRoot 'PSAppDeployToolkit.psd1'
                $moduleFile = Join-Path $dependencyRoot 'PSAppDeployToolkit.psm1'

                try {
                    [void][System.IO.Directory]::CreateDirectory($dependencyRoot)
                    @'
function Show-InstallationPrompt {
    param([string]$Message)
}
'@ | Set-Content -Path $moduleFile
                    @"
@{
    RootModule = 'PSAppDeployToolkit.psm1'
    ModuleVersion = '1.0.0'
    GUID = '11111111-1111-1111-1111-111111111111'
}
"@ | Set-Content -Path $dependencyFile
                    Set-ToastClientDependencyOptions -AppDeployToolkitModulePath $dependencyRoot

                    Ensure-ToastNotificationDependencies -DisplayMode 'AppDeployToolkit'
                } finally {
                    Remove-Module PSAppDeployToolkit -ErrorAction SilentlyContinue
                    Remove-Item -LiteralPath $dependencyRoot -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
        }

        It 'supports a direct AppDeployToolkit manifest path' {
            InModuleScope ToastSql {
                $dependencyRoot = Join-Path ([System.IO.Path]::GetTempPath()) "toastsql-adt-file-$([guid]::NewGuid().ToString('N'))"
                $dependencyFile = Join-Path $dependencyRoot 'PSAppDeployToolkit.psd1'
                $moduleFile = Join-Path $dependencyRoot 'PSAppDeployToolkit.psm1'

                try {
                    [void][System.IO.Directory]::CreateDirectory($dependencyRoot)
                    @'
function Show-InstallationPrompt {
    param([string]$Message)
}
'@ | Set-Content -Path $moduleFile
                    @"
@{
    RootModule = 'PSAppDeployToolkit.psm1'
    ModuleVersion = '1.0.0'
    GUID = '33333333-3333-3333-3333-333333333333'
}
"@ | Set-Content -Path $dependencyFile
                    Set-ToastClientDependencyOptions -AppDeployToolkitModulePath $dependencyFile

                    Ensure-ToastNotificationDependencies -DisplayMode 'AppDeployToolkit'
                } finally {
                    Remove-Module PSAppDeployToolkit -ErrorAction SilentlyContinue
                    Remove-Item -LiteralPath $dependencyRoot -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
        }
    }

    Context 'notification rendering' {
        It 'routes toast rows through the AppDeployToolkit prompt' {
            InModuleScope ToastSql {
                Mock Ensure-ToastNotificationDependencies {}
                Mock Show-ToastAppDeployToolkitPrompt { [pscustomobject]@{ Selection = 'Acknowledge'; ResultType = 'Acknowledge' } }

                $row = [pscustomobject]@{
                    MessageId = 42
                    Title = 'Title'
                    Subtitle = 'Subtitle'
                    Body = 'Body'
                    DisplayMode = 'AppDeployToolkit'
                    ButtonText = 'Open'
                    ButtonArguments = 'https://example.com'
                    ButtonActivationType = 'Protocol'
                    AcknowledgeButtonText = 'Stäng'
                }

                Invoke-ToastNotification -ToastRow $row

                Should -Invoke Ensure-ToastNotificationDependencies -Times 1 -ParameterFilter { $DisplayMode -eq 'AppDeployToolkit' }
                Should -Invoke Show-ToastAppDeployToolkitPrompt -Times 1 -ParameterFilter {
                    $MessageId -eq 42 -and
                    $Title -eq 'Title' -and
                    $Subtitle -eq 'Subtitle' -and
                    $Body -eq 'Body' -and
                    $ButtonText -eq 'Open' -and
                    $ButtonArguments -eq 'https://example.com' -and
                    $ButtonActivationType -eq 'Protocol' -and
                    $AcknowledgeButtonText -eq 'Stäng'
                }
            }
        }

        It 'routes legacy rows without AcknowledgeButtonText with an empty acknowledgement label' {
            InModuleScope ToastSql {
                Mock Ensure-ToastNotificationDependencies {}
                Mock Show-ToastAppDeployToolkitPrompt { [pscustomobject]@{ Selection = 'Acknowledge'; ResultType = 'Acknowledge' } }

                $table = [System.Data.DataTable]::new()
                foreach ($columnName in @('MessageId','Title','Body','DisplayMode','AcknowledgeButtonText')) {
                    [void]$table.Columns.Add($columnName)
                }
                $dataRow = $table.NewRow()
                $dataRow['MessageId'] = 42
                $dataRow['Title'] = 'Title'
                $dataRow['Body'] = 'Body'
                $dataRow['DisplayMode'] = 'AppDeployToolkit'
                $dataRow['AcknowledgeButtonText'] = [System.DBNull]::Value
                $table.Rows.Add($dataRow)

                Invoke-ToastNotification -ToastRow $dataRow

                Should -Invoke Show-ToastAppDeployToolkitPrompt -Times 1 -ParameterFilter {
                    [string]::IsNullOrEmpty($AcknowledgeButtonText)
                }
            }
        }

        It 'defaults missing display modes to AppDeployToolkit for queued rows' {
            InModuleScope ToastSql {
                Mock Ensure-ToastNotificationDependencies {}
                Mock Show-ToastAppDeployToolkitPrompt { [pscustomobject]@{ Selection = 'Acknowledge'; ResultType = 'Acknowledge' } }

                $row = [pscustomobject]@{
                    MessageId = 42
                    Title = 'Title'
                    Body = 'Body'
                }

                Invoke-ToastNotification -ToastRow $row

                Should -Invoke Ensure-ToastNotificationDependencies -Times 1
                Should -Invoke Show-ToastAppDeployToolkitPrompt -Times 1
            }
        }

        It 'throws a clear error when queue data contains an unsupported display mode' {
            InModuleScope ToastSql {
                $row = [pscustomobject]@{
                    MessageId = 42
                    Title = 'Title'
                    Body = 'Body'
                    DisplayMode = 'BurntToast'
                }

                { Invoke-ToastNotification -ToastRow $row } | Should -Throw '*DisplayMode must be one of*'
            }
        }
    }

    Context 'registry read state' {
        It 'isolates server database computer and port scopes without a user SID and normalizes name case' {
            $scope = @{ Server = 'sql01'; Port = 1433; Database = 'Toast'; ComputerName = 'PC01' }
            $path = Get-ToastReadStatePath @scope
            $path | Should -Match '^HKLM:\\Software\\AppDeployToolkit-MessengerTool\\ReadState\\[A-F0-9]{64}$'
            (Get-Command Get-ToastReadStatePath).Parameters.Keys | Should -Not -Contain 'UserSid'
            foreach ($key in @('Server','Database','ComputerName','Port')) {
                $changed = $scope.Clone()
                $changed[$key] = if ($key -eq 'Port') { 1434 } else { $scope[$key] + 'other' }
                Get-ToastReadStatePath @changed | Should -Not -Be $path
            }
            $scope.Server = 'SQL01'
            Get-ToastReadStatePath @scope | Should -Be $path
        }

        It 'round trips atomic JSON registry state across independent reads' {
            InModuleScope ToastSql {
                $script:registryValue = $null
                Mock Test-Path { $true }
                Mock New-ItemProperty { $script:registryValue = $Value }
                Mock Get-ItemProperty { [pscustomobject]@{ '42' = $script:registryValue } }
                $next = [datetime]::UtcNow.AddMinutes(5)
                Set-ToastReadState -StatePath 'HKLM:\Test' -MessageId 42 -State ([pscustomobject]@{ Read = $true; ShowCount = 2; NextShowUtc = $next })
                $state = Get-ToastReadState -StatePath 'HKLM:\Test' -MessageId 42
                $state.Read | Should -BeTrue
                $state.ShowCount | Should -Be 2
                $state.NextShowUtc.ToString('o') | Should -Be $next.ToString('o')
                (Get-ToastReadState -StatePath 'HKLM:\Test' -MessageId 42).ShowCount | Should -Be 2
                Should -Invoke New-ItemProperty -Times 1 -ParameterFilter { $Name -eq '42' -and $PropertyType -eq 'String' -and $ErrorAction -eq 'Stop' }
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

        It 'requires administrator provisioning instead of creating the machine root or falling back' {
            InModuleScope ToastSql {
                Mock Test-Path { $false }
                Mock New-Item {}
                { Set-ToastReadState -StatePath 'HKLM:\Software\AppDeployToolkit-MessengerTool\ReadState\scope' -MessageId 42 -State ([pscustomobject]@{ Read = $false; ShowCount = 0; NextShowUtc = $null }) } |
                    Should -Throw '*administrator must run deploy/Initialize-ToastReadState.ps1*'
                Should -Invoke New-Item -Times 0
            }
        }

        It 'creates only the scope below a provisioned root and propagates denied writes' {
            InModuleScope ToastSql {
                Mock Test-Path { $LiteralPath -eq 'HKLM:\Software\AppDeployToolkit-MessengerTool\ReadState' }
                Mock New-Item {}
                Mock New-ItemProperty { throw 'Access denied' }
                $path = 'HKLM:\Software\AppDeployToolkit-MessengerTool\ReadState\scope'
                { Set-ToastReadState -StatePath $path -MessageId 42 -State ([pscustomobject]@{ Read = $false; ShowCount = 0; NextShowUtc = $null }) } |
                    Should -Throw '*Access denied*'
                Should -Invoke New-Item -Times 1 -ParameterFilter { $Path -eq 'HKLM:\Software\AppDeployToolkit-MessengerTool\ReadState\scope' -and -not $Force }
                Should -Invoke New-ItemProperty -Times 1 -ParameterFilter { $LiteralPath -eq 'HKLM:\Software\AppDeployToolkit-MessengerTool\ReadState\scope' }
            }
        }

        It 'limits provisioning to the 64-bit machine read-state subtree and interactive data rights' {
            $text = Get-Content "$PSScriptRoot/../deploy/Initialize-ToastReadState.ps1" -Raw
            $text | Should -Match '#Requires -RunAsAdministrator'
            $text | Should -Match 'Is64BitProcess'
            $text | Should -Match ([regex]::Escape("`$path = 'HKLM:\Software\AppDeployToolkit-MessengerTool\ReadState'"))
            $text | Should -Match "SecurityIdentifier\]::new\('S-1-5-4'\)"
            $text | Should -Match 'RegistryRights\]::ReadKey'
            $text | Should -Match 'RegistryRights\]::SetValue'
            $text | Should -Match 'RegistryRights\]::CreateSubKey'
            $text | Should -Match 'InheritanceFlags\]::ContainerInherit'
            $text | Should -Match 'Set-Acl -LiteralPath \$path'
            $text | Should -Not -Match 'FullControl|ChangePermissions|TakeOwnership|HKCU:'
            $module = Get-Content "$PSScriptRoot/../src/Module/ToastSql.psm1" -Raw
            $module | Should -Match 'function Assert-ToastRegistryArchitecture'
            $module | Should -Match 'if \(-not \[Environment\]::Is64BitProcess\)'
            $module | Should -Not -Match 'HKCU:|UserSid'
        }
    }

    Context 'machine-wide polling concurrency' {
        BeforeEach {
            InModuleScope ToastSql {
                $script:lockAvailable = $true
                $script:releaseCount = 0
                $script:disposeCount = 0
                $script:passArgs = @{ ConnectionString = 'test'; ComputerName = 'PC01'; StatePath = 'HKLM:\Software\AppDeployToolkit-MessengerTool\ReadState\scope' }
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

        It 'skips a busy scope but allows a later session pass and releases before sleep' {
            InModuleScope ToastSql {
                $script:lockAvailable = $false
                Invoke-ToastClientPass @script:passArgs
                Should -Invoke Invoke-ToastClientPoll -Times 0
                $script:releaseCount | Should -Be 0
                $script:lockAvailable = $true
                Invoke-ToastClientPass @script:passArgs
                Should -Invoke Invoke-ToastClientPoll -Times 1
                Should -Invoke New-ToastClientMutex -Times 2 -ParameterFilter { $Name -eq 'Global\ToastSql-scope' }
                $script:releaseCount | Should -Be 1
                $script:disposeCount | Should -Be 2
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

        It 'grants cross-user synchronize and release rights with framework-specific built-in APIs' {
            $text = Get-Content "$PSScriptRoot/../src/Module/ToastSql.psm1" -Raw
            $text | Should -Match 'MutexRights\]::Synchronize'
            $text | Should -Match 'MutexRights\]::Modify'
            $text | Should -Match "SecurityIdentifier\]::new\('S-1-5-4'\)"
            $text | Should -Match 'MutexAccessRule'
            $text | Should -Match 'System.Threading.MutexAcl\]::Create'
            $text | Should -Match '\$mutexType::OpenExisting\(\$Name, \$rights\)'
            $text | Should -Match 'catch \[System.UnauthorizedAccessException\]'
        }
    }

    Context 'read-only client polling' {
        BeforeEach {
            InModuleScope ToastSql {
                $script:pollRows = @([pscustomobject]@{ MessageId = 42; RepeatCount = $null; RepeatIntervalSeconds = $null })
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

        It 'suppresses an acknowledged one-time message on later polls without database writes' {
            InModuleScope ToastSql {
                Invoke-ToastClientPoll @script:pollArgs
                Invoke-ToastClientPoll @script:pollArgs
                $script:localStates[42L].Read | Should -BeTrue
                $script:localStates[42L].ShowCount | Should -Be 1
                Should -Invoke Invoke-ToastNotification -Times 1
                Should -Invoke Invoke-ToastSql -Times 3 -Exactly -ParameterFilter { -not $NonQuery -and $CommandText -eq 'EXEC dbo.usp_GetPendingToast @ComputerName, @MessageId' }
            }
        }

        It 'persists repeat schedule and count and stops after the configured total' {
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

        It 'does not acknowledge timeout null or unknown prompt outcomes' {
            InModuleScope ToastSql {
                foreach ($outcome in @('Timeout','Unknown')) {
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

        It 'leaves render and protocol failures unread but continues with other messages' {
            InModuleScope ToastSql {
                $script:pollRows += [pscustomobject]@{ MessageId = 43; RepeatCount = $null; RepeatIntervalSeconds = $null }
                Mock Invoke-ToastNotification { throw 'Protocol failed' } -ParameterFilter { $ToastRow.MessageId -eq 42 }
                Invoke-ToastClientPoll @script:pollArgs -WarningAction SilentlyContinue
                $script:localStates[42L].ShowCount | Should -Be 0
                $script:localStates[43L].ShowCount | Should -Be 1
            }
        }

        It 'counts successful action and dismiss as explicit user acknowledgement' {
            InModuleScope ToastSql {
                foreach ($outcome in @('Action','Dismiss')) {
                    $script:localStates.Clear()
                    Mock Invoke-ToastNotification { [pscustomobject]@{ ResultType = $outcome } }
                    Invoke-ToastClientPoll @script:pollArgs
                    $script:localStates[42L].Read | Should -BeTrue
                }
            }
        }

        It 'does not starve an unread message behind more than twenty suppressed messages' {
            InModuleScope ToastSql {
                $script:pollRows = @(1..25 | ForEach-Object {
                    $script:localStates[[long]$_] = [pscustomobject]@{ Read = $true; ShowCount = 1; NextShowUtc = $null }
                    [pscustomobject]@{ MessageId = $_; RepeatCount = $null; RepeatIntervalSeconds = $null }
                })
                $script:pollRows += [pscustomobject]@{ MessageId = 26; RepeatCount = $null; RepeatIntervalSeconds = $null }
                Invoke-ToastClientPoll @script:pollArgs
                Should -Invoke Invoke-ToastNotification -Times 1 -ParameterFilter { $ToastRow.MessageId -eq 26 }
            }
        }

        It 'rechecks expiry cancellation and membership before displaying' {
            InModuleScope ToastSql {
                Mock Invoke-ToastSql { $null } -ParameterFilter { $null -ne $Parameters.MessageId }
                Invoke-ToastClientPoll @script:pollArgs
                Should -Invoke Invoke-ToastNotification -Times 0
                Should -Invoke Set-ToastReadState -Times 0
            }
        }

        It 'finds an unread message behind twenty-five suppressed SQL DataTable rows' {
            InModuleScope ToastSql {
                Mock Invoke-ToastSql {
                    $table = [System.Data.DataTable]::new()
                    [void]$table.Columns.Add('MessageId', [long])
                    [void]$table.Columns.Add('RepeatCount', [int])
                    [void]$table.Columns.Add('RepeatIntervalSeconds', [int])
                    foreach ($id in 1..26) {
                        if ($null -eq $Parameters.MessageId -or $id -eq $Parameters.MessageId) {
                            [void]$table.Rows.Add($id, [DBNull]::Value, [DBNull]::Value)
                        }
                    }
                    Write-Output -NoEnumerate $table
                }
                foreach ($id in 1..25) {
                    $script:localStates[[long]$id] = [pscustomobject]@{ Read = $true; ShowCount = 1; NextShowUtc = $null }
                }
                Invoke-ToastClientPoll @script:pollArgs
                Should -Invoke Invoke-ToastNotification -Times 1 -Exactly -ParameterFilter {
                    $ToastRow -is [System.Data.DataRow] -and $ToastRow.MessageId -eq 26
                }
                $script:localStates[26L].Read | Should -BeTrue
                $script:localStates[26L].ShowCount | Should -Be 1
            }
        }

        It 'handles the real SQL DataTable shape including an empty recheck' {
            InModuleScope ToastSql {
                Mock Invoke-ToastSql {
                    $table = [System.Data.DataTable]::new()
                    [void]$table.Columns.Add('MessageId', [long])
                    [void]$table.Columns.Add('RepeatCount', [int])
                    [void]$table.Columns.Add('RepeatIntervalSeconds', [int])
                    [void]$table.Rows.Add(42, [DBNull]::Value, [DBNull]::Value)
                    Write-Output -NoEnumerate $table
                }
                Invoke-ToastClientPoll @script:pollArgs
                Should -Invoke Invoke-ToastNotification -Times 1 -ParameterFilter { $ToastRow -is [System.Data.DataRow] }
                $script:localStates.Clear()
                Mock Invoke-ToastSql {
                    Write-Output -NoEnumerate ([System.Data.DataTable]::new())
                } -ParameterFilter { $null -ne $Parameters.MessageId }
                Invoke-ToastClientPoll @script:pollArgs
                Should -Invoke Invoke-ToastNotification -Times 1
            }
        }

        It 'fails visibly on registry errors before display or after acknowledgement' {
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

    Context 'AD computer import' {
        BeforeEach {
            function Get-ADComputer { param($Filter, $SearchBase) }
            Mock Import-Module {}
            Mock Get-ADComputer { [pscustomobject]@{ Name = 'PC01' }; [pscustomobject]@{ Name = 'PC01' }; [pscustomobject]@{ Name = "PC'02" } }
            Mock Import-ToastConfig { @{ CommandTimeoutSeconds = 15 } }
            Mock Get-ToastConnectionString { 'test' }
            Mock Get-ToastSqlCredential { $null }
            Mock Invoke-ToastSql {}
        }
        It 'uses OU and AD filter and parameterized idempotent membership inserts' {
            $result = & "$PSScriptRoot/../src/Server/Import-ToastADComputers.ps1" -ConfigPath 'admin.psd1' -Tag ' IT ' -SearchBase 'OU=PC,DC=test' -Filter 'Enabled -eq $true'
            $result.Count | Should -Be 2
            Should -Invoke Get-ADComputer -Times 1 -ParameterFilter { $Filter -eq 'Enabled -eq $true' -and $SearchBase -eq 'OU=PC,DC=test' }
            Should -Invoke Invoke-ToastSql -Times 2 -ParameterFilter {
                $NonQuery -and $Parameters.GroupName -eq 'IT' -and
                $CommandText -match 'UPDLOCK, HOLDLOCK' -and $CommandText -match 'BEGIN TRAN' -and
                $CommandText -notmatch "PC'02" -and $CommandText -notmatch 'ToastDelivery'
            }
        }
        It 'supports WhatIf without database writes' {
            & "$PSScriptRoot/../src/Server/Import-ToastADComputers.ps1" -ConfigPath 'admin.psd1' -Tag 'IT' -WhatIf
            Should -Invoke Invoke-ToastSql -Times 0
        }
        It 'validates tags and all computer names before writing' {
            { & "$PSScriptRoot/../src/Server/Import-ToastADComputers.ps1" -ConfigPath 'admin.psd1' -Tag ('a' * 129) } | Should -Throw
            Mock Get-ADComputer { [pscustomobject]@{ Name = 'PC01' }; [pscustomobject]@{ Name = ('x' * 257) } }
            { & "$PSScriptRoot/../src/Server/Import-ToastADComputers.ps1" -ConfigPath 'admin.psd1' -Tag 'IT' } | Should -Throw '*between 1 and 256*'
            Should -Invoke Invoke-ToastSql -Times 0
        }
    }

    Context 'read-only SQL installation contracts' {
        It 'keeps migration and consolidated queue definitions identical' {
            $migration = Get-Content "$PSScriptRoot/../sql/005-read-only-clients.sql" -Raw
            $installer = Get-Content "$PSScriptRoot/../sql/Install-BurntToast-SQLserver.sql" -Raw
            $pattern = '(?s)CREATE OR ALTER PROCEDURE dbo.usp_QueueToastMessage.*?\r?\nGO'
            $migrationQueue = [regex]::Match($migration, $pattern).Value
            $installerQueue = [regex]::Match($installer, $pattern).Value
            $migrationQueue | Should -Not -BeNullOrEmpty
            $migrationQueue.Trim() | Should -Be $installerQueue.Trim()
        }

        It 'installs identical SELECT-only polling and least-privilege client permissions in both paths' {
            $procedures = @()
            foreach ($file in @('005-read-only-clients.sql','Install-BurntToast-SQLserver.sql')) {
                $text = Get-Content "$PSScriptRoot/../sql/$file" -Raw
                $proc = [regex]::Match($text, '(?s)CREATE OR ALTER PROCEDURE dbo.usp_GetPendingToast.*?\r?\nGO').Value
                $proc | Should -Not -BeNullOrEmpty
                $proc | Should -Not -Match '(?i)\b(UPDATE|INSERT|DELETE|MERGE|EXEC|TOP|UPDLOCK|LeaseId|ToastDelivery|LastSeenUtc)\b'
                $proc | Should -Match 'm.IsUrgent DESC, m.MessageId'
                $proc | Should -Match 'm.IsCancelled = 0'
                $proc | Should -Match 'm.ExpiresUtc > SYSDATETIME\(\)'
                $proc | Should -Match 'g.IsActive = 1'
                $procedures += $proc
                $text | Should -Match 'GRANT EXECUTE ON OBJECT::dbo.usp_GetPendingToast TO ToastClientReader'
                $text | Should -Match 'DENY INSERT, UPDATE, DELETE TO ToastClientReader'
                $text | Should -Match 'DENY EXECUTE ON OBJECT::dbo.usp_QueueToastMessage TO ToastClientReader'
                $text | Should -Match 'DENY EXECUTE ON OBJECT::dbo.usp_RecordToastDelivery TO ToastClientReader'
                $text | Should -Not -Match 'GRANT (INSERT|UPDATE|DELETE|CONTROL|EXECUTE TO)'
                $text | Should -Not -Match 'INSERT dbo.ToastDelivery'
                $text | Should -Not -Match 'DROP TABLE dbo.ToastDelivery'
                $lastRecord = [regex]::Matches($text, '(?s)CREATE OR ALTER PROCEDURE dbo.usp_RecordToastDelivery.*?\r?\nGO') | Select-Object -Last 1
                $lastRecord.Value | Should -Match 'THROW 50040'
                $lastRecord.Value | Should -Not -Match 'UPDATE'
            }
            $procedures[0].Trim() | Should -Be $procedures[1].Trim()
        }
        It 'removes registration and database reporting from the client entry point' {
            $text = Get-Content "$PSScriptRoot/../src/Client/Start-ToastClient.ps1" -Raw
            $text | Should -Not -Match '\$Register|ClientGroups|usp_RecordToastDelivery|NonQuery|LeaseId|LastSeen'
            $text | Should -Match 'WindowsIdentity'
            $text | Should -Match 'Invoke-ToastClientPass'
            $text | Should -Not -Match 'UserSid|HKCU:|RunAsAdministrator|Verb RunAs'
            $task = Get-Content "$PSScriptRoot/../deploy/Register-ToastClientTask.ps1" -Raw
            $task | Should -Match '\$identity.User.Value'
            $task | Should -Match '-LogonType Interactive -RunLevel Limited'
            $task | Should -Match '-MultipleInstances IgnoreNew'
        }
    }

    Context 'local-time reporting SQL compatibility' {
        It 'keeps @TimeZoneName and avoids UTC-to-local conversion assumptions' {
            $scriptPath = Join-Path $PSScriptRoot '..\sql\004-local-time-reporting.sql'
            $scriptText = Get-Content -Path $scriptPath -Raw

            $scriptText | Should -Match "DECLARE @DefaultLocalTimeZone sysname = NULL;"
            $scriptText | Should -Match "CURRENT_TIMEZONE\(\)"
            $scriptText | Should -Match "FROM sys\.time_zone_info"
            $scriptText | Should -Match "ufn_ToastMessageLocal\s*\(\s*@TimeZoneName sysname = N'''\s*\+ @EscapedDefaultLocalTimeZone \+ N''',\s*@ServerTimeZoneName sysname = N'''\s*\+ @EscapedDefaultLocalTimeZone \+ N'''"
            $scriptText | Should -Match "ufn_ToastDeliveryLocal\s*\(\s*@TimeZoneName sysname = N'''\s*\+ @EscapedDefaultLocalTimeZone \+ N''',\s*@ServerTimeZoneName sysname = N'''\s*\+ @EscapedDefaultLocalTimeZone \+ N'''"
            $scriptText | Should -Match "\(m\.CreatedUtc AT TIME ZONE @ServerTimeZoneName\) AT TIME ZONE @TimeZoneName"
            $scriptText | Should -Match "\(d\.LastAttemptUtc AT TIME ZONE @ServerTimeZoneName\) AT TIME ZONE @TimeZoneName"
            $scriptText | Should -Match "m\.CreatedUtc AT TIME ZONE N'''\s*\+ @EscapedDefaultLocalTimeZone \+ N''' AS CreatedLocalTime"
            $scriptText | Should -Match "d\.LastAttemptUtc AT TIME ZONE N'''\s*\+ @EscapedDefaultLocalTimeZone \+ N''' AS LastAttemptLocalTime"
            $scriptText | Should -Match "m\.CreatedUtc AS CreatedServerLocalTime"
            $scriptText | Should -Match "d\.LastAttemptUtc AS LastAttemptServerLocalTime"
            $scriptText | Should -Not -Match "AT TIME ZONE ''UTC''"
        }
    }

    Context 'legacy UTC migration SQL coverage' {
        It 'converts legacy UTC timestamp columns when upgrading existing installations' {
            $scriptPath = Join-Path $PSScriptRoot '..\sql\002-toast-design-repeat.sql'
            $scriptText = Get-Content -Path $scriptPath -Raw

            $scriptText | Should -Match "CURRENT_TIMEZONE\(\)"
            $scriptText | Should -Match "FROM sys\.time_zone_info"
            $scriptText | Should -Match "UPDATE dbo\.ToastMessage"
            $scriptText | Should -Match "UPDATE dbo\.ToastDelivery"
            $scriptText | Should -Match "UPDATE dbo\.ToastClient"
            $scriptText | Should -Match "AT TIME ZONE 'UTC'\) AT TIME ZONE @ServerLocalTimeZone"
            $scriptText | Should -Match "DECLARE @DropNextShowUtcDefaultConstraintSql nvarchar\(max\)"
            $scriptText | Should -Match "SET @DropNextShowUtcDefaultConstraintSql =\s*N'ALTER TABLE dbo\.ToastDelivery DROP CONSTRAINT '\s*\+\s*QUOTENAME\(@NextShowUtcDefaultConstraintName\)\s*\+\s*N';'"
            $scriptText | Should -Match "EXEC sp_executesql @DropNextShowUtcDefaultConstraintSql"
        }
    }

    Context 'queued-toast SQL procedure compatibility' {
        It 'exposes queue/get/record contracts expected by the client scripts' {
            $repeatScriptPath = Join-Path $PSScriptRoot '..\sql\002-toast-design-repeat.sql'
            $buttonScriptPath = Join-Path $PSScriptRoot '..\sql\003-toast-button.sql'
            $schemaScriptPath = Join-Path $PSScriptRoot '..\sql\001-schema.sql'
            $installScriptPath = Join-Path $PSScriptRoot '..\sql\Install-BurntToast-SQLserver.sql'
            $serverScriptPath = Join-Path $PSScriptRoot '..\src\Server\Send-ToastMessage.ps1'
            $taskScriptPath = Join-Path $PSScriptRoot '..\deploy\Register-ToastClientTask.ps1'
            $clientScriptPath = Join-Path $PSScriptRoot '..\src\Client\Start-ToastClient.ps1'
            $configPath = Join-Path $PSScriptRoot '..\config\config.example.psd1'
            $repeatScriptText = Get-Content -Path $repeatScriptPath -Raw
            $buttonScriptText = Get-Content -Path $buttonScriptPath -Raw
            $schemaScriptText = Get-Content -Path $schemaScriptPath -Raw
            $installScriptText = Get-Content -Path $installScriptPath -Raw
            $serverScriptText = Get-Content -Path $serverScriptPath -Raw
            $taskScriptText = Get-Content -Path $taskScriptPath -Raw
            $clientScriptText = Get-Content -Path $clientScriptPath -Raw
            $configText = Get-Content -Path $configPath -Raw

            $repeatScriptText | Should -Match "CREATE OR ALTER PROCEDURE dbo\.usp_RecordToastDelivery"
            $repeatScriptText | Should -Match "@LeaseId uniqueidentifier"
            $repeatScriptText | Should -Match "inserted\.LeaseId"
            $repeatScriptText | Should -Match "inserted\.ShowCount"
            $repeatScriptText | Should -Match "IF COL_LENGTH\('dbo\.ToastMessage', 'Subtitle'\) IS NULL\s+ALTER TABLE dbo\.ToastMessage ADD Subtitle nvarchar\(200\) NULL"
            $repeatScriptText | Should -Match "@Subtitle nvarchar\(200\) = NULL"
            $repeatScriptText | Should -Match "m\.Subtitle"
            $repeatScriptText.IndexOf("IF COL_LENGTH('dbo.ToastMessage', 'Subtitle') IS NULL") |
                Should -BeLessThan $repeatScriptText.IndexOf('CREATE OR ALTER PROCEDURE dbo.usp_QueueToastMessage')

            $buttonScriptText | Should -Match "@Sound varchar\(20\) = NULL"
            $buttonScriptText | Should -Match "@IsUrgent bit = 0"
            $buttonScriptText | Should -Match "@RepeatIntervalSeconds int = NULL"
            $buttonScriptText | Should -Match "@RepeatCount int = NULL"
            $buttonScriptText | Should -Match "@ButtonText nvarchar\(200\) = NULL"
            $buttonScriptText | Should -Match "@ButtonArguments nvarchar\(2048\) = NULL"
            $buttonScriptText | Should -Match "@ButtonActivationType varchar\(20\) = NULL"
            $buttonScriptText | Should -Match "@Scenario varchar\(20\) = 'Default'"
            $buttonScriptText | Should -Match "@DisplayMode varchar\(20\) = 'AppDeployToolkit'"
            $buttonScriptText | Should -Match "@ResolvedScenario varchar\(20\) = NULL OUTPUT"
            $buttonScriptText | Should -Match "@ResolvedScenario varchar\(20\) = NULL OUTPUT,\s*@Subtitle nvarchar\(200\) = NULL"
            $buttonScriptText | Should -Match "Scenario must be Default, Reminder, Alarm, or IncomingCall"
            $buttonScriptText | Should -Match "DisplayMode must be AppDeployToolkit"
            $buttonScriptText | Should -Match "IF COL_LENGTH\('dbo\.ToastMessage', 'Subtitle'\) IS NULL\s+ALTER TABLE dbo\.ToastMessage ADD Subtitle nvarchar\(200\) NULL"
            $buttonScriptText | Should -Match "SET @Subtitle = NULLIF\(LTRIM\(RTRIM\(@Subtitle\)\), ''\)"
            $buttonScriptText | Should -Match "Title,\s*Subtitle,\s*Body"
            $buttonScriptText | Should -Match "m\.Subtitle"
            $buttonScriptText | Should -Match "ALTER TABLE dbo\.ToastMessage ADD Scenario varchar\(20\) NULL"
            $buttonScriptText | Should -Match "ALTER TABLE dbo\.ToastMessage ADD DisplayMode varchar\(20\) NULL"
            $buttonScriptText | Should -Match "MessagesWithDeliveryHistory AS"
            $buttonScriptText | Should -Match "h\.MessageId IS NULL"
            $buttonScriptText | Should -Match "m\.Scenario"
            $buttonScriptText | Should -Match "CAST\('AppDeployToolkit' AS varchar\(20\)\) AS DisplayMode"
            $buttonScriptText | Should -Match "IF COL_LENGTH\('dbo\.ToastMessage', 'AcknowledgeButtonText'\) IS NULL\s+ALTER TABLE dbo\.ToastMessage ADD AcknowledgeButtonText nvarchar\(200\) NULL"
            $buttonScriptText | Should -Match "@Subtitle nvarchar\(200\) = NULL,\s*@AcknowledgeButtonText nvarchar\(200\) = NULL\s*AS"
            $buttonScriptText | Should -Match "SET @AcknowledgeButtonText = NULLIF\(LTRIM\(RTRIM\(@AcknowledgeButtonText\)\), ''\)"
            $buttonScriptText | Should -Match "THROW 50032, 'AcknowledgeButtonText must differ from ButtonText\.'"
            $buttonScriptText | Should -Match "DisplayMode,\s*AcknowledgeButtonText\s*\)"
            $buttonScriptText | Should -Match "@DisplayMode,\s*@AcknowledgeButtonText\s*\)"
            $buttonScriptText | Should -Match "m\.AcknowledgeButtonText"
            $buttonScriptText.IndexOf("IF COL_LENGTH('dbo.ToastMessage', 'AcknowledgeButtonText') IS NULL") |
                Should -BeLessThan $buttonScriptText.IndexOf('CREATE OR ALTER PROCEDURE dbo.usp_QueueToastMessage')
            $buttonScriptText.IndexOf("IF COL_LENGTH('dbo.ToastMessage', 'Subtitle') IS NULL") |
                Should -BeLessThan $buttonScriptText.IndexOf('CREATE OR ALTER PROCEDURE dbo.usp_QueueToastMessage')
            $schemaScriptText | Should -Match "DisplayMode must be AppDeployToolkit"
            $schemaScriptText | Should -Match "Subtitle\s+nvarchar\(200\) NULL"
            $schemaScriptText | Should -Match "@ResolvedScenario varchar\(20\) = NULL OUTPUT,\s*@Subtitle nvarchar\(200\) = NULL"
            $schemaScriptText | Should -Match "Title, Subtitle, Body"
            $schemaScriptText | Should -Match "NULLIF\(LTRIM\(RTRIM\(@Subtitle\)\), ''\)"
            $schemaScriptText | Should -Match "m\.Subtitle"
            $schemaScriptText | Should -Match "AcknowledgeButtonText\s+nvarchar\(200\) NULL"
            $schemaScriptText | Should -Match "@Subtitle nvarchar\(200\) = NULL,\s*@AcknowledgeButtonText nvarchar\(200\) = NULL\s*AS"
            $schemaScriptText | Should -Match "SET @AcknowledgeButtonText = NULLIF\(LTRIM\(RTRIM\(@AcknowledgeButtonText\)\), ''\)"
            $schemaScriptText | Should -Match "THROW 50032, 'AcknowledgeButtonText must differ from ButtonText\.'"
            $schemaScriptText | Should -Match "DisplayMode,\s*AcknowledgeButtonText\s*\)"
            $schemaScriptText | Should -Match "@DisplayMode,\s*@AcknowledgeButtonText\s*\)"
            $schemaScriptText | Should -Match "m\.AcknowledgeButtonText"
            $serverScriptText | Should -Match '\[ValidateSet\(''AppDeployToolkit''\)\]\[string\]\$DisplayMode = ''AppDeployToolkit'''
            $serverScriptText | Should -Match "@DisplayMode = @DisplayMode"
            $serverScriptText | Should -Match '\[AllowNull\(\)\]\[AllowEmptyString\(\)\]\[string\]\$Subtitle'
            $serverScriptText | Should -Match "@Subtitle = @Subtitle"
            $installScriptText | Should -Match "IF COL_LENGTH\('dbo\.ToastMessage', 'Subtitle'\) IS NULL\s+ALTER TABLE dbo\.ToastMessage ADD Subtitle nvarchar\(200\) NULL"
            $installScriptText | Should -Match "@ResolvedScenario varchar\(20\) = NULL OUTPUT,\s*@Subtitle nvarchar\(200\) = NULL"
            $installScriptText | Should -Match "SET @Subtitle = NULLIF\(LTRIM\(RTRIM\(@Subtitle\)\), ''\)"
            $installScriptText | Should -Match "Title,\s*Subtitle,\s*Body"
            $installScriptText | Should -Match "m\.Subtitle"
            $installScriptText | Should -Match "IF COL_LENGTH\('dbo\.ToastMessage', 'AcknowledgeButtonText'\) IS NULL\s+ALTER TABLE dbo\.ToastMessage ADD AcknowledgeButtonText nvarchar\(200\) NULL"
            $installScriptText | Should -Match "@Subtitle nvarchar\(200\) = NULL,\s*@AcknowledgeButtonText nvarchar\(200\) = NULL\s*AS"
            $installScriptText | Should -Match "SET @AcknowledgeButtonText = NULLIF\(LTRIM\(RTRIM\(@AcknowledgeButtonText\)\), ''\)"
            $installScriptText | Should -Match "THROW 50032, 'AcknowledgeButtonText must differ from ButtonText\.'"
            $installScriptText | Should -Match "DisplayMode,\s*AcknowledgeButtonText\s*\)"
            $installScriptText | Should -Match "@DisplayMode,\s*@AcknowledgeButtonText\s*\)"
            $installScriptText | Should -Match "m\.AcknowledgeButtonText"
            $installScriptText.IndexOf("IF COL_LENGTH('dbo.ToastMessage', 'AcknowledgeButtonText') IS NULL") |
                Should -BeLessThan $installScriptText.IndexOf('CREATE OR ALTER PROCEDURE dbo.usp_QueueToastMessage')
            $installScriptText.IndexOf("IF COL_LENGTH('dbo.ToastMessage', 'Subtitle') IS NULL") |
                Should -BeLessThan $installScriptText.IndexOf('CREATE OR ALTER PROCEDURE dbo.usp_QueueToastMessage')
            $serverScriptText | Should -Not -Match 'AppLogo'
            $serverScriptText | Should -Not -Match 'HeroImage'
            $serverScriptText | Should -Not -Match '@Sound'
            $taskScriptText | Should -Match '-STA'
            $taskScriptText | Should -Match 'Displays SQL-backed AppDeployToolkit notifications'
            $taskScriptText | Should -Not -Match 'BurntToast'
            $taskScriptText | Should -Not -Match 'WPF'
            $clientScriptText | Should -Match 'Set-ToastClientDependencyOptions -AppDeployToolkitModulePath'
            $clientScriptText | Should -Match 'AppDeployToolkitModulePath'
            $clientScriptText | Should -Not -Match 'InternalPowerShellRepository'
            $configText | Should -Match 'AppDeployToolkitModulePath'
            $configText | Should -Not -Match 'InternalPowerShellRepository'
            $installScriptText | Should -Match "IF OBJECT_ID\('dbo\.ToastGroup', 'U'\) IS NULL"
            $installScriptText | Should -Match "CREATE OR ALTER PROCEDURE dbo\.usp_QueueToastMessage"
            $installScriptText | Should -Match "CREATE OR ALTER PROCEDURE dbo\.usp_GetPendingToast"
            $installScriptText | Should -Match "CREATE OR ALTER PROCEDURE dbo\.usp_RecordToastDelivery"
            $installScriptText | Should -Match "CREATE OR ALTER FUNCTION dbo\.ufn_ToastMessageLocal"
            $installScriptText | Should -Match "CREATE OR ALTER VIEW dbo\.vw_ToastDeliveryLocal"
            $installScriptText | Should -Match "DisplayMode must be AppDeployToolkit"
            $installScriptText | Should -Match "MessagesWithDeliveryHistory AS"
            $installScriptText | Should -Match "h\.MessageId IS NULL"
            $installScriptText | Should -Match "CURRENT_TIMEZONE\(\)"
        }

        It 'removes obsolete image columns from every SQL script, index, procedure parameter, INSERT, and OUTPUT' {
            $obsoleteImageColumns = @('AppLogoPath', 'HeroImagePath', 'AppLogoBytes', 'AppLogoContentType', 'HeroImageBytes', 'HeroImageContentType')
            foreach ($scriptName in @('001-schema.sql', '002-toast-design-repeat.sql', '003-toast-button.sql', '004-local-time-reporting.sql')) {
                $scriptText = Get-Content -Path (Join-Path $PSScriptRoot "..\sql\$scriptName") -Raw
                foreach ($columnName in $obsoleteImageColumns) {
                    $scriptText | Should -Not -Match $columnName -Because "$scriptName must not reference $columnName"
                }
            }

            $schemaScriptText = Get-Content -Path (Join-Path $PSScriptRoot '..\sql\001-schema.sql') -Raw
            $schemaScriptText | Should -Match 'INCLUDE \(IsCancelled, ExpiresUtc, Title, Body, Sound, IsUrgent, RepeatIntervalSeconds, RepeatCount\)'
            $schemaScriptText | Should -Match 'Sound\s+varchar\(20\) NULL'
            $schemaScriptText | Should -Match 'm\.Sound'

            $installScriptText = Get-Content -Path (Join-Path $PSScriptRoot '..\sql\Install-BurntToast-SQLserver.sql') -Raw
            foreach ($columnName in $obsoleteImageColumns) {
                $installScriptText | Should -Not -Match "ADD $columnName" -Because 'earlier installer stages must not re-add obsolete image columns'
                $installScriptText | Should -Not -Match "@$columnName" -Because 'procedures must not expose obsolete image parameters'
                $installScriptText | Should -Not -Match "m\.$columnName" -Because 'usp_GetPendingToast must not OUTPUT obsolete image columns'
                $installScriptText | Should -Not -Match "(?m)^\s+$columnName\s+(n?varchar|varbinary)" -Because 'fresh installs must not create obsolete image columns'
            }

            # Existing databases: drop dependent indexes/constraints/statistics first, then the columns, then recreate the polling index and procedures.
            $cleanupStart = $installScriptText.IndexOf('Remove obsolete image columns from dbo.ToastMessage')
            $cleanupStart | Should -BeGreaterThan 0
            $dropIndexPosition = $installScriptText.IndexOf("N'DROP INDEX '", $cleanupStart)
            $dropColumnPosition = $installScriptText.IndexOf("N'ALTER TABLE dbo.ToastMessage DROP COLUMN '", $cleanupStart)
            $recreateIndexPosition = $installScriptText.IndexOf('CREATE INDEX IX_ToastMessage_Polling', $cleanupStart)
            $queueProcedurePosition = $installScriptText.IndexOf('CREATE OR ALTER PROCEDURE dbo.usp_QueueToastMessage')
            $dropIndexPosition | Should -BeGreaterThan $cleanupStart
            $dropColumnPosition | Should -BeGreaterThan $dropIndexPosition
            $recreateIndexPosition | Should -BeGreaterThan $dropColumnPosition
            $queueProcedurePosition | Should -BeGreaterThan $recreateIndexPosition
            $installScriptText | Should -Match "VALUES \(N'AppLogoPath'\), \(N'HeroImagePath'\), \(N'AppLogoBytes'\), \(N'AppLogoContentType'\), \(N'HeroImageBytes'\), \(N'HeroImageContentType'\)"
            $installScriptText | Should -Match 'Back up the database'

            InModuleScope ToastSql -Parameters @{ Columns = $obsoleteImageColumns } {
                param($Columns)
                foreach ($columnName in $Columns) {
                    $script:ToastSqlNullParameterDefinitions.ContainsKey($columnName) | Should -BeFalse
                }
                $script:ToastSqlNullParameterDefinitions.ContainsKey('Sound') | Should -BeTrue
            }
        }
    }
}
