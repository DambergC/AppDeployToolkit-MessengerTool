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
$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot\..\Module\ToastLogging.psm1" -Force
$runId = New-ToastLogRunId
$logPath = Get-ToastServerLogPath
$component = 'Server'
Write-ToastLog -Path $logPath -Level Info -Component $component -RunId $runId -Message 'Message queue operation started.'
try {
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
Write-ToastLog -Path $logPath -Level Info -Component $component -RunId $runId `
    -Message 'Message queued successfully.' -MessageId $queuedResult.MessageId
Write-Output "Queued message $($queuedResult.MessageId) for group '$GroupName'."
} catch {
    Write-ToastLog -Path $logPath -Level Error -Component $component -RunId $runId -ErrorKey 'Queue' `
        -Message "Message queue operation failed ($($_.Exception.GetType().Name))."
    throw
} finally {
    Write-ToastLog -Path $logPath -Level Info -Component $component -RunId $runId -Message 'Message queue operation finished.'
}
