Set-StrictMode -Version Latest

$script:ToastDependencyOptions = @{
    AppDeployToolkitModulePath = $null
    RunAsSystem = $false
}
$script:ToastSqlNullParameterDefinitions = @{
    GroupName = @{ SqlDbType = [System.Data.SqlDbType]::NVarChar; Size = 128 }
    Title = @{ SqlDbType = [System.Data.SqlDbType]::NVarChar; Size = 200 }
    Subtitle = @{ SqlDbType = [System.Data.SqlDbType]::NVarChar; Size = 200 }
    Body = @{ SqlDbType = [System.Data.SqlDbType]::NVarChar; Size = 4000 }
    RepeatIntervalSeconds = @{ SqlDbType = [System.Data.SqlDbType]::Int }
    RepeatCount = @{ SqlDbType = [System.Data.SqlDbType]::Int }
    AcknowledgeButtonText = @{ SqlDbType = [System.Data.SqlDbType]::NVarChar; Size = 200 }
    MessageId = @{ SqlDbType = [System.Data.SqlDbType]::BigInt }
    ExpiresUtc = @{ SqlDbType = [System.Data.SqlDbType]::DateTime2 }
    ActiveDuration = @{ SqlDbType = [System.Data.SqlDbType]::Int }
    DurationUnit = @{ SqlDbType = [System.Data.SqlDbType]::VarChar; Size = 10 }
}

function Get-ToastSqlCredentialValues {
    param(
        [Parameter(Mandatory)]$SqlCredential,
        [string]$Path = 'configuration'
    )

    if ($SqlCredential -is [pscredential]) {
        return @{
            UserName = $SqlCredential.UserName
            Password = $SqlCredential.GetNetworkCredential().Password
        }
    }

    if ($SqlCredential -is [System.Collections.IDictionary]) {
        $missing = @('UserName','Password' | Where-Object { $SqlCredential.Keys -notcontains $_ })
        if ($missing.Count -gt 0) {
            throw "Config file '$Path' setting SqlCredential must define: $($missing -join ', ') when UseIntegratedSecurity = `$false."
        }

        if ([string]::IsNullOrWhiteSpace([string]$SqlCredential['UserName']) -or [string]::IsNullOrWhiteSpace([string]$SqlCredential['Password'])) {
            throw "Config file '$Path' setting SqlCredential must contain non-empty UserName and Password values when UseIntegratedSecurity = `$false."
        }

        return @{
            UserName = [string]$SqlCredential['UserName']
            Password = [string]$SqlCredential['Password']
        }
    }

    throw "Config file '$Path' setting SqlCredential must be a PSCredential or a hashtable with UserName and Password when UseIntegratedSecurity = `$false."
}

function ConvertTo-ToastPositiveInt {
    param(
        [Parameter(Mandatory)]$Value,
        [Parameter(Mandatory)][string]$SettingName,
        [string]$Path = 'configuration'
    )

    $isIntegral = $Value -is [byte] -or
        $Value -is [sbyte] -or
        $Value -is [int16] -or
        $Value -is [uint16] -or
        $Value -is [int32] -or
        $Value -is [uint32] -or
        $Value -is [int64] -or
        $Value -is [uint64]

    if (-not $isIntegral) {
        throw "Config file '$Path' setting $SettingName must be a positive integer."
    }

    if ($Value -is [uint64]) {
        if ($Value -gt [uint64][int]::MaxValue) {
            throw "Config file '$Path' setting $SettingName must be a positive integer."
        }

        $normalizedValue = [int]$Value
    } else {
        $wideValue = [long]$Value
        if ($wideValue -gt [int]::MaxValue) {
            throw "Config file '$Path' setting $SettingName must be a positive integer."
        }

        $normalizedValue = [int]$wideValue
    }

    if ($normalizedValue -le 0) {
        throw "Config file '$Path' setting $SettingName must be a positive integer."
    }

    return $normalizedValue
}

function Resolve-ToastRepeatSettings {
    [CmdletBinding()]
    param(
        [Nullable[int]]$RepeatIntervalSeconds,
        [Nullable[int]]$RepeatIntervalMinutes,
        [Nullable[int]]$RepeatCount
    )

    $hasSeconds = $PSBoundParameters.ContainsKey('RepeatIntervalSeconds') -and $null -ne $RepeatIntervalSeconds
    $hasMinutes = $PSBoundParameters.ContainsKey('RepeatIntervalMinutes') -and $null -ne $RepeatIntervalMinutes
    $hasCount = $PSBoundParameters.ContainsKey('RepeatCount') -and $null -ne $RepeatCount

    if ($hasSeconds -and $hasMinutes) {
        throw 'Specify either RepeatIntervalSeconds or RepeatIntervalMinutes, not both.'
    }

    if (($hasSeconds -or $hasMinutes) -and -not $hasCount) {
        throw 'RepeatCount is required when a repeat interval is specified.'
    }

    if ($hasCount -and -not ($hasSeconds -or $hasMinutes)) {
        throw 'RepeatIntervalSeconds or RepeatIntervalMinutes is required when RepeatCount is specified.'
    }

    if (-not $hasCount) {
        return @{
            RepeatIntervalSeconds = $null
            RepeatCount = $null
        }
    }

    $normalizedRepeatCount = ConvertTo-ToastPositiveInt -Value $RepeatCount -SettingName 'RepeatCount'
    if ($normalizedRepeatCount -lt 2) {
        throw 'RepeatCount must be 2 or greater because it includes the first display. Omit repeat settings for a one-time toast.'
    }

    if ($hasSeconds) {
        $normalizedRepeatIntervalSeconds = ConvertTo-ToastPositiveInt -Value $RepeatIntervalSeconds -SettingName 'RepeatIntervalSeconds'
    } else {
        $normalizedRepeatIntervalMinutes = ConvertTo-ToastPositiveInt -Value $RepeatIntervalMinutes -SettingName 'RepeatIntervalMinutes'
        if ($normalizedRepeatIntervalMinutes -gt [math]::Floor([int]::MaxValue / 60)) {
            throw 'RepeatIntervalMinutes is too large.'
        }

        $normalizedRepeatIntervalSeconds = $normalizedRepeatIntervalMinutes * 60
    }

    return @{
        RepeatIntervalSeconds = $normalizedRepeatIntervalSeconds
        RepeatCount = $normalizedRepeatCount
    }
}

