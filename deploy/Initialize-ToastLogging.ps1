[CmdletBinding()]
param(
    [ValidatePattern('^S-1(-\d+)+$')][string]$ClientUserSid
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module "$PSScriptRoot\..\src\Module\ToastLogging.psm1"
$root = Get-ToastLogRoot
if (-not (Test-Path -LiteralPath $root -PathType Container)) {
    throw "Windows Temp directory does not exist: '$root'."
}

if ($PSBoundParameters.ContainsKey('ClientUserSid')) {
    Write-Warning 'ClientUserSid is no longer needed. Log files are created directly in Windows Temp without changing permissions.'
}

Write-Output $root
