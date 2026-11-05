[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConfigPath,
    [switch]$Once,
    [switch]$DebugLogging,
    [ValidateRange(1,2147483647)][int]$PollSeconds = 30
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot\..\Module\ToastLogging.psm1" -Force
$runId = New-ToastLogRunId
$logPath = Get-ToastClientLogPath
$component = 'Client'
$identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$mode = if ($identity.IsSystem) { 'SYSTEM' } else { 'User' }
Write-ToastLog -Path $logPath -Level Info -Component $component -RunId $runId -Message "Client starting; mode=$mode."
if ($DebugLogging) {
    Write-ToastLog -Path $logPath -Level Info -Component $component -RunId $runId -Message 'Detailed debug logging enabled.'
}
try {
if (-not [Environment]::Is64BitProcess) {
    throw 'Run the client in 64-bit PowerShell to use the machine-wide HKLM read state.'
}
Import-Module "$PSScriptRoot\..\Module\ToastSql.psm1" -Force
$config = Import-ToastConfig -Path $ConfigPath -RequiredProperties @('SqlServer','SqlDatabase','SqlPort','UseIntegratedSecurity','ClientName','AppDeployToolkitModulePath','Encrypt','TrustServerCertificate','ConnectTimeoutSeconds','CommandTimeoutSeconds') -NullableProperties @('ClientName','AppDeployToolkitModulePath') -ResolveClientName
$user = [System.Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $user.IsSystem -and -not [Environment]::UserInteractive) {
    throw 'Run the client as SYSTEM or in an interactive user session.'
}
Write-ToastLog -Path $logPath -Level Info -Component $component -RunId $runId -Message "Execution mode confirmed; mode=$mode."
try {
    Set-ToastClientDependencyOptions -AppDeployToolkitModulePath $config.AppDeployToolkitModulePath -RunAsSystem:$user.IsSystem
} catch {
    Write-ToastLog -Path $logPath -Level Error -Component $component -RunId $runId -ErrorKey 'Toolkit' `
        -Message "Toolkit initialization failed ($($_.Exception.GetType().Name))."
    throw
}
$conn = Get-ToastConnectionString $config
$sqlCredential = Get-ToastSqlCredential $config
$statePath = Get-ToastReadStatePath -Server $config.SqlServer -Port $config.SqlPort -Database $config.SqlDatabase -ComputerName $config.ClientName
Write-ToastLog -Path $logPath -Level Info -Component $component -RunId $runId -Message "Read-state scope=$($statePath.Split('\')[-1])."
if (-not (Test-Path -LiteralPath $statePath -ErrorAction Stop)) {
    throw 'Read-state scope is not provisioned. Run deploy\Initialize-ToastReadState.ps1 with this configuration in an elevated 64-bit PowerShell session before starting the client.'
}
do {
    try {
        $passCompleted = Invoke-ToastClientPass -ConnectionString $conn -SqlCredential $sqlCredential -ComputerName $config.ClientName -StatePath $statePath -CommandTimeoutSeconds $config.CommandTimeoutSeconds -LogPath $logPath -RunId $runId -DebugLogging:$DebugLogging
        if ($passCompleted) {
            Clear-ToastLogError -Path $logPath -Component $component -RunId $runId -ErrorKey 'SQL'
            Clear-ToastLogError -Path $logPath -Component $component -RunId $runId -ErrorKey 'ClientLoop'
        }
    } catch {
        Write-ToastLog -Path $logPath -Level Error -Component $component -RunId $runId -ErrorKey 'ClientLoop' -Message "Client pass failed ($($_.Exception.GetType().Name))."
        if ($Once) { throw }
    }
    if ($Once) { break }
    Start-Sleep -Seconds $PollSeconds
} while ($true)
} catch {
    Write-ToastLog -Path $logPath -Level Error -Component $component -RunId $runId -ErrorKey 'Startup' -Message "Client stopped after an error ($($_.Exception.GetType().Name))."
    throw
} finally {
    Write-ToastLog -Path $logPath -Level Info -Component $component -RunId $runId -Message 'Client stopped.'
}