function Resolve-ToastAcknowledgeButtonText {
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyString()][string]$AcknowledgeButtonText
    )

    if ([string]::IsNullOrWhiteSpace($AcknowledgeButtonText)) {
        return 'Stäng'
    }

    $normalizedAcknowledgeButtonText = $AcknowledgeButtonText.Trim()
    if ($normalizedAcknowledgeButtonText.Length -gt 200) {
        throw 'AcknowledgeButtonText must be 200 characters or fewer.'
    }
    if ($normalizedAcknowledgeButtonText -eq 'Timeout') {
        throw 'AcknowledgeButtonText cannot be Timeout because it is reserved by AppDeployToolkit.'
    }

    return $normalizedAcknowledgeButtonText
}

function Resolve-ToastQueueResult {
    [CmdletBinding()]
    param(
        [AllowNull()]$Result
    )

    if ($null -eq $Result) {
        throw 'Queue toast message SQL command returned no result set.'
    }

    if ($Result -is [System.Data.DataTable]) {
        if ($Result.Rows.Count -eq 0) {
            throw 'Queue toast message SQL command returned no rows.'
        }

        if (-not $Result.Columns.Contains('MessageId')) {
            throw 'Queue toast message SQL result must include a MessageId column.'
        }

        $messageId = $Result.Rows[0]['MessageId']
        if ($null -eq $messageId -or $messageId -is [System.DBNull]) {
            throw 'Queue toast message SQL result contained a null MessageId value.'
        }

        return [pscustomobject]@{
            MessageId = [long]$messageId
        }
    }

    if ($Result -is [System.Data.DataRow]) {
        if (-not $Result.Table.Columns.Contains('MessageId')) {
            throw 'Queue toast message SQL result must include a MessageId column.'
        }

        $messageId = $Result['MessageId']
        if ($null -eq $messageId -or $messageId -is [System.DBNull]) {
            throw 'Queue toast message SQL result contained a null MessageId value.'
        }

        return [pscustomobject]@{
            MessageId = [long]$messageId
        }
    }

    $messageIdProperty = $Result.PSObject.Properties['MessageId']
    if ($null -eq $messageIdProperty) {
        throw 'Queue toast message SQL result must expose a MessageId value.'
    }

    $messageId = $messageIdProperty.Value
    if ($null -eq $messageId -or $messageId -is [System.DBNull]) {
        throw 'Queue toast message SQL result contained a null MessageId value.'
    }

    return [pscustomobject]@{
        MessageId = [long]$messageId
    }
}

function Resolve-ToastExpirySettings {
    [CmdletBinding()]
    param(
        [AllowNull()]$ExpiresUtc,
        [AllowNull()]$ActiveDuration,
        [AllowNull()][AllowEmptyString()][string]$DurationUnit,
        [datetimeoffset]$Now = [datetimeoffset]::UtcNow
    )
    $hasExpiry = $null -ne $ExpiresUtc
    $hasDuration = $null -ne $ActiveDuration
    $hasUnit = -not [string]::IsNullOrWhiteSpace($DurationUnit)
    if ($hasExpiry -eq ($hasDuration -or $hasUnit)) {
        throw 'Specify exactly one of ExpiresUtc or ActiveDuration with DurationUnit.'
    }
    if ($hasExpiry) {
        if ($ExpiresUtc -is [datetimeoffset]) {
            $expiry = $ExpiresUtc
        } elseif ($ExpiresUtc -is [datetime] -and $ExpiresUtc.Kind -ne [DateTimeKind]::Unspecified) {
            $expiry = [datetimeoffset]$ExpiresUtc
        } elseif ($ExpiresUtc -is [string] -and $ExpiresUtc.Trim() -match '(?i)T.*(?:Z|[+-]\d{2}:\d{2})$') {
            $expiry = [datetimeoffset]::Parse($ExpiresUtc, [cultureinfo]::InvariantCulture)
        } else {
            throw 'ExpiresUtc must be a DateTimeOffset, a zoned DateTime, or an ISO 8601 string with Z or an explicit timezone offset.'
        }
        if ($expiry -le $Now) { throw 'ExpiresUtc must be in the future.' }
        return @{ ExpiresUtc = $expiry.UtcDateTime; ActiveDuration = $null; DurationUnit = $null }
    }
    if (-not ($hasDuration -and $hasUnit)) { throw 'ActiveDuration and DurationUnit are required together.' }
    $duration = ConvertTo-ToastPositiveInt -Value $ActiveDuration -SettingName 'ActiveDuration'
    if ($DurationUnit -notin @('Days','Hours','Minutes')) { throw 'DurationUnit must be Days, Hours, or Minutes.' }
    $unit = @('Days','Hours','Minutes') | Where-Object { $_ -eq $DurationUnit }
    return @{ ExpiresUtc = $null; ActiveDuration = $duration; DurationUnit = $unit }
}

