[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ConfigPath,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$GroupName,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Title,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Body,
    [AllowNull()][AllowEmptyString()][string]$Subtitle,
    [Parameter(HelpMessage='DateTimeOffset or ISO 8601 timestamp with Z or an explicit timezone offset.')][AllowNull()]$ExpiresUtc,
    [AllowNull()]$ActiveDuration,
    [ValidateSet('Days','Hours','Minutes')][string]$DurationUnit,
    [AllowNull()][AllowEmptyString()][string]$AcknowledgeButtonText = 'Stäng',
    [Nullable[int]]$RepeatIntervalSeconds,
    [Nullable[int]]$RepeatIntervalMinutes,
    [Nullable[int]]$RepeatCount
)

Set-StrictMode -Version Latest
Import-Module "$PSScriptRoot\..\Module\ToastSql.psm1" -Force

$expirySettings = Resolve-ToastExpirySettings -ExpiresUtc $ExpiresUtc -ActiveDuration $ActiveDuration -DurationUnit $DurationUnit
$repeatSettings = Resolve-ToastRepeatSettings -RepeatIntervalSeconds $RepeatIntervalSeconds -RepeatIntervalMinutes $RepeatIntervalMinutes -RepeatCount $RepeatCount
$label = Resolve-ToastAcknowledgeButtonText -AcknowledgeButtonText $AcknowledgeButtonText
$config = Import-ToastConfig -Path $ConfigPath -RequiredProperties @(
    'SqlServer','SqlDatabase','SqlPort','UseIntegratedSecurity','Encrypt',
    'TrustServerCertificate','ConnectTimeoutSeconds','CommandTimeoutSeconds'
)
Test-ToastSqlPort -Server $config.SqlServer -Port $config.SqlPort
$conn = Get-ToastConnectionString $config
$sqlCredential = Get-ToastSqlCredential $config

$params = @{
    GroupName = $GroupName
    Title = $Title
    Subtitle = $Subtitle
    Body = $Body
    AcknowledgeButtonText = $label
    ExpiresUtc = $expirySettings.ExpiresUtc
    ActiveDuration = $expirySettings.ActiveDuration
    DurationUnit = $expirySettings.DurationUnit
    RepeatIntervalSeconds = $repeatSettings.RepeatIntervalSeconds
    RepeatCount = $repeatSettings.RepeatCount
}
$sql = @'
EXEC dbo.usp_QueueToastMessage
    @GroupName = @GroupName,
    @Title = @Title,
    @Subtitle = @Subtitle,
    @Body = @Body,
    @AcknowledgeButtonText = @AcknowledgeButtonText,
    @ExpiresUtc = @ExpiresUtc,
    @ActiveDuration = @ActiveDuration,
    @DurationUnit = @DurationUnit,
    @RepeatIntervalSeconds = @RepeatIntervalSeconds,
    @RepeatCount = @RepeatCount
'@
$result = Invoke-ToastSql -ConnectionString $conn -SqlCredential $sqlCredential `
    -CommandText $sql -Parameters $params -CommandTimeoutSeconds $config.CommandTimeoutSeconds
$queuedResult = Resolve-ToastQueueResult -Result $result
Write-Output "Queued message $($queuedResult.MessageId) for group '$GroupName'."
