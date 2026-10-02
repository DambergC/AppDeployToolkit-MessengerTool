$modulePath = Join-Path $PSScriptRoot '..\src\Module\ToastSql.psm1'
Import-Module $modulePath -Force

Describe 'Start-ToastClient-API.ps1' {
    BeforeAll {
        $script:clientScriptPath = Join-Path $PSScriptRoot '..\src\Client\Start-ToastClient-API.ps1'
        $script:exampleConfigPath = Join-Path $PSScriptRoot '..\config\config.example-api.psd1'

        function New-TestApiConfig {
            param([string]$ApiUri = 'https://messenger.example.test/api', [int]$MaxRetryCount = 2)

            $path = Join-Path $TestDrive "config-$([guid]::NewGuid().ToString('N')).psd1"
            Set-Content -Path $path -Value @"
@{
    ApiUri = '$ApiUri'
    ClientName = 'PC001'
    ClientGroups = @('IT-TEST','SALES')
    AppDeployToolkitModulePath = `$null
    RequestTimeoutSeconds = 5
    MaxRetryCount = $MaxRetryCount
    RetryDelaySeconds = 0
}
"@
            return $path
        }

        function New-TestHttpError {
            param([int]$StatusCode, [string]$Message = "HTTP $StatusCode")

            $exception = [System.Exception]::new($Message)
            $exception | Add-Member -NotePropertyName Response -NotePropertyValue ([pscustomobject]@{ StatusCode = $StatusCode })
            return [System.Management.Automation.ErrorRecord]::new($exception, 'TestHttpError', [System.Management.Automation.ErrorCategory]::InvalidOperation, $null)
        }

        function New-TestToastRow {
            [pscustomobject]@{
                MessageId = 42
                LeaseId = '6f9619ff-8b86-d011-b42d-00c04fc964ff'
                Title = 'Title'
                Subtitle = $null
                Body = 'Body'
                ButtonText = $null
                ButtonArguments = $null
                ButtonActivationType = $null
                AcknowledgeButtonText = $null
                DisplayMode = 'AppDeployToolkit'
                ShowCount = 0
            }
        }
    }

    BeforeEach {
        # Mock bodies run inside the client script's scope, so shared state lives in a global hashtable.
        $global:ToastApiTestState = @{
            PutBodies = [System.Collections.Generic.List[object]]::new()
            RequestLog = [System.Collections.Generic.List[string]]::new()
            GetAttempts = 0
            PutAttempts = 0
        }
        Mock Start-Sleep {}
        Mock Invoke-ToastNotification {}
    }

    AfterEach {
        Remove-Variable -Name ToastApiTestState -Scope Global -ErrorAction SilentlyContinue
    }

    It 'ships an API example config that loads with the expected settings' {
        $config = Import-PowerShellDataFile -Path $script:exampleConfigPath
        $config.ApiUri | Should -Match '^https://'
        $config.ContainsKey('ClientName') | Should -BeTrue
        $config.ClientName | Should -BeNullOrEmpty
        @($config.ClientGroups).Count | Should -BeGreaterThan 0
        $config.ContainsKey('AppDeployToolkitModulePath') | Should -BeTrue
        $config.Keys | Should -Not -Contain 'SqlServer'
    }

    It 'rejects a non-https ApiUri' {
        $configPath = New-TestApiConfig -ApiUri 'http://messenger.example.test/api'
        Mock Invoke-RestMethod {}
        { & $script:clientScriptPath -ConfigPath $configPath -Once } | Should -Throw '*ApiUri must be an absolute https URL*'
        Should -Invoke Invoke-RestMethod -Times 0 -Exactly
    }

    It 'registers the client and groups via POST using default credentials' {
        $configPath = New-TestApiConfig
        Mock Invoke-RestMethod {
            $global:ToastApiTestState.RequestLog.Add("$Method $Uri")
            $global:ToastApiTestState.RegisterBody = [System.Text.Encoding]::UTF8.GetString($Body) | ConvertFrom-Json
            $global:ToastApiTestState.UsedDefaultCredentials = [bool]$UseDefaultCredentials
        }

        $output = & $script:clientScriptPath -ConfigPath $configPath -Register -Once

        $output | Should -Be 'Registered PC001'
        $global:ToastApiTestState.RequestLog | Should -Be @('Post https://messenger.example.test/api/Clients')
        $global:ToastApiTestState.RegisterBody.computerName | Should -Be 'PC001'
        @($global:ToastApiTestState.RegisterBody.groups) | Should -Be @('IT-TEST','SALES')
        $global:ToastApiTestState.UsedDefaultCredentials | Should -BeTrue
    }

    It 'shows pending toasts and acknowledges delivery with the lease via PUT' {
        $configPath = New-TestApiConfig
        Mock Invoke-RestMethod {
            $global:ToastApiTestState.RequestLog.Add("$Method $Uri")
            if ($Method -eq 'Get') { return ,@(New-TestToastRow) }
            $global:ToastApiTestState.PutBodies.Add(([System.Text.Encoding]::UTF8.GetString($Body) | ConvertFrom-Json))
        }

        & $script:clientScriptPath -ConfigPath $configPath -Once

        Should -Invoke Invoke-ToastNotification -Times 1 -Exactly -ParameterFilter { $ToastRow.MessageId -eq 42 }
        $global:ToastApiTestState.RequestLog | Should -Be @('Get https://messenger.example.test/api/Clients/PC001', 'Put https://messenger.example.test/api/Clients/PC001')
        $global:ToastApiTestState.PutBodies[0].messageId | Should -Be 42
        $global:ToastApiTestState.PutBodies[0].leaseId | Should -Be '6f9619ff-8b86-d011-b42d-00c04fc964ff'
        $global:ToastApiTestState.PutBodies[0].status | Should -Be 'Delivered'
        $global:ToastApiTestState.PutBodies[0].errorMessage | Should -BeNullOrEmpty
    }

    It 'does nothing when no toasts are pending' {
        $configPath = New-TestApiConfig
        Mock Invoke-RestMethod { if ($Method -eq 'Get') { return ,@() } }

        & $script:clientScriptPath -ConfigPath $configPath -Once

        Should -Invoke Invoke-ToastNotification -Times 0 -Exactly
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly
    }

    It 'records a Failed delivery with the error message when the toast cannot be shown' {
        $configPath = New-TestApiConfig
        Mock Invoke-ToastNotification { throw 'ADT prompt failed' }
        Mock Invoke-RestMethod {
            if ($Method -eq 'Get') { return ,@(New-TestToastRow) }
            $global:ToastApiTestState.PutBodies.Add(([System.Text.Encoding]::UTF8.GetString($Body) | ConvertFrom-Json))
        }

        & $script:clientScriptPath -ConfigPath $configPath -Once

        $global:ToastApiTestState.PutBodies.Count | Should -Be 1
        $global:ToastApiTestState.PutBodies[0].status | Should -Be 'Failed'
        $global:ToastApiTestState.PutBodies[0].errorMessage | Should -Be 'ADT prompt failed'
    }

    It 'retries transient HTTP errors before succeeding' {
        $configPath = New-TestApiConfig
        Mock Invoke-RestMethod {
            if ($Method -eq 'Get') {
                $global:ToastApiTestState.GetAttempts++
                if ($global:ToastApiTestState.GetAttempts -lt 3) { throw (New-TestHttpError -StatusCode 503) }
                return ,@()
            }
        }

        & $script:clientScriptPath -ConfigPath $configPath -Once

        $global:ToastApiTestState.GetAttempts | Should -Be 3
    }

    It 'does not retry non-transient HTTP errors' {
        $configPath = New-TestApiConfig
        Mock Invoke-RestMethod {
            $global:ToastApiTestState.GetAttempts++
            throw (New-TestHttpError -StatusCode 400 -Message 'bad request')
        }

        { & $script:clientScriptPath -ConfigPath $configPath -Once } | Should -Throw '*bad request*'
        $global:ToastApiTestState.GetAttempts | Should -Be 1
    }

    It 'treats a lease conflict after a transient acknowledgement failure as already recorded' {
        $configPath = New-TestApiConfig
        Mock Invoke-RestMethod {
            if ($Method -eq 'Get') { return ,@(New-TestToastRow) }
            $global:ToastApiTestState.PutAttempts++
            if ($global:ToastApiTestState.PutAttempts -eq 1) { throw [System.Net.Http.HttpRequestException]::new('connection reset') }
            throw (New-TestHttpError -StatusCode 409 -Message 'Lease not active.')
        }

        { & $script:clientScriptPath -ConfigPath $configPath -Once -WarningVariable warnings -WarningAction SilentlyContinue } | Should -Not -Throw
        $global:ToastApiTestState.PutAttempts | Should -Be 2
    }

    It 'warns instead of failing when delivery acknowledgement keeps failing transiently' {
        $configPath = New-TestApiConfig -MaxRetryCount 1
        Mock Invoke-RestMethod {
            if ($Method -eq 'Get') { return ,@(New-TestToastRow) }
            $global:ToastApiTestState.PutAttempts++
            throw (New-TestHttpError -StatusCode 503 -Message 'unavailable')
        }

        & $script:clientScriptPath -ConfigPath $configPath -Once -WarningVariable warnings -WarningAction SilentlyContinue

        $global:ToastApiTestState.PutAttempts | Should -Be 2
        ($warnings -join "`n") | Should -Match 'could not record delivery status after retry'
    }

    It 'fails fast when a lease conflict occurs without a prior transient failure' {
        $configPath = New-TestApiConfig
        Mock Invoke-RestMethod {
            if ($Method -eq 'Get') { return ,@(New-TestToastRow) }
            throw (New-TestHttpError -StatusCode 409 -Message 'Lease not active.')
        }

        { & $script:clientScriptPath -ConfigPath $configPath -Once } | Should -Throw '*Lease not active*'
    }
}