function Set-ToastClientDependencyOptions {
    [CmdletBinding()]
    param(
        [string]$AppDeployToolkitModulePath,
        [switch]$RunAsSystem
    )

    $script:ToastDependencyOptions = @{
        AppDeployToolkitModulePath = if ([string]::IsNullOrWhiteSpace($AppDeployToolkitModulePath)) { $null } else { $AppDeployToolkitModulePath.Trim() }
        RunAsSystem = [bool]$RunAsSystem
    }
}

function Resolve-ToastDependencyImportPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DependencyPath,
        [Parameter(Mandatory)][string[]]$CandidateLeafNames
    )

    if (-not (Test-Path -LiteralPath $DependencyPath)) {
        throw "Configured dependency path '$DependencyPath' was not found."
    }

    $resolvedDependencyPath = (Resolve-Path -LiteralPath $DependencyPath -ErrorAction Stop | Select-Object -First 1 -ExpandProperty Path)
    $dependencyItem = Get-Item -LiteralPath $resolvedDependencyPath -ErrorAction Stop
    if (-not $dependencyItem.PSIsContainer) {
        return $resolvedDependencyPath
    }

    foreach ($candidateLeafName in $CandidateLeafNames) {
        $topLevelCandidatePath = Join-Path $resolvedDependencyPath $candidateLeafName
        if (Test-Path -LiteralPath $topLevelCandidatePath -PathType Leaf) {
            return (Resolve-Path -LiteralPath $topLevelCandidatePath -ErrorAction Stop | Select-Object -First 1 -ExpandProperty Path)
        }
    }

    $candidatePriority = @{}
    for ($index = 0; $index -lt $CandidateLeafNames.Count; $index++) {
        $candidatePriority[$CandidateLeafNames[$index]] = $index
    }

    $candidate = Get-ChildItem -LiteralPath $resolvedDependencyPath -Recurse -Depth 3 -File -ErrorAction SilentlyContinue |
        Where-Object { $CandidateLeafNames -contains $_.Name } |
        Sort-Object @{ Expression = { ($_.FullName -split '[\\/]').Count } }, @{ Expression = { $candidatePriority[$_.Name] } }, FullName |
        Select-Object -First 1
    if ($null -ne $candidate) {
        return $candidate.FullName
    }

    throw "Configured dependency path '$resolvedDependencyPath' does not contain any of: $($CandidateLeafNames -join ', ')."
}

function Get-ToastAppDeployToolkitPromptCommand {
    [CmdletBinding()]
    param()

    $commandNames = if ($script:ToastDependencyOptions.RunAsSystem) { @('Show-ADTInstallationPrompt') } else { @('Show-ADTInstallationPrompt','Show-InstallationPrompt') }
    foreach ($commandName in $commandNames) {
        $command = Get-Command -Name $commandName -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $command) {
            return $command
        }
    }

    return $null
}

function Ensure-ToastNotificationDependencies {
    [CmdletBinding()]
    param()

    if ($null -ne (Get-ToastAppDeployToolkitPromptCommand)) {
        return
    }

    if (-not $script:ToastDependencyOptions.AppDeployToolkitModulePath) {
        throw "A locally packaged PSAppDeployToolkit copy is required. Configure AppDeployToolkitModulePath to a version-pinned manifest, bootstrap script, or containing folder before starting the client."
    }

    $importPath = Resolve-ToastDependencyImportPath `
        -DependencyPath $script:ToastDependencyOptions.AppDeployToolkitModulePath `
        -CandidateLeafNames @('PSAppDeployToolkit.psd1','PSAppDeployToolkit.psm1','AppDeployToolkitMain.psm1')
    Import-Module -Name $importPath -ErrorAction Stop

    if ($null -eq (Get-ToastAppDeployToolkitPromptCommand)) {
        throw "AppDeployToolkit dependency '$importPath' did not expose a supported prompt. SYSTEM requires Show-ADTInstallationPrompt with session bridging (use the bundled PSAppDeployToolkit 4.1.8)."
    }
}

function Test-ToastSystemUserSession {
    [CmdletBinding()]
    param()

    foreach ($commandName in @('Get-ADTLoggedOnUser','Initialize-ADTModule','Get-ADTEnvironmentTable')) {
        if ($null -eq (Get-Command -Name $commandName -ErrorAction SilentlyContinue)) {
            throw "SYSTEM session handling requires $commandName. Configure the bundled PSAppDeployToolkit 4.1.8."
        }
    }

    if (@(Get-ADTLoggedOnUser -ErrorAction Stop | Where-Object IsActiveUserSession).Count -eq 0) {
        Write-Verbose 'No active user session; postponing the dialog.'
        return $false
    }

    # ADT caches its target session. Refresh it for every dialog, including after fast user switching.
    Initialize-ADTModule -ErrorAction Stop
    $target = (Get-ADTEnvironmentTable -ErrorAction Stop).RunAsActiveUser
    if ($null -eq $target) {
        Write-Verbose 'The active user logged off before the dialog could be shown.'
        return $false
    }
    $activeTarget = @(Get-ADTLoggedOnUser -ErrorAction Stop | Where-Object {
        $_.IsActiveUserSession -and $_.SessionId -eq $target.SessionId -and $_.SID -eq $target.SID
    })
    if ($activeTarget.Count -eq 0) {
        Write-Verbose 'The selected user session is no longer active; postponing the dialog.'
        return $false
    }
    return $true
}

