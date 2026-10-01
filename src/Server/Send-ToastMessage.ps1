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
    [Parameter(HelpMessage='Optional text shown on a single toast action button.')][string]$ButtonText,
    [Parameter(HelpMessage='Optional button argument, typically an absolute URL or protocol URI.')][string]$ButtonArguments,
    [Parameter(HelpMessage='Button activation type. Use Protocol to open a URI or Dismiss to close the toast.')][ValidateSet('Protocol','Dismiss')][string]$ButtonActivationType,
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

$result = Invoke-ToastSql `
    -ConnectionString $conn `
    -SqlCredential $sqlCredential `
    -CommandText $sql `
    -Parameters $params `
    -CommandTimeoutSeconds $config.CommandTimeoutSeconds

$queuedResult = Resolve-ToastQueueResult -Result $result

Write-Output "Queued message $($queuedResult.MessageId) for group '$GroupName'."