[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Optional precreation for the current user; the client also creates this path on demand.
$path = 'HKCU:\Software\AppDeployToolkit-MessengerTool\ReadState'
if (-not (Test-Path -LiteralPath $path)) {
    New-Item -Path $path -Force | Out-Null
}