function Resolve-ToastAppDeployToolkitPromptSelection {
    [CmdletBinding()]
    param(
        [AllowNull()]$Result,
        [string]$AcknowledgeButtonText = 'Stäng'
    )

    if ($null -eq $Result) {
        return 'Unknown'
    }

    $valuesToInspect = [System.Collections.Generic.List[string]]::new()
    if ($Result -is [string]) {
        $valuesToInspect.Add($Result)
    }

    foreach ($propertyName in @('Button','SelectedButton','Selection','Result','Value')) {
        $property = $Result.PSObject.Properties[$propertyName]
        if ($null -ne $property -and $null -ne $property.Value) {
            $valuesToInspect.Add([string]$property.Value)
        }
    }

    if (@($valuesToInspect | Where-Object { $_.Trim() -eq 'Timeout' }).Count -gt 0) { return 'Timeout' }
    foreach ($value in $valuesToInspect) {
        $normalizedValue = if ([string]::IsNullOrWhiteSpace($value)) { $null } else { $value.Trim() }
        if ($null -eq $normalizedValue) {
            continue
        }

        if (
            $normalizedValue.Equals($AcknowledgeButtonText, [System.StringComparison]::Ordinal)
        ) {
            return 'Acknowledge'
        }
    }

    return 'Unknown'
}

function ConvertTo-ToastPlainText {
    param([AllowNull()][AllowEmptyString()][string]$Text)
    # PSADT parses bracket tags ([url], [bold], etc.), not XML. A word joiner
    # preserves the visible bracket while preventing those tags from activating.
    return $Text.Replace('[', ('[' + [char]0x2060))
}

function Show-ToastAppDeployToolkitPrompt {
    [CmdletBinding()]
    param(
        [AllowNull()][long]$MessageId,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Title,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Body,
        [AllowNull()][AllowEmptyString()][string]$Subtitle,
        [AllowNull()][AllowEmptyString()][string]$AcknowledgeButtonText,
        [AllowNull()]$ExpiresUtc
    )

    Ensure-ToastNotificationDependencies
    $promptCommand = Get-ToastAppDeployToolkitPromptCommand
    if ($null -eq $promptCommand) {
        throw "AppDeployToolkit could not find Show-ADTInstallationPrompt or Show-InstallationPrompt after dependency loading."
    }
    if ($script:ToastDependencyOptions.RunAsSystem -and -not (Test-ToastSystemUserSession)) {
        return [pscustomobject]@{ Selection = 'NoActiveSession'; ResultType = 'NoActiveSession' }
    }

    $resolvedAcknowledgeButtonText = Resolve-ToastAcknowledgeButtonText -AcknowledgeButtonText $AcknowledgeButtonText
    foreach ($requiredParameter in @('Title','Message','ButtonRightText')) {
        if (-not $promptCommand.Parameters.ContainsKey($requiredParameter)) {
            throw "AppDeployToolkit prompt must support $requiredParameter."
        }
    }
    $promptParameters = @{
        Title = ConvertTo-ToastPlainText -Text $Title
        Message = ConvertTo-ToastPlainText -Text $Body
        ButtonRightText = $resolvedAcknowledgeButtonText
    }
    if ($promptCommand.Parameters.ContainsKey('Subtitle')) {
        $promptParameters['Subtitle'] = if ([string]::IsNullOrWhiteSpace($Subtitle)) { 'Meddelande' } else { ConvertTo-ToastPlainText -Text $Subtitle }
    } elseif (-not [string]::IsNullOrWhiteSpace($Subtitle)) {
        $promptParameters['Message'] = ConvertTo-ToastPlainText -Text ($Subtitle + "`r`n`r`n" + $Body)
    }
    if ($promptCommand.Parameters.ContainsKey('NoExitOnTimeout')) {
        $promptParameters['NoExitOnTimeout'] = $true
    }

    try {
        if ($PSBoundParameters.ContainsKey('ExpiresUtc') -and -not (Test-ToastRowUnexpired -ToastRow ([pscustomobject]@{ ExpiresUtc = $ExpiresUtc }))) {
            return [pscustomobject]@{ Selection = 'Expired'; ResultType = 'Expired' }
        }
        $result = & $promptCommand @promptParameters -ErrorAction Stop
    } catch {
        throw [System.Exception]::new("AppDeployToolkit prompt execution failed for MessageId ${MessageId}.", $_.Exception)
    }
    $selection = Resolve-ToastAppDeployToolkitPromptSelection `
        -Result $result `
        -AcknowledgeButtonText $resolvedAcknowledgeButtonText

    return [pscustomobject]@{
        Selection = $selection
        ResultType = $selection
    }
}

function Invoke-ToastNotification {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$ToastRow
    )

    Show-ToastAppDeployToolkitPrompt `
        -MessageId (Get-ToastObjectPropertyValue -InputObject $ToastRow -PropertyName 'MessageId') `
        -Title ([string](Get-ToastObjectPropertyValue -InputObject $ToastRow -PropertyName 'Title')) `
        -Body ([string](Get-ToastObjectPropertyValue -InputObject $ToastRow -PropertyName 'Body')) `
        -Subtitle ([string](Get-ToastObjectPropertyValue -InputObject $ToastRow -PropertyName 'Subtitle')) `
        -AcknowledgeButtonText ([string](Get-ToastObjectPropertyValue -InputObject $ToastRow -PropertyName 'AcknowledgeButtonText')) `
        -ExpiresUtc (Get-ToastObjectPropertyValue -InputObject $ToastRow -PropertyName 'ExpiresUtc')
}

