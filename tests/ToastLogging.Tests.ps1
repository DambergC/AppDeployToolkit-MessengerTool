BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../src/Module/ToastLogging.psm1') -Force
    $script:TestLogPath = Join-Path $TestDrive 'Client.log'
    $script:TestRunId = '0123456789abcdef0123456789abcdef'
}

Describe 'ToastLogging module' {
    BeforeEach {
        Get-ChildItem -LiteralPath $TestDrive -Filter 'Client.log*' -ErrorAction SilentlyContinue |
            Remove-Item -Force
    }

    It 'writes CMTrace-compatible entries with timezone, level, PID, run ID and MessageId' {
        Write-ToastLog -Path $script:TestLogPath -Level Info -Component 'Client' -RunId $script:TestRunId `
            -Message 'Dialog result: Acknowledge.' -MessageId 42

        $line = Get-Content -LiteralPath $script:TestLogPath -Raw
        $line | Should -Match '<!\[LOG\[Dialog result: Acknowledge\.\]LOG\]!><time="\d{2}:\d{2}:\d{2}\.\d{3}[+-]\d{2}:\d{2}" date="\d{4}-\d{2}-\d{2}" component="Client" context="RunId=0123456789abcdef0123456789abcdef;Level=Info;ProcessId=\d+;MessageId=42" type="1" thread="\d+" file="" line="">'
    }

    It 'serializes repeated failures and logs recovery' {
        Write-ToastLog -Path $script:TestLogPath -Level Error -Component 'Client' -RunId $script:TestRunId `
            -ErrorKey 'SQL' -Message 'SQL poll failed (SqlException).'
        Write-ToastLog -Path $script:TestLogPath -Level Error -Component 'Client' -RunId $script:TestRunId `
            -ErrorKey 'SQL' -Message 'SQL poll failed (SqlException).'

        InModuleScope ToastLogging -Parameters @{ Path = $script:TestLogPath; RunId = $script:TestRunId } {
            $key = "$Path|Client|$RunId|SQL|SQL poll failed (SqlException)."
            $global:ToastMessengerLogErrorState[$key].LastSummaryUtc = [DateTimeOffset]::UtcNow.AddMinutes(-6)
            Write-ToastLog -Path $Path -Level Error -Component 'Client' -RunId $RunId `
                -ErrorKey 'SQL' -Message 'SQL poll failed (SqlException).'
            Clear-ToastLogError -Path $Path -Component 'Client' -RunId $RunId -ErrorKey 'SQL'
        }

        $lines = @(Get-Content -LiteralPath $script:TestLogPath)
        $lines.Count | Should -Be 3
        $lines[1] | Should -Match 'Repeated error persists \(2 occurrences\)'
        $lines[2] | Should -Match 'Recovered after SQL errors'
    }

    It 'rotates at the configured size and retains no more than five archives' {
        InModuleScope ToastLogging -Parameters @{ Path = $script:TestLogPath; RunId = $script:TestRunId } {
            $script:ToastLogMaxBytes = 300
            try {
                foreach ($index in 1..30) {
                    Write-ToastLog -Path $Path -Level Info -Component 'Client' -RunId $RunId -Message ('x' * 90)
                }
            } finally {
                $script:ToastLogMaxBytes = 10MB
            }
        }

        @(Get-ChildItem -LiteralPath $TestDrive -Filter 'Client.log.*' |
            Where-Object { $_.Name -match '^Client\.log\.\d+$' }).Count | Should -BeLessOrEqual 5
        (Get-Item -LiteralPath $script:TestLogPath).Length | Should -BeLessThan 300
    }
}
