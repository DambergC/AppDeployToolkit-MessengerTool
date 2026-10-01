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
                Get-ToastAppDeployToolkitSubtitle -Title '' -Body "`r`n  First line  `r`nSecond line" | Should -Be 'First line'
                Get-ToastAppDeployToolkitSubtitle -Title '' -Body '' | Should -Be 'Notification'
            }
        }

        It 'returns null when a protocol action starts successfully' {
            InModuleScope ToastSql {
                Mock Start-Process {}

                Invoke-ToastProtocolAction -ButtonArguments 'https://example.com' | Should -Be $null
                Should -Invoke Start-Process -Times 1 -ParameterFilter { $FilePath -eq 'https://example.com' }
            }
        }

        It 'returns an error message when a protocol action fails to start' {
            InModuleScope ToastSql {
                Mock Start-Process { throw 'boom' }

                (Invoke-ToastProtocolAction -ButtonArguments 'https://example.com') | Should -Match 'boom'
            }
        }
    }

    Context 'AppDeployToolkit prompt construction' {
        It 'passes Subtitle when the prompt command requires it and preserves the body as the message' {
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
                    $result = Show-ToastAppDeployToolkitPrompt -MessageId 42 -Title 'Toast title' -Body 'Toast body'

                    $result.ResultType | Should -Be 'Acknowledge'
                    $script:capturedPromptParameters.Title | Should -Be 'Toast title'
                    $script:capturedPromptParameters.Subtitle | Should -Be 'Toast title'
                    $script:capturedPromptParameters.Message | Should -Be 'Toast body'
                    $script:capturedPromptParameters.ButtonRightText | Should -Be 'Acknowledge'
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
                    $result = Show-ToastAppDeployToolkitPrompt -MessageId 42 -Title 'Toast title' -Body 'Toast body'

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
                        [string]$Subtitle,
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

                Mock Start-Process {}

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
                    Should -Invoke Start-Process -Times 1 -ParameterFilter { $FilePath -eq 'https://example.com/details' }
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

                Mock Start-Process {}

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
                    Should -Invoke Start-Process -Times 0
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

                Mock Start-Process {}

                try {
                    $result = Show-ToastAppDeployToolkitPrompt `
                        -MessageId 42 `
                        -Title 'Toast title' `
                        -Body 'Toast body' `
                        -ButtonText 'Dismiss' `
                        -ButtonActivationType 'Dismiss'

                    $result.Selection | Should -Be 'Action'
                    $result.ResultType | Should -Be 'Dismiss'
                    Should -Invoke Start-Process -Times 0
                } finally {
                    Remove-Item Function:\Show-ADTInstallationPrompt -ErrorAction SilentlyContinue
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
            $parameterNames | Should -Contain 'ExpiresUtc'
            $parameterNames | Should -Contain 'Urgent'
            $parameterNames | Should -Contain 'RepeatIntervalSeconds'
            $parameterNames | Should -Contain 'RepeatIntervalMinutes'
            $parameterNames | Should -Contain 'RepeatCount'
            $parameterNames | Should -Contain 'ButtonText'
            $parameterNames | Should -Contain 'ButtonArguments'
            $parameterNames | Should -Contain 'ButtonActivationType'
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
                    Body = 'Body'
                    DisplayMode = 'AppDeployToolkit'
                    ButtonText = 'Open'
                    ButtonArguments = 'https://example.com'
                    ButtonActivationType = 'Protocol'
                }

                Invoke-ToastNotification -ToastRow $row

                Should -Invoke Ensure-ToastNotificationDependencies -Times 1 -ParameterFilter { $DisplayMode -eq 'AppDeployToolkit' }
                Should -Invoke Show-ToastAppDeployToolkitPrompt -Times 1 -ParameterFilter {
                    $MessageId -eq 42 -and
                    $Title -eq 'Title' -and
                    $Body -eq 'Body' -and
                    $ButtonText -eq 'Open' -and
                    $ButtonArguments -eq 'https://example.com' -and
                    $ButtonActivationType -eq 'Protocol'
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
            $repeatScriptText | Should -Match "@AppLogoBytes varbinary\(max\) = NULL"
            $repeatScriptText | Should -Match "@AppLogoContentType varchar\(100\) = NULL"
            $repeatScriptText | Should -Match "@HeroImageBytes varbinary\(max\) = NULL"
            $repeatScriptText | Should -Match "@HeroImageContentType varchar\(100\) = NULL"

            $buttonScriptText | Should -Match "@AppLogoPath nvarchar\(1024\) = NULL"
            $buttonScriptText | Should -Match "@HeroImagePath nvarchar\(1024\) = NULL"
            $buttonScriptText | Should -Match "@AppLogoBytes varbinary\(max\) = NULL"
            $buttonScriptText | Should -Match "@AppLogoContentType varchar\(100\) = NULL"
            $buttonScriptText | Should -Match "@HeroImageBytes varbinary\(max\) = NULL"
            $buttonScriptText | Should -Match "@HeroImageContentType varchar\(100\) = NULL"
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
            $buttonScriptText | Should -Match "Scenario must be Default, Reminder, Alarm, or IncomingCall"
            $buttonScriptText | Should -Match "DisplayMode must be AppDeployToolkit"
            $buttonScriptText | Should -Match "ALTER TABLE dbo\.ToastMessage ADD Scenario varchar\(20\) NULL"
            $buttonScriptText | Should -Match "ALTER TABLE dbo\.ToastMessage ADD DisplayMode varchar\(20\) NULL"
            $buttonScriptText | Should -Match "MessagesWithDeliveryHistory AS"
            $buttonScriptText | Should -Match "h\.MessageId IS NULL"
            $buttonScriptText | Should -Match "m\.Scenario"
            $buttonScriptText | Should -Match "CAST\('AppDeployToolkit' AS varchar\(20\)\) AS DisplayMode"
            $buttonScriptText | Should -Match "m\.AppLogoBytes"
            $buttonScriptText | Should -Match "m\.HeroImageBytes"
            $schemaScriptText | Should -Match "DisplayMode must be AppDeployToolkit"
            $serverScriptText | Should -Match '\[ValidateSet\(''AppDeployToolkit''\)\]\[string\]\$DisplayMode = ''AppDeployToolkit'''
            $serverScriptText | Should -Match "@DisplayMode = @DisplayMode"
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
    }
}