function Test-ToastRowUnexpired {
    param(
        [Parameter(Mandatory)]$ToastRow,
        [datetime]$Now = [datetime]::UtcNow
    )
    $value = Get-ToastObjectPropertyValue -InputObject $ToastRow -PropertyName 'ExpiresUtc'
    if ($null -eq $value) { return $false }
    try {
        if ($value -is [datetimeoffset]) {
            $expiry = $value.UtcDateTime
        } elseif ($value -is [datetime]) {
            # SQL datetime2 has no Kind; this contract stores UTC, never server-local time.
            $expiry = if ($value.Kind -eq [DateTimeKind]::Unspecified) { [datetime]::SpecifyKind($value, [DateTimeKind]::Utc) } else { $value.ToUniversalTime() }
        } else {
            if ([string]$value -notmatch '(?i)T.*(?:Z|[+-]\d{2}:\d{2})$') { return $false }
            $expiry = [datetimeoffset]::Parse([string]$value, [cultureinfo]::InvariantCulture).UtcDateTime
        }
        return $expiry -gt $Now
    } catch { return $false }
}

function Get-ToastReadStatePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Server,
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][string]$Database,
        [Parameter(Mandatory)][string]$ComputerName
    )
    $scope = @($Server.ToLowerInvariant(), $Port, $Database.ToLowerInvariant(), $ComputerName.ToLowerInvariant()) | ConvertTo-Json -Compress
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $hash = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($scope))).Replace('-', '') }
    finally { $sha.Dispose() }
    return "HKLM:\Software\AppDeployToolkit-MessengerTool\ReadState\$hash"
}

function Get-ToastReadState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StatePath, [Parameter(Mandatory)][long]$MessageId)
    if (-not (Test-Path -LiteralPath $StatePath -ErrorAction Stop)) {
        return [pscustomobject]@{ Read = $false; ShowCount = 0; NextShowUtc = $null }
    }
    $properties = Get-ItemProperty -LiteralPath $StatePath -ErrorAction Stop
    $property = $properties.PSObject.Properties[[string]$MessageId]
    if ($null -eq $property) {
        return [pscustomobject]@{ Read = $false; ShowCount = 0; NextShowUtc = $null }
    }
    $state = $property.Value | ConvertFrom-Json -ErrorAction Stop
    if ($state.Read -isnot [bool] -or $state.ShowCount -isnot [long] -and $state.ShowCount -isnot [int] -or $state.ShowCount -lt 0) {
        throw "Invalid local read state for message $MessageId."
    }
    if ($null -ne $state.NextShowUtc) {
        $state.NextShowUtc = if ($state.NextShowUtc -is [datetime]) { $state.NextShowUtc.ToUniversalTime() } else {
            [datetime]::Parse($state.NextShowUtc, [cultureinfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
        }
    }
    return $state
}

function Write-ToastReadStateValue {
    param(
        [Parameter(Mandatory)][string]$StatePath,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Value
    )
    if ($StatePath -notmatch '^HKLM:\\Software\\AppDeployToolkit-MessengerTool\\ReadState\\[A-F0-9]{64}$') {
        throw 'Read-state writes must target a provisioned HKLM read-state scope.'
    }
    $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
    $key = $null
    try {
        # The registry provider requests CreateSubKey for writes; open with only SetValue instead.
        $key = $baseKey.OpenSubKey($StatePath.Substring(6), [Microsoft.Win32.RegistryKeyPermissionCheck]::Default, [System.Security.AccessControl.RegistryRights]::SetValue)
        if ($null -eq $key) { throw "Read-state scope '$StatePath' is not provisioned." }
        $key.SetValue($Name, $Value, [Microsoft.Win32.RegistryValueKind]::String)
    } finally {
        if ($null -ne $key) { $key.Dispose() }
        $baseKey.Dispose()
    }
}

function Set-ToastReadState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StatePath, [Parameter(Mandatory)][long]$MessageId, [Parameter(Mandatory)]$State)
    if (-not (Test-Path -LiteralPath $StatePath -ErrorAction Stop)) {
        throw "Read-state scope '$StatePath' is not provisioned. Run deploy\Initialize-ToastReadState.ps1 with the client configuration in an elevated 64-bit PowerShell session."
    }
    $nextShow = if ($null -ne $State.NextShowUtc) { $State.NextShowUtc.ToUniversalTime().ToString('o', [cultureinfo]::InvariantCulture) } else { $null }
    $json = @{ Read = [bool]$State.Read; ShowCount = [int]$State.ShowCount; NextShowUtc = $nextShow } | ConvertTo-Json -Compress
    Write-ToastReadStateValue -StatePath $StatePath -Name ([string]$MessageId) -Value $json
}

function New-ToastClientMutex {
    param([Parameter(Mandatory)][string]$Name)
    $security = [System.Security.AccessControl.MutexSecurity]::new()
    foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
        $security.AddAccessRule([System.Security.AccessControl.MutexAccessRule]::new(
            [System.Security.Principal.SecurityIdentifier]::new($sid),
            [System.Security.AccessControl.MutexRights]::FullControl,
            [System.Security.AccessControl.AccessControlType]::Allow))
    }
    $rights = [System.Security.AccessControl.MutexRights]::Synchronize -bor [System.Security.AccessControl.MutexRights]::Modify
    $security.AddAccessRule([System.Security.AccessControl.MutexAccessRule]::new(
        [System.Security.Principal.SecurityIdentifier]::new('S-1-5-4'), $rights,
        [System.Security.AccessControl.AccessControlType]::Allow))
    try {
        if ($PSVersionTable.PSEdition -eq 'Core') {
            return [System.Threading.MutexAcl]::OpenExisting($Name, $rights)
        }
        return [System.Threading.Mutex]::OpenExisting($Name, $rights)
    } catch [System.Threading.WaitHandleCannotBeOpenedException] {
        $created = $false
        try {
            if ($PSVersionTable.PSEdition -eq 'Core') {
                return [System.Threading.MutexAcl]::Create($false, $Name, [ref]$created, $security)
            }
            return [System.Threading.Mutex]::new($false, $Name, [ref]$created, $security)
        } catch [System.UnauthorizedAccessException] {
            # Another user's client may have created the mutex since OpenExisting.
            if ($PSVersionTable.PSEdition -eq 'Core') {
                return [System.Threading.MutexAcl]::OpenExisting($Name, $rights)
            }
            return [System.Threading.Mutex]::OpenExisting($Name, $rights)
        }
    }
}

