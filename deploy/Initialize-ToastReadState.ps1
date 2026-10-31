#Requires -RunAsAdministrator
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not [Environment]::Is64BitProcess) {
    throw 'Machine read state requires 64-bit PowerShell; 32-bit registry redirection is not supported.'
}
$path = 'HKLM:\Software\AppDeployToolkit-MessengerTool\ReadState'
if (-not (Test-Path -LiteralPath $path)) {
    New-Item -Path $path -Force | Out-Null
}
$acl = Get-Acl -LiteralPath $path
# Only this data subtree is writable by interactive users, never code/config or parent keys.
$interactive = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-4')
$rights = [System.Security.AccessControl.RegistryRights]::ReadKey -bor
    [System.Security.AccessControl.RegistryRights]::SetValue -bor
    [System.Security.AccessControl.RegistryRights]::CreateSubKey
$rule = [System.Security.AccessControl.RegistryAccessRule]::new(
    $interactive, $rights, [System.Security.AccessControl.InheritanceFlags]::ContainerInherit,
    [System.Security.AccessControl.PropagationFlags]::None, [System.Security.AccessControl.AccessControlType]::Allow)
$acl.SetAccessRule($rule)
Set-Acl -LiteralPath $path -AclObject $acl
