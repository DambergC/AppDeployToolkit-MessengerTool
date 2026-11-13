<#
.SYNOPSIS
Queues a plain-text notification for a SQL notification group.
.DESCRIPTION
Validates expiry and optional repeat settings, checks the SQL TCP port by
default, and queues through parameterized SQL with server logging.
Use ExpiresUtc with an explicit timezone OR ActiveDuration with DurationUnit.
Queueing does not confirm delivery. For GUI functions, import ToastAdmin.psm1.
.PARAMETER ConfigPath
Path to the administrator's local configuration data file.
.PARAMETER GroupName
Existing SQL notification group name.
.PARAMETER Title
Required plain-text dialog title.
.PARAMETER Body
Required plain-text message.
.PARAMETER Subtitle
Optional independent subtitle.
.PARAMETER ExpiresUtc
Future timestamp with explicit timezone; cannot be combined with duration.
.PARAMETER ActiveDuration
Positive integer duration calculated at SQL queue time.
.PARAMETER DurationUnit
Days, Hours or Minutes; required with ActiveDuration.
.PARAMETER AcknowledgeButtonText
Single acknowledgement button label. Blank uses the default; Timeout is reserved.
.PARAMETER RepeatIntervalSeconds
Repeat interval in seconds; use seconds or minutes with RepeatCount.
.PARAMETER RepeatIntervalMinutes
Repeat interval in minutes instead of seconds.
.PARAMETER RepeatCount
Total acknowledgement count including the first display, at least 2.
.PARAMETER CheckSqlPort
Controls only the TCP precheck, not SQL authentication or TLS validation.
.PARAMETER PassThru
Returns MessageId and GroupName as an object instead of the default status text.
.EXAMPLE
.\Send-ToastMessage.ps1 -ConfigPath C:\Toast\admin.local.psd1 -GroupName Pilot -Title Maintenance -Body 'Save your work.' -ActiveDuration 2 -DurationUnit Hours
.OUTPUTS
System.String by default; PSCustomObject with MessageId and GroupName with PassThru.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ConfigPath,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][ValidateLength(1,128)][string]$GroupName,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Title,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Body,
    [AllowNull()][AllowEmptyString()][string]$Subtitle,
    [Parameter(HelpMessage='DateTimeOffset or ISO 8601 timestamp with Z or an explicit timezone offset.')][AllowNull()]$ExpiresUtc,
    [AllowNull()]$ActiveDuration,
    [ValidateSet('Days','Hours','Minutes')][string]$DurationUnit,
    [AllowNull()][AllowEmptyString()][string]$AcknowledgeButtonText = 'Stäng',
    [Nullable[int]]$RepeatIntervalSeconds,
    [Nullable[int]]$RepeatIntervalMinutes,
    [Nullable[int]]$RepeatCount,
    [Parameter(HelpMessage='Enable or disable the SQL TCP port precheck; SQL authentication and TLS validation always apply.')][bool]$CheckSqlPort = $true,
    [switch]$PassThru
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
if ($CheckSqlPort) {
    Test-ToastSqlPort -Server $config.SqlServer -Port $config.SqlPort
}
$conn = Get-ToastConnectionString $config
$sqlCredential = Get-ToastSqlCredential $config
$domainUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
if ([string]::IsNullOrWhiteSpace($domainUser) -or $domainUser.Length -gt 256) {
    throw 'The current Windows identity must have a non-empty name of at most 256 characters.'
}

$params = @{
    DomainUser = $domainUser
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
BEGIN TRY
    EXEC sys.sp_set_session_context @key = N'DomainUser', @value = @DomainUser;
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
        @RepeatCount = @RepeatCount;
    EXEC sys.sp_set_session_context @key = N'DomainUser', @value = NULL;
END TRY
BEGIN CATCH
    EXEC sys.sp_set_session_context @key = N'DomainUser', @value = NULL;
    THROW;
END CATCH
'@
$result = Invoke-ToastSql -ConnectionString $conn -SqlCredential $sqlCredential `
    -CommandText $sql -Parameters $params -CommandTimeoutSeconds $config.CommandTimeoutSeconds
$queuedResult = Resolve-ToastQueueResult -Result $result
Write-ToastLog -Path $logPath -Level Info -Component $component -RunId $runId `
    -Message 'Message queued successfully.' -MessageId $queuedResult.MessageId
if ($PassThru) {
    [pscustomobject]@{ MessageId = $queuedResult.MessageId; GroupName = $GroupName }
}
else {
    Write-Output "Queued message $($queuedResult.MessageId) for group '$GroupName'."
}
} catch {
    Write-ToastLog -Path $logPath -Level Error -Component $component -RunId $runId -ErrorKey 'Queue' `
        -Message "Message queue operation failed ($($_.Exception.GetType().Name))."
    throw
} finally {
    Write-ToastLog -Path $logPath -Level Info -Component $component -RunId $runId -Message 'Message queue operation finished.'
}