function Invoke-ToastClientPass {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ConnectionString,
        [AllowNull()][System.Data.SqlClient.SqlCredential]$SqlCredential,
        [Parameter(Mandatory)][string]$ComputerName,
        [Parameter(Mandatory)][string]$StatePath,
        [int]$CommandTimeoutSeconds = 15
    )
    $mutex = New-ToastClientMutex -Name ('Global\ToastSql-' + ($StatePath -split '\\')[-1])
    $ownsMutex = $false
    try {
        try { $ownsMutex = $mutex.WaitOne(0) }
        catch [System.Threading.AbandonedMutexException] { $ownsMutex = $true }
        if ($ownsMutex) { Invoke-ToastClientPoll @PSBoundParameters }
    } finally {
        if ($ownsMutex) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Invoke-ToastClientPoll {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ConnectionString,
        [AllowNull()][System.Data.SqlClient.SqlCredential]$SqlCredential,
        [Parameter(Mandatory)][string]$ComputerName,
        [Parameter(Mandatory)][string]$StatePath,
        [int]$CommandTimeoutSeconds = 15
    )
    $sql = @{
        ConnectionString = $ConnectionString
        SqlCredential = $SqlCredential
        CommandText = 'EXEC dbo.usp_GetPendingToast @ComputerName, @MessageId'
        CommandTimeoutSeconds = $CommandTimeoutSeconds
    }
    # SQL returns every eligible message, so locally suppressed rows cannot fill a TOP (20) window.
    $rows = Invoke-ToastSql @sql -Parameters @{ ComputerName = $ComputerName; MessageId = $null }
    foreach ($row in $rows) {
        $state = Get-ToastReadState -StatePath $StatePath -MessageId $row.MessageId
        $repeatCount = Get-ToastObjectPropertyValue -InputObject $row -PropertyName 'RepeatCount'
        $limit = if ($null -eq $repeatCount) { 1 } else { [int]$repeatCount }
        if ($state.ShowCount -ge $limit -or ($null -ne $state.NextShowUtc -and $state.NextShowUtc -gt [datetime]::UtcNow)) { continue }
        # A previous blocking prompt may have outlived cancellation, membership, or expiry.
        $current = Invoke-ToastSql @sql -Parameters @{ ComputerName = $ComputerName; MessageId = [long]$row.MessageId }
        $currentRows = if ($current -is [System.Data.DataTable]) { @($current.Rows) } else { @($current | Where-Object { $null -ne $_ }) }
        if (@($currentRows).Count -eq 0) { continue }
        $row = @($currentRows)[0]
        # Check persistence before showing; a post-acknowledgement write error terminates polling rather than silently losing state.
        Set-ToastReadState -StatePath $StatePath -MessageId $row.MessageId -State $state
        if (-not (Test-ToastRowUnexpired -ToastRow $row)) { continue }
        try {
            $result = Invoke-ToastNotification -ToastRow $row
            if ($null -eq $result -or $result.ResultType -ne 'Acknowledge') {
                Write-Warning "Message $($row.MessageId) was not acknowledged; it remains unread."
                continue
            }
        } catch {
            Write-Warning "Message $($row.MessageId) remains unread: $($_.Exception.Message)"
            continue
        }
        $state.Read = $true
        $state.ShowCount++
        $interval = Get-ToastObjectPropertyValue -InputObject $row -PropertyName 'RepeatIntervalSeconds'
        $state.NextShowUtc = if ($null -ne $interval -and $state.ShowCount -lt $limit) { [datetime]::UtcNow.AddSeconds([int]$interval) } else { $null }
        Set-ToastReadState -StatePath $StatePath -MessageId $row.MessageId -State $state
    }
}

