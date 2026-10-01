Set-StrictMode -Version Latest

$script:ToastSupportedDisplayModes = @('AppDeployToolkit')
$script:ToastDependencyOptions = @{
    AppDeployToolkitModulePath = $null
}
$script:ToastSupportedProtocolSchemes = @('http','https','mailto')
$script:ToastSupportedScenarios = @('Default','Reminder','Alarm','IncomingCall')
$script:ToastSqlNullParameterDefinitions = @{
    GroupName = @{ SqlDbType = [System.Data.SqlDbType]::NVarChar; Size = 128 }
    Title = @{ SqlDbType = [System.Data.SqlDbType]::NVarChar; Size = 200 }
    Subtitle = @{ SqlDbType = [System.Data.SqlDbType]::NVarChar; Size = 200 }
    Body = @{ SqlDbType = [System.Data.SqlDbType]::NVarChar; Size = 4000 }
    AppLogoPath = @{ SqlDbType = [System.Data.SqlDbType]::NVarChar; Size = 1024 }
    HeroImagePath = @{ SqlDbType = [System.Data.SqlDbType]::NVarChar; Size = 1024 }
    AppLogoBytes = @{ SqlDbType = [System.Data.SqlDbType]::VarBinary; Size = -1 }
    HeroImageBytes = @{ SqlDbType = [System.Data.SqlDbType]::VarBinary; Size = -1 }
    AppLogoContentType = @{ SqlDbType = [System.Data.SqlDbType]::VarChar; Size = 100 }
    HeroImageContentType = @{ SqlDbType = [System.Data.SqlDbType]::VarChar; Size = 100 }
    Sound = @{ SqlDbType = [System.Data.SqlDbType]::VarChar; Size = 20 }
    IsUrgent = @{ SqlDbType = [System.Data.SqlDbType]::Bit }
    RepeatIntervalSeconds = @{ SqlDbType = [System.Data.SqlDbType]::Int }
    RepeatCount = @{ SqlDbType = [System.Data.SqlDbType]::Int }
    ButtonText = @{ SqlDbType = [System.Data.SqlDbType]::NVarChar; Size = 200 }
    AcknowledgeButtonText = @{ SqlDbType = [System.Data.SqlDbType]::NVarChar; Size = 200 }
    ButtonArguments = @{ SqlDbType = [System.Data.SqlDbType]::NVarChar; Size = 2048 }
    MessageId = @{ SqlDbType = [System.Data.SqlDbType]::BigInt }
    LeaseId = @{ SqlDbType = [System.Data.SqlDbType]::UniqueIdentifier }
    ExpiresUtc = @{ SqlDbType = [System.Data.SqlDbType]::DateTime2 }
    ButtonActivationType = @{ SqlDbType = [System.Data.SqlDbType]::VarChar; Size = 20 }
    DisplayMode = @{ SqlDbType = [System.Data.SqlDbType]::VarChar; Size = 20 }
    Scenario = @{ SqlDbType = [System.Data.SqlDbType]::VarChar; Size = 20 }
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

function Resolve-ToastButtonSettings {
    [CmdletBinding()]
    param(
        [string]$ButtonText,
        [string]$ButtonArguments,
        [ValidateSet('Protocol','Dismiss')][string]$ButtonActivationType
    )

    $normalizedButtonText = if ([string]::IsNullOrWhiteSpace($ButtonText)) { $null } else { $ButtonText.Trim() }
    $normalizedButtonArguments = if ([string]::IsNullOrWhiteSpace($ButtonArguments)) { $null } else { $ButtonArguments.Trim() }

    if (($null -eq $normalizedButtonText) -and ($null -ne $normalizedButtonArguments)) {
        throw 'ButtonText must be specified when ButtonArguments is provided.'
    }

    if (($null -eq $normalizedButtonText) -and [string]::IsNullOrWhiteSpace($ButtonActivationType)) {
        return @{
            ButtonText = $null
            ButtonArguments = $null
            ButtonActivationType = $null
        }
    }

    if ($null -eq $normalizedButtonText) {
        throw 'ButtonText is required when ButtonActivationType is specified.'
    }

    $normalizedButtonActivationType = if ([string]::IsNullOrWhiteSpace($ButtonActivationType)) { 'Protocol' } else { $ButtonActivationType }
    if ($normalizedButtonActivationType -eq 'Protocol') {
        if ($null -eq $normalizedButtonArguments) {
            throw 'ButtonArguments is required when ButtonActivationType is Protocol.'
        }

        $buttonUri = $null
        if (
            -not [System.Uri]::TryCreate($normalizedButtonArguments, [System.UriKind]::Absolute, [ref]$buttonUri) -or
            [string]::IsNullOrWhiteSpace($buttonUri.Scheme) -or
            ($normalizedButtonArguments -notmatch '^[a-zA-Z][a-zA-Z0-9+.-]*:')
        ) {
            throw 'ButtonArguments must be a valid absolute URI when ButtonActivationType is Protocol.'
        }
    } elseif ($null -eq $normalizedButtonArguments) {
        # Dismiss buttons can omit arguments.
    }

    return @{
        ButtonText = $normalizedButtonText
        ButtonArguments = $normalizedButtonArguments
        ButtonActivationType = $normalizedButtonActivationType
    }
}

function Resolve-ToastAcknowledgeButtonText {
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyString()][string]$AcknowledgeButtonText,
        [AllowNull()][AllowEmptyString()][string]$ButtonText
    )

    if ([string]::IsNullOrWhiteSpace($AcknowledgeButtonText)) {
        return $null
    }

    $normalizedAcknowledgeButtonText = $AcknowledgeButtonText.Trim()
    if ($normalizedAcknowledgeButtonText.Length -gt 200) {
        throw 'AcknowledgeButtonText must be 200 characters or fewer.'
    }

    if (
        -not [string]::IsNullOrWhiteSpace($ButtonText) -and
        $normalizedAcknowledgeButtonText.Equals($ButtonText.Trim(), [System.StringComparison]::OrdinalIgnoreCase)
    ) {
        throw 'AcknowledgeButtonText must differ from ButtonText so the acknowledgement and action buttons can be distinguished.'
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

function Resolve-ToastScenario {
    [CmdletBinding()]
    param(
        [AllowNull()][string]$Scenario
    )

    $normalizedScenario = if ([string]::IsNullOrWhiteSpace($Scenario)) { 'Default' } else { $Scenario.Trim() }
    $resolvedScenario = $script:ToastSupportedScenarios | Where-Object { $_.Equals($normalizedScenario, [System.StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1
    if ($null -eq $resolvedScenario) {
        throw "Scenario must be one of: $($script:ToastSupportedScenarios -join ', ')."
    }

    return $resolvedScenario
}

function Resolve-ToastDisplayMode {
    [CmdletBinding()]
    param(
        [AllowNull()][string]$DisplayMode
    )

    $normalizedDisplayMode = if ([string]::IsNullOrWhiteSpace($DisplayMode)) { 'AppDeployToolkit' } else { $DisplayMode.Trim() }
    foreach ($supportedDisplayMode in $script:ToastSupportedDisplayModes) {
        if ($supportedDisplayMode.Equals($normalizedDisplayMode, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $supportedDisplayMode
        }
    }

    throw "DisplayMode must be one of: $($script:ToastSupportedDisplayModes -join ', ')."
}

function Set-ToastClientDependencyOptions {
    [CmdletBinding()]
    param(
        [string]$AppDeployToolkitModulePath
    )

    $script:ToastDependencyOptions = @{
        AppDeployToolkitModulePath = if ([string]::IsNullOrWhiteSpace($AppDeployToolkitModulePath)) { $null } else { $AppDeployToolkitModulePath.Trim() }
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

    foreach ($commandName in @('Show-ADTInstallationPrompt','Show-InstallationPrompt')) {
        $command = Get-Command -Name $commandName -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $command) {
            return $command
        }
    }

    return $null
}

function Test-ToastCommandParameterMandatory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Command,
        [Parameter(Mandatory)][string]$ParameterName
    )

    if (-not $Command.Parameters.ContainsKey($ParameterName)) {
        return $false
    }

    foreach ($attribute in $Command.Parameters[$ParameterName].Attributes) {
        if ($attribute -is [System.Management.Automation.ParameterAttribute] -and $attribute.Mandatory) {
            return $true
        }
    }

    return $false
}

function Ensure-ToastNotificationDependencies {
    [CmdletBinding()]
    param(
        [AllowNull()][string]$DisplayMode = 'AppDeployToolkit'
    )

    [void](Resolve-ToastDisplayMode -DisplayMode $DisplayMode)

    if ($null -ne (Get-ToastAppDeployToolkitPromptCommand)) {
        return
    }

    if (-not $script:ToastDependencyOptions.AppDeployToolkitModulePath) {
        throw "DisplayMode 'AppDeployToolkit' requires a locally packaged PSAppDeployToolkit copy. Configure AppDeployToolkitModulePath to a version-pinned manifest, bootstrap script, or containing folder before starting the client."
    }

    $importPath = Resolve-ToastDependencyImportPath `
        -DependencyPath $script:ToastDependencyOptions.AppDeployToolkitModulePath `
        -CandidateLeafNames @('PSAppDeployToolkit.psd1','PSAppDeployToolkit.psm1','AppDeployToolkitMain.psm1')
    Import-Module -Name $importPath -ErrorAction Stop

    if ($null -eq (Get-ToastAppDeployToolkitPromptCommand)) {
        throw "AppDeployToolkit dependency '$importPath' did not expose Show-ADTInstallationPrompt or Show-InstallationPrompt."
    }
}

function Resolve-ToastProtocolUri {
    [CmdletBinding()]
    param(
        [string]$ButtonArguments
    )

    if ([string]::IsNullOrWhiteSpace([string]$ButtonArguments)) {
        return $null
    }

    $normalizedButtonArguments = [string]$ButtonArguments
    if (-not [string]::IsNullOrWhiteSpace($normalizedButtonArguments)) {
        $normalizedButtonArguments = $normalizedButtonArguments.Trim()
    }

    $protocolUri = $null
    if (
        -not [System.Uri]::TryCreate($normalizedButtonArguments, [System.UriKind]::Absolute, [ref]$protocolUri) -or
        [string]::IsNullOrWhiteSpace($protocolUri.Scheme) -or
        ($normalizedButtonArguments -notmatch '^[a-zA-Z][a-zA-Z0-9+.-]*:')
    ) {
        return $null
    }

    if ($script:ToastSupportedProtocolSchemes -notcontains $protocolUri.Scheme.ToLowerInvariant()) {
        return $null
    }

    return $protocolUri
}

function Resolve-ToastAppDeployToolkitButtonSettings {
    [CmdletBinding()]
    param(
        [string]$ButtonText,
        [string]$ButtonArguments,
        [string]$ButtonActivationType
    )

    $buttonSettingsParameters = @{
        ButtonText = $ButtonText
        ButtonArguments = $ButtonArguments
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$ButtonActivationType)) {
        $buttonSettingsParameters['ButtonActivationType'] = [string]$ButtonActivationType
    }

    $buttonSettings = Resolve-ToastButtonSettings @buttonSettingsParameters
    $protocolUri = $null

    if ($buttonSettings.ButtonActivationType -eq 'Protocol') {
        $protocolUri = Resolve-ToastProtocolUri -ButtonArguments $buttonSettings.ButtonArguments
        if ($null -eq $protocolUri) {
            throw 'AppDeployToolkit protocol buttons support only absolute http, https, or mailto URIs.'
        }
    }

    return [pscustomobject]@{
        ButtonText = $buttonSettings.ButtonText
        ButtonArguments = $buttonSettings.ButtonArguments
        ButtonActivationType = $buttonSettings.ButtonActivationType
        ProtocolUri = $protocolUri
    }
}

function Resolve-ToastAppDeployToolkitPromptSelection {
    [CmdletBinding()]
    param(
        [AllowNull()]$Result,
        [string]$ActionButtonText,
        [string]$AcknowledgeButtonText = 'Acknowledge'
    )

    if ($null -eq $Result) {
        return 'Acknowledge'
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

    if ($Result -is [int] -or $Result -is [long] -or $Result -is [short] -or $Result -is [byte]) {
        $numericResult = [int]$Result
        if (-not [string]::IsNullOrWhiteSpace($ActionButtonText) -and $numericResult -eq 0) {
            return 'Action'
        }

        if ($numericResult -eq 1) {
            return 'Acknowledge'
        }
    }

    foreach ($value in $valuesToInspect) {
        $normalizedValue = if ([string]::IsNullOrWhiteSpace($value)) { $null } else { $value.Trim() }
        if ($null -eq $normalizedValue) {
            continue
        }

        if (
            -not [string]::IsNullOrWhiteSpace($ActionButtonText) -and (
                $normalizedValue.Equals($ActionButtonText, [System.StringComparison]::OrdinalIgnoreCase) -or
                $normalizedValue.Equals('Left', [System.StringComparison]::OrdinalIgnoreCase) -or
                $normalizedValue.Equals('ButtonLeft', [System.StringComparison]::OrdinalIgnoreCase) -or
                $normalizedValue.Equals('Action', [System.StringComparison]::OrdinalIgnoreCase) -or
                $normalizedValue.Equals('Primary', [System.StringComparison]::OrdinalIgnoreCase) -or
                $normalizedValue.Equals('0', [System.StringComparison]::OrdinalIgnoreCase)
            )
        ) {
            return 'Action'
        }

        if (
            $normalizedValue.Equals($AcknowledgeButtonText, [System.StringComparison]::OrdinalIgnoreCase) -or
            $normalizedValue.Equals('Right', [System.StringComparison]::OrdinalIgnoreCase) -or
            $normalizedValue.Equals('ButtonRight', [System.StringComparison]::OrdinalIgnoreCase) -or
            $normalizedValue.Equals('OK', [System.StringComparison]::OrdinalIgnoreCase) -or
            $normalizedValue.Equals('Acknowledge', [System.StringComparison]::OrdinalIgnoreCase) -or
            $normalizedValue.Equals('1', [System.StringComparison]::OrdinalIgnoreCase)
        ) {
            return 'Acknowledge'
        }
    }

    return 'Acknowledge'
}

function Get-ToastAppDeployToolkitSubtitle {
    [CmdletBinding()]
    param(
        [AllowNull()][string]$Body
    )

    if (-not [string]::IsNullOrWhiteSpace($Body)) {
        $bodyLines = [string]$Body -split "`r`n|`n|`r"
        foreach ($bodyLine in $bodyLines) {
            if (-not [string]::IsNullOrWhiteSpace($bodyLine)) {
                return $bodyLine.Trim()
            }
        }
    }

    return 'Notification'
}

function Show-ToastAppDeployToolkitPrompt {
    [CmdletBinding()]
    param(
        [AllowNull()][long]$MessageId,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Title,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Body,
        [AllowNull()][AllowEmptyString()][string]$Subtitle,
        [string]$ButtonText,
        [string]$ButtonArguments,
        [string]$ButtonActivationType,
        [AllowNull()][AllowEmptyString()][string]$AcknowledgeButtonText
    )

    Ensure-ToastNotificationDependencies -DisplayMode 'AppDeployToolkit'
    $promptCommand = Get-ToastAppDeployToolkitPromptCommand
    if ($null -eq $promptCommand) {
        throw "AppDeployToolkit display mode could not find Show-ADTInstallationPrompt or Show-InstallationPrompt after dependency loading."
    }

    $buttonSettings = Resolve-ToastAppDeployToolkitButtonSettings `
        -ButtonText $ButtonText `
        -ButtonArguments $ButtonArguments `
        -ButtonActivationType $ButtonActivationType

    $resolvedAcknowledgeButtonText = Resolve-ToastAcknowledgeButtonText `
        -AcknowledgeButtonText $AcknowledgeButtonText `
        -ButtonText $buttonSettings.ButtonText
    if ($null -eq $resolvedAcknowledgeButtonText) {
        $resolvedAcknowledgeButtonText = 'Acknowledge'
    }

    $subtitleFallback = Get-ToastAppDeployToolkitSubtitle -Body $Body
    $titleIsMandatory = Test-ToastCommandParameterMandatory -Command $promptCommand -ParameterName 'Title'
    $subtitleIsMandatory = Test-ToastCommandParameterMandatory -Command $promptCommand -ParameterName 'Subtitle'
    $promptParameters = @{
        Message = [string]$Body
    }

    if ($promptCommand.Parameters.Keys -contains 'ButtonRightText') {
        $promptParameters['ButtonRightText'] = $resolvedAcknowledgeButtonText
    }

    if ($promptCommand.Parameters.Keys -contains 'Title') {
        if (-not [string]::IsNullOrWhiteSpace($Title)) {
            $promptParameters['Title'] = [string]$Title
        } elseif ($titleIsMandatory) {
            $promptParameters['Title'] = $subtitleFallback
        }
    }

    if ($promptCommand.Parameters.Keys -contains 'Subtitle') {
        if (-not [string]::IsNullOrWhiteSpace($Subtitle)) {
            $promptParameters['Subtitle'] = [string]$Subtitle
        } elseif ($subtitleIsMandatory) {
            $promptParameters['Subtitle'] = $subtitleFallback
        }
    }

    foreach ($iconMapping in @(
        @{ ParameterName = 'Icon'; Value = 'Information' },
        @{ ParameterName = 'IconType'; Value = 'Information' },
        @{ ParameterName = 'MessageBoxIcon'; Value = 64 }
    )) {
        if ($promptCommand.Parameters.Keys -contains $iconMapping.ParameterName) {
            $promptParameters[$iconMapping.ParameterName] = $iconMapping.Value
            break
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($buttonSettings.ButtonText)) {
        if ($promptCommand.Parameters.Keys -contains 'ButtonLeftText') {
            $promptParameters['ButtonLeftText'] = [string]$buttonSettings.ButtonText
        } else {
            Write-Warning ("AppDeployToolkit prompt command '{0}' does not support ButtonLeftText; omitting action button '{1}' for MessageId {2}." -f $promptCommand.Name, $buttonSettings.ButtonText, $MessageId)
        }
    }

    try {
        $result = & $promptCommand @promptParameters
    } catch {
        throw [System.Exception]::new("AppDeployToolkit prompt execution failed for MessageId ${MessageId}.", $_.Exception)
    }
    $selection = Resolve-ToastAppDeployToolkitPromptSelection `
        -Result $result `
        -ActionButtonText $buttonSettings.ButtonText `
        -AcknowledgeButtonText $resolvedAcknowledgeButtonText

    if ($selection -eq 'Action' -and $buttonSettings.ButtonActivationType -eq 'Protocol') {
        Write-Verbose ("Launching protocol action for MessageId {0}: {1}" -f $MessageId, $buttonSettings.ProtocolUri.AbsoluteUri)
        $protocolActionError = Invoke-ToastProtocolAction -ButtonArguments $buttonSettings.ProtocolUri.AbsoluteUri
        if (-not [string]::IsNullOrWhiteSpace($protocolActionError)) {
            throw "Failed to open AppDeployToolkit action '$($buttonSettings.ProtocolUri.AbsoluteUri)' for MessageId ${MessageId}: $protocolActionError"
        }
    }

    $resultType = switch ($selection) {
        'Action' {
            if ($buttonSettings.ButtonActivationType -eq 'Dismiss') { 'Dismiss' } else { 'Action' }
            break
        }
        default { 'Acknowledge' }
    }

    return [pscustomobject]@{
        Selection = $selection
        ResultType = $resultType
        ButtonActivationType = $buttonSettings.ButtonActivationType
    }
}

function Invoke-ToastProtocolAction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ButtonArguments
    )

    try {
        $protocolUri = Resolve-ToastProtocolUri -ButtonArguments $ButtonArguments
        if ($null -eq $protocolUri) {
            throw 'Protocol actions support only absolute http, https, or mailto URIs.'
        }

        $startAsUserCommand = Get-Command -Name 'Start-ADTProcessAsUser' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -eq $startAsUserCommand) {
            Write-Warning "AppDeployToolkit command 'Start-ADTProcessAsUser' is not available; opening '$($protocolUri.AbsoluteUri)' with Start-Process in the current session instead."
            Start-Process -FilePath $protocolUri.AbsoluteUri -ErrorAction Stop | Out-Null
            return $null
        }

        # explorer.exe hands the URI to the user's default browser/protocol handler.
        $shellPath = [System.IO.Path]::Combine([System.Environment]::GetFolderPath('Windows'), 'explorer.exe')
        & $startAsUserCommand `
            -FilePath $shellPath `
            -ArgumentList @($protocolUri.AbsoluteUri) `
            -NoWait `
            -ErrorAction Stop | Out-Null
        return $null
    } catch {
        return $_.Exception.Message
    }
}

