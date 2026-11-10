#Requires -RunAsAdministrator
[CmdletBinding()]
param([Parameter(Mandatory)][string]$ConfigPath)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not [Environment]::Is64BitProcess) {
    throw 'Run provisioning in 64-bit PowerShell to use the machine-wide HKLM read state.'
}

Import-Module "$PSScriptRoot\..\src\Module\ToastSql.psm1" -Force
$config = Import-ToastConfig -Path $ConfigPath -RequiredProperties @('SqlServer','SqlPort','SqlDatabase','ClientName') -NullableProperties @('ClientName') -ResolveClientName
$statePath = Get-ToastReadStatePath -Server $config.SqlServer -Port $config.SqlPort -Database $config.SqlDatabase -ComputerName $config.ClientName
if (-not (Test-Path -LiteralPath $statePath)) {
    New-Item -Path $statePath -Force | Out-Null
}

# Protect only this scope; users cannot create keys, delete state, or change permissions.
# Trade-off: all interactive users (S-1-5-4) can write values, so one user could alter another's read/repeat state on a shared machine.
$acl = [System.Security.AccessControl.RegistrySecurity]::new()
$acl.SetAccessRuleProtection($true, $false)
$acl.SetOwner([System.Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
    $acl.AddAccessRule([System.Security.AccessControl.RegistryAccessRule]::new(
        [System.Security.Principal.SecurityIdentifier]::new($sid),
        [System.Security.AccessControl.RegistryRights]::FullControl,
        [System.Security.AccessControl.InheritanceFlags]::ContainerInherit,
        [System.Security.AccessControl.PropagationFlags]::None,
        [System.Security.AccessControl.AccessControlType]::Allow))
}
$rights = [System.Security.AccessControl.RegistryRights]::ReadKey -bor [System.Security.AccessControl.RegistryRights]::SetValue
$acl.AddAccessRule([System.Security.AccessControl.RegistryAccessRule]::new(
    [System.Security.Principal.SecurityIdentifier]::new('S-1-5-4'), $rights,
    [System.Security.AccessControl.InheritanceFlags]::None,
    [System.Security.AccessControl.PropagationFlags]::None,
    [System.Security.AccessControl.AccessControlType]::Allow))
Set-Acl -LiteralPath $statePath -AclObject $acl
Write-Output $statePath