function Import-ToastConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string[]]$RequiredProperties = @(),
        [string[]]$NullableProperties = @(),
        [string[]]$NonEmptyProperties = @(),
        [switch]$ResolveClientName
    )

    try {
        $config = Import-PowerShellDataFile -Path $Path -ErrorAction Stop
    } catch {
        throw "Failed to load config file '$Path': $($_.Exception.Message) PowerShell data files (.psd1) must contain only static values supported by Import-PowerShellDataFile. Replace dynamic expressions with static values."
    }

    if ($config -isnot [System.Collections.IDictionary]) {
        throw "Config file '$Path' must contain a top-level hashtable/dictionary."
    }

    if ($config -isnot [hashtable]) {
        $normalizedConfig = @{}
        foreach ($key in $config.Keys) {
            $normalizedConfig[$key] = $config[$key]
        }

        $config = $normalizedConfig
    }

    $missing = @($RequiredProperties | Where-Object { -not $config.ContainsKey($_) })
    if ($missing.Count -gt 0) {
        throw "Config file '$Path' is missing required setting(s): $($missing -join ', '). Copy config/config.example.psd1 and define each setting explicitly."
    }

    $emptyRequired = @(
        $RequiredProperties |
            Where-Object { $_ -notin $NullableProperties } |
            Where-Object {
                $value = $config[$_]
                $null -eq $value -or ($value -is [string] -and [string]::IsNullOrWhiteSpace($value))
            }
    )
    if ($emptyRequired.Count -gt 0) {
        throw "Config file '$Path' has empty required setting(s): $($emptyRequired -join ', '). Set each required value explicitly or copy it from config/config.example.psd1."
    }

    $emptyCollections = @(
        $NonEmptyProperties |
            Where-Object {
                $value = $config[$_]
                $value -is [System.Array] -and $value.Count -eq 0
            }
    )
    if ($emptyCollections.Count -gt 0) {
        throw "Config file '$Path' must define at least one value for: $($emptyCollections -join ', ')."
    }

    foreach ($booleanSetting in @('UseIntegratedSecurity','Encrypt','TrustServerCertificate')) {
        if ($config.ContainsKey($booleanSetting) -and $config[$booleanSetting] -isnot [bool]) {
            throw "Config file '$Path' setting $booleanSetting must be `$true or `$false."
        }
    }

    foreach ($positiveIntegerSetting in @('ConnectTimeoutSeconds','CommandTimeoutSeconds')) {
        if ($config.ContainsKey($positiveIntegerSetting)) {
            $config[$positiveIntegerSetting] = ConvertTo-ToastPositiveInt -Value $config[$positiveIntegerSetting] -SettingName $positiveIntegerSetting -Path $Path
        }
    }

    if ($config.ContainsKey('UseIntegratedSecurity') -and -not $config['UseIntegratedSecurity']) {
        if (-not $config.ContainsKey('SqlCredential') -or $null -eq $config['SqlCredential']) {
            throw "Config file '$Path' sets UseIntegratedSecurity = `$false, so SqlCredential must be provided as a PSCredential or as a static hashtable with UserName and Password."
        }

        [void](Get-ToastSqlCredentialValues -SqlCredential $config['SqlCredential'] -Path $Path)
    }

    if ($ResolveClientName) {
        if (-not $config.ContainsKey('ClientName')) {
            throw "Config file '$Path' must define ClientName when automatic client-name resolution is enabled."
        }

        $clientName = $config['ClientName']
        if ($null -eq $clientName) {
            if ([string]::IsNullOrWhiteSpace($env:COMPUTERNAME)) {
                throw "Config file '$Path' leaves ClientName empty and the COMPUTERNAME environment variable is not available. Set ClientName explicitly or ensure COMPUTERNAME is defined."
            }

            $config['ClientName'] = $env:COMPUTERNAME
        } elseif ($clientName -isnot [string]) {
            throw "Config file '$Path' setting ClientName must be a string or `$null."
        } elseif ([string]::IsNullOrWhiteSpace($clientName)) {
            throw "Config file '$Path' setting ClientName must be a non-empty string or `$null."
        }
    }

    return $config
}

function Test-ToastSqlPort {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Server,[int]$Port=1433)

    $hostName = ($Server -split '\\|,')[0]
    if (-not (Test-NetConnection -ComputerName $hostName -Port $Port -InformationLevel Quiet -WarningAction SilentlyContinue)) {
        throw "TCP $Port to SQL Server '$hostName' is not reachable."
    }
}

function Get-ToastConnectionString {
    param([hashtable]$Config)

    foreach ($booleanSetting in @('UseIntegratedSecurity','Encrypt','TrustServerCertificate')) {
        if (-not $Config.ContainsKey($booleanSetting)) {
            throw "Config setting $booleanSetting is required."
        }

        if ($Config[$booleanSetting] -isnot [bool]) {
            throw "Config setting $booleanSetting must be `$true or `$false."
        }
    }

    $connectTimeoutSeconds = 15
    if ($Config.ContainsKey('ConnectTimeoutSeconds')) {
        $connectTimeoutSeconds = ConvertTo-ToastPositiveInt -Value $Config['ConnectTimeoutSeconds'] -SettingName 'ConnectTimeoutSeconds'
    }

    $builder = [System.Data.SqlClient.SqlConnectionStringBuilder]::new()
    $builder['Data Source'] = "tcp:$($Config.SqlServer),$($Config.SqlPort)"
    $builder['Initial Catalog'] = $Config.SqlDatabase
    $builder['Encrypt'] = $Config.Encrypt
    $builder['TrustServerCertificate'] = $Config.TrustServerCertificate
    $builder['Connect Timeout'] = $connectTimeoutSeconds

    if ($Config.UseIntegratedSecurity) {
        $builder['Integrated Security'] = $true
        return $builder.ConnectionString
    }

    $builder['Integrated Security'] = $false
    return $builder.ConnectionString
}

function Get-ToastSqlCredential {
    param([hashtable]$Config)

    if (-not $Config.ContainsKey('UseIntegratedSecurity')) {
        throw 'Config setting UseIntegratedSecurity is required.'
    }

    if ($Config['UseIntegratedSecurity']) {
        return $null
    }

    if (-not $Config.ContainsKey('SqlCredential') -or $null -eq $Config['SqlCredential']) {
        throw 'Config setting SqlCredential is required when UseIntegratedSecurity = $false.'
    }

    $values = Get-ToastSqlCredentialValues -SqlCredential $Config['SqlCredential']

    $securePassword = [System.Security.SecureString]::new()
    foreach ($character in $values.Password.ToCharArray()) {
        $securePassword.AppendChar($character)
    }
    $securePassword.MakeReadOnly()

    return [System.Data.SqlClient.SqlCredential]::new($values.UserName, $securePassword)
}

