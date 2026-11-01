[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConfigPath,
    [switch]$Once,
    [ValidateRange(1,2147483647)][int]$PollSeconds = 30
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot\..\Module\ToastSql.psm1" -Force
$config = Import-ToastConfig -Path $ConfigPath -RequiredProperties @('SqlServer','SqlDatabase','SqlPort','UseIntegratedSecurity','ClientName','AppDeployToolkitModulePath','Encrypt','TrustServerCertificate','ConnectTimeoutSeconds','CommandTimeoutSeconds') -NullableProperties @('ClientName','AppDeployToolkitModulePath') -ResolveClientName
Set-ToastClientDependencyOptions -AppDeployToolkitModulePath $config.AppDeployToolkitModulePath
$conn = Get-ToastConnectionString $config
$sqlCredential = Get-ToastSqlCredential $config
$user = [System.Security.Principal.WindowsIdentity]::GetCurrent()
if ($user.IsSystem -or -not [Environment]::UserInteractive) {
    throw 'Run the client in the interactive user session, not as SYSTEM.'
}
$statePath = Get-ToastReadStatePath -Server $config.SqlServer -Port $config.SqlPort -Database $config.SqlDatabase -ComputerName $config.ClientName
do {
    Invoke-ToastClientPass -ConnectionString $conn -SqlCredential $sqlCredential -ComputerName $config.ClientName -StatePath $statePath -CommandTimeoutSeconds $config.CommandTimeoutSeconds
    if ($Once) { break }
    Start-Sleep -Seconds $PollSeconds
} while ($true)
