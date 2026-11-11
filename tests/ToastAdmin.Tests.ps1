BeforeDiscovery {
    Import-Module (Join-Path $PSScriptRoot '../src/Module/ToastAdmin.psm1') -Force
}

Describe 'ToastAdmin GUI functions' {
    InModuleScope ToastAdmin {
        BeforeAll {
            Import-Module (Join-Path (Get-Module ToastAdmin).ModuleBase 'ToastLogging.psm1') -Force
            Import-Module (Join-Path (Get-Module ToastAdmin).ModuleBase 'ToastSql.psm1') -Force
            function Get-ADObject { param($Identity, $Properties) }
            function Get-ADGroupMember { param($Identity, [switch]$Recursive) }
            function Get-ADComputer { param($Filter, $SearchBase) }
        }

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
            Mock Get-ADObject { [pscustomobject]@{ ObjectClass = 'group' } }
            Mock Get-ADGroupMember {
                [pscustomobject]@{ Name = 'PC01'; ObjectClass = 'computer' }
                [pscustomobject]@{ Name = 'PC01'; ObjectClass = 'computer' }
                [pscustomobject]@{ Name = 'Person'; ObjectClass = 'user' }
            }
            Mock Get-ADComputer {}
        }

        It 'returns a queue object and forwards message options without parsing text' {
            $result = @(Send-ToastMessage -ConfigPath admin.psd1 -GroupName IT -Title Title -Subtitle Subtitle -Body Body -ActiveDuration 2 -DurationUnit Hours -RepeatIntervalMinutes 5 -RepeatCount 3 -CheckSqlPort:$false -Confirm:$false)
            $result.Count | Should -Be 1
            $result[0].MessageId | Should -Be 42
            $result[0].MessageId | Should -BeOfType ([long])
            $result[0].GroupName | Should -Be 'IT'
            Should -Invoke Test-ToastSqlPort -Times 0
            Should -Invoke Invoke-ToastSql -Times 1 -Exactly -ParameterFilter {
                $Parameters.Subtitle -eq 'Subtitle' -and $Parameters.ActiveDuration -eq 2 -and
                $Parameters.DurationUnit -eq 'Hours' -and $Parameters.RepeatIntervalSeconds -eq 300 -and
                $Parameters.RepeatCount -eq 3
            }
        }

        It 'skips the whole send operation during WhatIf' {
            @(Send-ToastMessage -ConfigPath missing.psd1 -GroupName IT -Title Title -Body Body -ActiveDuration 2 -DurationUnit Hours -WhatIf).Count | Should -Be 0
            Should -Invoke Import-ToastConfig -Times 0
            Should -Invoke Test-ToastSqlPort -Times 0
            Should -Invoke Invoke-ToastSql -Times 0
            Should -Invoke Write-ToastLog -Times 0
        }

        It 'preserves sender validation and propagates SQL failures to GUI callers' {
            { Send-ToastMessage -ConfigPath admin.psd1 -GroupName IT -Title Title -Body Body } | Should -Throw '*exactly one*'
            Should -Invoke Invoke-ToastSql -Times 0
            Mock Invoke-ToastSql { throw 'SQL unavailable' }
            { Send-ToastMessage -ConfigPath admin.psd1 -GroupName IT -Title Title -Body Body -ActiveDuration 2 -DurationUnit Hours } | Should -Throw '*SQL unavailable*'
            Should -Invoke Write-ToastLog -Times 0 -ParameterFilter { $Message -eq 'Message queued successfully.' }
        }

        It 'returns recursive AD computer imports as objects and forwards SearchBase and Tag' {
            Mock Invoke-ToastSql {
                $table = [System.Data.DataTable]::new()
                if ($CommandText -like '*SELECT c.ComputerName*') {
                    [void]$table.Columns.Add('ComputerName', [string])
                    [void]$table.Rows.Add('PC01')
                }
                else {
                    [void]$table.Columns.Add('Changes', [int])
                    [void]$table.Rows.Add(1)
                }
                Write-Output -NoEnumerate $table
            }
            $result = @(Import-ToastADComputers -ConfigPath admin.psd1 -Tag ' IT ' -SearchBase 'CN=Pilot,DC=test' -Confirm:$false)
            $result.Count | Should -Be 1
            $result[0].ComputerName | Should -Be 'PC01'
            $result[0].Tag | Should -Be 'IT'
            Should -Invoke Get-ADGroupMember -Times 1 -Exactly -ParameterFilter { $Recursive -and $Identity -eq 'CN=Pilot,DC=test' }
            Should -Invoke Get-ADComputer -Times 0
            Should -Invoke Invoke-ToastSql -Times 2 -Exactly -ParameterFilter {
                $Parameters.GroupName -eq 'IT' -and ($Parameters.ComputerName -eq 'PC01' -or $null -eq $Parameters.ComputerName)
            }
        }

        It 'removes tag memberships for computers no longer in the AD group' {
            Mock Invoke-ToastSql {
                $table = [System.Data.DataTable]::new()
                if ($CommandText -like '*SELECT c.ComputerName*') {
                    [void]$table.Columns.Add('ComputerName', [string])
                    [void]$table.Rows.Add('PC01')
                    [void]$table.Rows.Add('PC02')
                }
                else {
                    [void]$table.Columns.Add('Changes', [int])
                    [void]$table.Rows.Add(1)
                }
                Write-Output -NoEnumerate $table
            }
            $result = @(Import-ToastADComputers -ConfigPath admin.psd1 -Tag IT -SearchBase 'CN=Pilot,DC=test' -Confirm:$false)
            $result.Count | Should -Be 1
            Should -Invoke Invoke-ToastSql -Times 1 -Exactly -ParameterFilter {
                $CommandText -like '*DELETE cg*' -and $Parameters.ComputerName -eq 'PC02' -and $Parameters.GroupName -eq 'IT'
            }
            Should -Invoke Invoke-ToastSql -Times 0 -Exactly -ParameterFilter {
                $CommandText -like '*DELETE cg*' -and $Parameters.ComputerName -eq 'PC01'
            }
        }

        It 'forwards import WhatIf without writing SQL' {
            Mock Invoke-ToastSql {
                $table = [System.Data.DataTable]::new()
                [void]$table.Columns.Add('ComputerName', [string])
                [void]$table.Rows.Add('PC01')
                [void]$table.Rows.Add('PC02')
                Write-Output -NoEnumerate $table
            }
            @(Import-ToastADComputers -ConfigPath admin.psd1 -Tag IT -SearchBase 'CN=Pilot,DC=test' -WhatIf).Count | Should -Be 0
            Should -Invoke Get-ADGroupMember -Times 1 -Exactly
            Should -Invoke Invoke-ToastSql -Times 1 -Exactly -ParameterFilter { $CommandText -like '*SELECT c.ComputerName*' }
            Should -Invoke Invoke-ToastSql -Times 0 -Exactly -ParameterFilter {
                $CommandText -like '*INSERT dbo.ToastClient*' -or $CommandText -like '*DELETE cg*'
            }
        }

        It 'forwards OU filters and propagates invalid AD selections before writes' {
            Mock Get-ADObject { [pscustomobject]@{ ObjectClass = 'organizationalUnit' } }
            Import-ToastADComputers -ConfigPath admin.psd1 -Tag IT -SearchBase 'OU=PCs,DC=test' -Filter 'Enabled -eq $true' -WarningAction SilentlyContinue
            Should -Invoke Get-ADComputer -Times 1 -Exactly -ParameterFilter {
                $Filter -eq 'Enabled -eq $true' -and $SearchBase -eq 'OU=PCs,DC=test'
            }
            Mock Get-ADObject { [pscustomobject]@{ ObjectClass = 'group' } }
            { Import-ToastADComputers -ConfigPath admin.psd1 -Tag IT -SearchBase 'CN=Pilot,DC=test' -Filter 'Enabled -eq $true' } | Should -Throw '*Filter cannot be used*'
            Should -Invoke Invoke-ToastSql -Times 0
        }
    }
}