function Add-ToastSqlParameter {
    param(
        [Parameter(Mandatory)][System.Data.SqlClient.SqlCommand]$Command,
        [Parameter(Mandatory)][string]$Name,
        $Value
    )

    if ($null -eq $Value) {
        if ($script:ToastSqlNullParameterDefinitions.ContainsKey($Name)) {
            $parameterDefinition = $script:ToastSqlNullParameterDefinitions[$Name]
            if ($parameterDefinition.ContainsKey('Size')) {
                $p = $Command.Parameters.Add("@$Name", $parameterDefinition.SqlDbType, $parameterDefinition.Size)
            } else {
                $p = $Command.Parameters.Add("@$Name", $parameterDefinition.SqlDbType)
            }
        } else {
            $p = $Command.Parameters.Add("@$Name", [System.Data.SqlDbType]::NVarChar, 4000)
        }

        $p.Value = [System.DBNull]::Value
        return
    }

    if ($Value -is [byte[]]) {
        $p = $Command.Parameters.Add("@$Name", [System.Data.SqlDbType]::VarBinary, -1)
        $p.Value = $Value
        return
    }

    if ($Value -is [guid]) {
        $p = $Command.Parameters.Add("@$Name", [System.Data.SqlDbType]::UniqueIdentifier)
        $p.Value = $Value
        return
    }

    if ($Value -is [datetime]) {
        $p = $Command.Parameters.Add("@$Name", [System.Data.SqlDbType]::DateTime2)
        $p.Value = $Value
        return
    }

    if ($Value -is [bool]) {
        $p = $Command.Parameters.Add("@$Name", [System.Data.SqlDbType]::Bit)
        $p.Value = $Value
        return
    }

    if ($Value -is [byte] -or $Value -is [sbyte] -or $Value -is [int16] -or $Value -is [uint16] -or $Value -is [int32]) {
        $p = $Command.Parameters.Add("@$Name", [System.Data.SqlDbType]::Int)
        $p.Value = [int]$Value
        return
    }

    if ($Value -is [uint32] -or $Value -is [int64] -or $Value -is [uint64]) {
        if ($Value -is [uint64] -and $Value -gt [uint64][long]::MaxValue) {
            throw "SQL parameter '$Name' cannot exceed Int64::MaxValue."
        }

        $p = $Command.Parameters.Add("@$Name", [System.Data.SqlDbType]::BigInt)
        $p.Value = [long]$Value
        return
    }

    $stringValue = [string]$Value
    $parameterSize = if ($stringValue.Length -gt 4000) { -1 } else { [math]::Max(1, $stringValue.Length) }
    $p = $Command.Parameters.Add("@$Name", [System.Data.SqlDbType]::NVarChar, $parameterSize)
    $p.Value = $stringValue
}

function Get-ToastObjectPropertyValue {
    param(
        [Parameter(Mandatory)]$InputObject,
        [Parameter(Mandatory)][string]$PropertyName
    )

    if ($InputObject -is [System.Data.DataRow]) {
        if ($InputObject.Table.Columns.Contains($PropertyName)) {
            $value = $InputObject[$PropertyName]
            if ($value -is [System.DBNull]) {
                return $null
            }

            return ,$value
        }

        return $null
    }

    $properties = $InputObject.PSObject.Properties.Match($PropertyName)
    if ($properties.Count -gt 0) {
        $value = $properties[0].Value
        if ($value -is [System.DBNull]) {
            return $null
        }

        return ,$value
    }

    return $null
}

function Invoke-ToastSql {
    param(
        [string]$ConnectionString,
        [System.Data.SqlClient.SqlCredential]$SqlCredential,
        [string]$CommandText,
        [hashtable]$Parameters = @{},
        [ValidateRange(1,[int]::MaxValue)][int]$CommandTimeoutSeconds = 30,
        [switch]$NonQuery
    )

    $safeParameters = if ($null -ne $Parameters) { $Parameters } else { @{} }
    $connection = [System.Data.SqlClient.SqlConnection]::new($ConnectionString)
    $command = $null
    $reader = $null

    try {
        if ($null -ne $SqlCredential) {
            $connection.Credential = $SqlCredential
        }

        $connection.Open()
        $command = $connection.CreateCommand()
        $command.CommandText = $CommandText
        $command.CommandTimeout = $CommandTimeoutSeconds

        foreach ($name in $safeParameters.Keys) {
            Add-ToastSqlParameter -Command $command -Name $name -Value $safeParameters[$name]
        }

        if ($NonQuery) {
            [void]$command.ExecuteNonQuery()
            return
        }

        $reader = $command.ExecuteReader()
        $table = [System.Data.DataTable]::new()
        $table.Load($reader)
        Write-Output -NoEnumerate $table
        return
    }
    finally {
        if ($null -ne $reader) { $reader.Dispose() }
        if ($null -ne $command) { $command.Dispose() }
        $connection.Dispose()
    }
}

Export-ModuleMember -Function Import-ToastConfig,Test-ToastSqlPort,Get-ToastConnectionString,Get-ToastSqlCredential,Invoke-ToastSql,Resolve-ToastRepeatSettings,Resolve-ToastExpirySettings,Resolve-ToastAcknowledgeButtonText,Resolve-ToastQueueResult,Invoke-ToastNotification,Set-ToastClientDependencyOptions,Get-ToastReadStatePath,Get-ToastReadState,Set-ToastReadState,Invoke-ToastClientPass,Invoke-ToastClientPoll
