#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [ValidatePattern('^S-1(-\d+)+$')][string]$ClientUserSid
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module "$PSScriptRoot\..\src\Module\ToastLogging.psm1"
$root = Get-ToastLogRoot
$systemSid = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-18')
$adminsSid = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
$authenticatedUsersSid = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-11')
$inheritToChildren = [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
    [System.Security.AccessControl.InheritanceFlags]::ObjectInherit

function Set-ToastLogDirectoryAcl {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][System.Security.AccessControl.FileSystemRights]$UserRights,
        [AllowNull()][System.Security.Principal.SecurityIdentifier]$UserSid
    )
    [void][IO.Directory]::CreateDirectory($Path)
    $acl = [System.Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    $acl.SetOwner($adminsSid)
    foreach ($sid in @($systemSid, $adminsSid)) {
        $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new(
            $sid, [System.Security.AccessControl.FileSystemRights]::FullControl,
            $inheritToChildren,
            [System.Security.AccessControl.PropagationFlags]::None,
            [System.Security.AccessControl.AccessControlType]::Allow))
    }
    if ($null -ne $UserSid) {
        $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new(
            $UserSid, $UserRights,
            $inheritToChildren,
            [System.Security.AccessControl.PropagationFlags]::None,
            [System.Security.AccessControl.AccessControlType]::Allow))
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}

$readAndExecute = [System.Security.AccessControl.FileSystemRights]::ReadAndExecute
Set-ToastLogDirectoryAcl -Path $root -UserRights $readAndExecute -UserSid $authenticatedUsersSid
Set-ToastLogDirectoryAcl -Path (Join-Path $root 'Server') -UserRights ([System.Security.AccessControl.FileSystemRights]0) -UserSid $null
Set-ToastLogDirectoryAcl -Path (Join-Path $root 'Client') -UserRights $readAndExecute -UserSid $authenticatedUsersSid
Set-ToastLogDirectoryAcl -Path (Join-Path $root 'Client\SYSTEM') -UserRights ([System.Security.AccessControl.FileSystemRights]0) -UserSid $null
Set-ToastLogDirectoryAcl -Path (Join-Path $root 'Client\Users') -UserRights $readAndExecute -UserSid $authenticatedUsersSid

if ($PSBoundParameters.ContainsKey('ClientUserSid')) {
    $userSid = [System.Security.Principal.SecurityIdentifier]::new($ClientUserSid)
    Set-ToastLogDirectoryAcl -Path (Join-Path $root "Client\Users\$ClientUserSid") `
        -UserRights ([System.Security.AccessControl.FileSystemRights]::Modify) -UserSid $userSid
}

Write-Output $root
