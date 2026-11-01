[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$ConfigPath,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][ValidateLength(1,128)][string]$Tag,
    [ValidateNotNullOrEmpty()][string]$Filter = '*',
    [ValidateNotNullOrEmpty()][string]$SearchBase
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot\..\Module\ToastSql.psm1" -Force
Import-Module ActiveDirectory -ErrorAction Stop
$Tag = $Tag.Trim()
if ([string]::IsNullOrWhiteSpace($Tag)) { throw 'Tag must contain a group name.' }
$config = Import-ToastConfig -Path $ConfigPath -RequiredProperties @('SqlServer','SqlDatabase','SqlPort','UseIntegratedSecurity','Encrypt','TrustServerCertificate','ConnectTimeoutSeconds','CommandTimeoutSeconds')
$connectionString = Get-ToastConnectionString $config
$credential = Get-ToastSqlCredential $config
$adParameters = @{ Filter = $Filter; ErrorAction = 'Stop' }
if ($PSBoundParameters.ContainsKey('SearchBase')) { $adParameters.SearchBase = $SearchBase }
# Name matches the default client hostname (not DNSHostName). Validate the whole selection before writing.
$computers = @(Get-ADComputer @adParameters | Select-Object -ExpandProperty Name -Unique)
foreach ($computer in $computers) {
    if ([string]::IsNullOrWhiteSpace($computer) -or $computer.Length -gt 256) {
        throw 'AD computer Name must contain between 1 and 256 characters.'
    }
}
$sql = @'
SET XACT_ABORT ON;
BEGIN TRY
    BEGIN TRAN;
    IF NOT EXISTS (SELECT 1 FROM dbo.ToastGroup WITH (UPDLOCK, HOLDLOCK) WHERE GroupName = @GroupName)
        INSERT dbo.ToastGroup(GroupName) VALUES (@GroupName);
    IF NOT EXISTS (SELECT 1 FROM dbo.ToastClient WITH (UPDLOCK, HOLDLOCK) WHERE ComputerName = @ComputerName)
        INSERT dbo.ToastClient(ComputerName) VALUES (@ComputerName);
    DECLARE @GroupId int = (SELECT GroupId FROM dbo.ToastGroup WHERE GroupName = @GroupName);
    DECLARE @ClientId int = (SELECT ClientId FROM dbo.ToastClient WHERE ComputerName = @ComputerName);
    IF NOT EXISTS (SELECT 1 FROM dbo.ToastClientGroup WITH (UPDLOCK, HOLDLOCK) WHERE ClientId = @ClientId AND GroupId = @GroupId)
        INSERT dbo.ToastClientGroup(ClientId, GroupId) VALUES (@ClientId, @GroupId);
    COMMIT;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK;
    THROW;
END CATCH;
'@
foreach ($computer in $computers) {
    if ($PSCmdlet.ShouldProcess("$computer -> $Tag", 'Register computer and add notification group membership')) {
        Invoke-ToastSql -ConnectionString $connectionString -SqlCredential $credential -CommandText $sql -Parameters @{ ComputerName = $computer; GroupName = $Tag } -CommandTimeoutSeconds $config.CommandTimeoutSeconds -NonQuery
        [pscustomobject]@{ ComputerName = $computer; Tag = $Tag }
    }
}