function Invoke-ToastNotification {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$ToastRow
    )

    $displayModeValue = Get-ToastObjectPropertyValue -InputObject $ToastRow -PropertyName 'DisplayMode'
    [void](Resolve-ToastDisplayMode -DisplayMode $displayModeValue)
    Ensure-ToastNotificationDependencies -DisplayMode $displayModeValue

    Show-ToastAppDeployToolkitPrompt `
        -MessageId (Get-ToastObjectPropertyValue -InputObject $ToastRow -PropertyName 'MessageId') `
        -Title ([string](Get-ToastObjectPropertyValue -InputObject $ToastRow -PropertyName 'Title')) `
        -Body ([string](Get-ToastObjectPropertyValue -InputObject $ToastRow -PropertyName 'Body')) `
        -Subtitle ([string](Get-ToastObjectPropertyValue -InputObject $ToastRow -PropertyName 'Subtitle')) `
        -ButtonText ([string](Get-ToastObjectPropertyValue -InputObject $ToastRow -PropertyName 'ButtonText')) `
        -ButtonArguments ([string](Get-ToastObjectPropertyValue -InputObject $ToastRow -PropertyName 'ButtonArguments')) `
        -ButtonActivationType ([string](Get-ToastObjectPropertyValue -InputObject $ToastRow -PropertyName 'ButtonActivationType')) `
        -AcknowledgeButtonText ([string](Get-ToastObjectPropertyValue -InputObject $ToastRow -PropertyName 'AcknowledgeButtonText')) | Out-Null
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

Export-ModuleMember -Function Import-ToastConfig,Test-ToastSqlPort,Get-ToastConnectionString,Get-ToastSqlCredential,Invoke-ToastSql,Resolve-ToastRepeatSettings,Resolve-ToastButtonSettings,Resolve-ToastAcknowledgeButtonText,Resolve-ToastScenario,Resolve-ToastDisplayMode,Invoke-ToastNotification,Set-ToastClientDependencyOptions
