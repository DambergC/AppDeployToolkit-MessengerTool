[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConfigPath,
    [Parameter(Mandatory)][string]$GroupName,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Title,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Body,
    [AllowNull()][AllowEmptyString()][string]$Subtitle,
    [datetime]$ExpiresUtc,
    [switch]$Urgent,
    [Nullable[int]]$RepeatIntervalSeconds,
    [Nullable[int]]$RepeatIntervalMinutes,
    [Nullable[int]]$RepeatCount,
    [Parameter(HelpMessage='Optional text shown on the extra action button to the left of the acknowledgement button.')][string]$ButtonText,
    [Parameter(HelpMessage='Optional button argument. For Protocol buttons use an absolute http, https, or mailto URL, either raw or as JSON {"url":"https://..."}; it opens in the default browser/application of the logged-on user.')][string]$ButtonArguments,
    [Parameter(HelpMessage='Button activation type. Use Protocol to open a URI or Dismiss to close the toast.')][ValidateSet('Protocol','Dismiss')][string]$ButtonActivationType,
    [Parameter(HelpMessage='Optional text shown on the right acknowledgement button. Defaults to Acknowledge.')][AllowNull()][AllowEmptyString()][string]$AcknowledgeButtonText,
    [ValidateSet('Default','Reminder','Alarm','IncomingCall')][string]$Scenario = 'Default',
    [ValidateSet('AppDeployToolkit')][string]$DisplayMode = 'AppDeployToolkit'
)

Set-StrictMode -Version Latest

Import-Module "$PSScriptRoot\..\Module\ToastSql.psm1" -Force

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

$config = Import-ToastConfig -Path $ConfigPath -RequiredProperties @(
    'SqlServer','SqlDatabase','SqlPort','UseIntegratedSecurity','Encrypt',
    'TrustServerCertificate','ConnectTimeoutSeconds','CommandTimeoutSeconds'
)

Test-ToastSqlPort -Server $config.SqlServer -Port $config.SqlPort
$conn = Get-ToastConnectionString $config
$sqlCredential = Get-ToastSqlCredential $config

$repeatSettings = Resolve-ToastRepeatSettings `
    -RepeatIntervalSeconds $RepeatIntervalSeconds `
    -RepeatIntervalMinutes $RepeatIntervalMinutes `
    -RepeatCount $RepeatCount

$buttonParams = @{
    ButtonText = $ButtonText
    ButtonArguments = $ButtonArguments
}

if (-not [string]::IsNullOrWhiteSpace([string]$ButtonActivationType)) {
    $buttonParams.ButtonActivationType = $ButtonActivationType
}

$buttonSettings = Resolve-ToastButtonSettings @buttonParams
$resolvedAcknowledgeButtonText = Resolve-ToastAcknowledgeButtonText `
    -AcknowledgeButtonText $AcknowledgeButtonText `
    -ButtonText $(if ($null -ne $buttonSettings) { $buttonSettings.ButtonText } else { $null })

$params = @{
    GroupName = $GroupName
    Title = $Title
    Body = $Body
    Subtitle = $Subtitle
    ExpiresUtc = if ($ExpiresUtc) { $ExpiresUtc } else { $null }
    IsUrgent = $Urgent.IsPresent
    RepeatIntervalSeconds = if ($null -ne $repeatSettings) { $repeatSettings.RepeatIntervalSeconds } else { $null }
    RepeatCount = if ($null -ne $repeatSettings) { $repeatSettings.RepeatCount } else { $null }
    ButtonText = if ($null -ne $buttonSettings) { $buttonSettings.ButtonText } else { $null }
    ButtonArguments = if ($null -ne $buttonSettings) { $buttonSettings.ButtonArguments } else { $null }
    ButtonActivationType = if ($null -ne $buttonSettings) { $buttonSettings.ButtonActivationType } else { $null }
    Scenario = $Scenario
    DisplayMode = $DisplayMode
}

foreach ($parameterName in @(
    'GroupName','Title','Body','Subtitle','ExpiresUtc',
    'IsUrgent','RepeatIntervalSeconds','RepeatCount',
    'ButtonText','ButtonArguments','ButtonActivationType','Scenario','DisplayMode'
)) {
    if (-not $params.ContainsKey($parameterName)) {
        $params[$parameterName] = $null
    }
}

$sql = @'
EXEC dbo.usp_QueueToastMessage
    @GroupName = @GroupName,
    @Title = @Title,
    @Body = @Body,
    @Subtitle = @Subtitle,
    @ExpiresUtc = @ExpiresUtc,
    @IsUrgent = @IsUrgent,
    @RepeatIntervalSeconds = @RepeatIntervalSeconds,
    @RepeatCount = @RepeatCount,
    @ButtonText = @ButtonText,
    @ButtonArguments = @ButtonArguments,
    @ButtonActivationType = @ButtonActivationType,
    @Scenario = @Scenario,
    @DisplayMode = @DisplayMode
'@

# Only send @AcknowledgeButtonText when a custom label is requested so databases
# that have not yet been upgraded keep working for default acknowledgement buttons.
if ($null -ne $resolvedAcknowledgeButtonText) {
    $params['AcknowledgeButtonText'] = $resolvedAcknowledgeButtonText
    $sql = $sql.TrimEnd() + ",`r`n    @AcknowledgeButtonText = @AcknowledgeButtonText"
}

$result = Invoke-ToastSql `
    -ConnectionString $conn `
    -SqlCredential $sqlCredential `
    -CommandText $sql `
    -Parameters $params `
    -CommandTimeoutSeconds $config.CommandTimeoutSeconds

$queuedResult = Resolve-ToastQueueResult -Result $result

Write-Output "Queued message $($queuedResult.MessageId) for group '$GroupName'."