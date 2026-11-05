[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$ConfigPath,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][ValidateLength(1,128)][string]$Tag,
    [ValidateNotNullOrEmpty()][string]$Filter = '*',
    [ValidateNotNullOrEmpty()][string]$SearchBase
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot\..\Module\ToastLogging.psm1" -Force
$runId = New-ToastLogRunId
$logPath = Get-ToastServerLogPath
$component = 'Server'
$changeCount = 0
$computerCount = 0
Write-ToastLog -Path $logPath -Level Info -Component $component -RunId $runId -Message 'AD import started.'
try {
Import-Module "$PSScriptRoot\..\Module\ToastSql.psm1" -Force
Import-Module ActiveDirectory -ErrorAction Stop
$Tag = $Tag.Trim()
if ([string]::IsNullOrWhiteSpace($Tag)) { throw 'Tag must contain a group name.' }
$config = Import-ToastConfig -Path $ConfigPath -RequiredProperties @('SqlServer','SqlDatabase','SqlPort','UseIntegratedSecurity','Encrypt','TrustServerCertificate','ConnectTimeoutSeconds','CommandTimeoutSeconds')
$connectionString = Get-ToastConnectionString $config
$credential = Get-ToastSqlCredential $config
$adParameters = @{ Filter = $Filter; ErrorAction = 'Stop' }

if ($PSBoundParameters.ContainsKey('SearchBase')) {
    $searchObject = Get-ADObject -Identity $SearchBase -Properties ObjectClass -ErrorAction Stop
    if ($searchObject.ObjectClass -contains 'group') {
        if ($Filter -ne '*') {
            throw 'Filter cannot be used with an AD group SearchBase; group membership determines the computer selection.'
        }
        $computers = @(Get-ADGroupMember -Identity $SearchBase -Recursive -ErrorAction Stop |
            Where-Object { $_.ObjectClass -eq 'computer' } |
            Select-Object -ExpandProperty Name -Unique)
    }
    else {
        $adParameters.SearchBase = $SearchBase
        $computers = @(Get-ADComputer @adParameters | Select-Object -ExpandProperty Name -Unique)
    }
}
else {
    $computers = @(Get-ADComputer @adParameters | Select-Object -ExpandProperty Name -Unique)
}
$computerCount = $computers.Count
Write-ToastLog -Path $logPath -Level Info -Component $component -RunId $runId -Message "AD selection completed; computers=$computerCount."

# Name matches the default client hostname (not DNSHostName). Validate the whole selection before writing.
foreach ($computer in $computers) {
    if ([string]::IsNullOrWhiteSpace($computer) -or $computer.Length -gt 256) {
        throw 'AD computer Name must contain between 1 and 256 characters.'
    }
}

$sql = @'
SET XACT_ABORT ON;
BEGIN TRY
    BEGIN TRAN;
    DECLARE @Changes int = 0;
    IF NOT EXISTS (SELECT 1 FROM dbo.ToastGroup WITH (UPDLOCK, HOLDLOCK) WHERE GroupName = @GroupName)
    BEGIN
        INSERT dbo.ToastGroup(GroupName) VALUES (@GroupName);
        SET @Changes += @@ROWCOUNT;
    END
    IF NOT EXISTS (SELECT 1 FROM dbo.ToastClient WITH (UPDLOCK, HOLDLOCK) WHERE ComputerName = @ComputerName)
    BEGIN
        INSERT dbo.ToastClient(ComputerName) VALUES (@ComputerName);
        SET @Changes += @@ROWCOUNT;
    END
    DECLARE @GroupId int = (SELECT GroupId FROM dbo.ToastGroup WHERE GroupName = @GroupName);
    DECLARE @ClientId int = (SELECT ClientId FROM dbo.ToastClient WHERE ComputerName = @ComputerName);
    IF NOT EXISTS (SELECT 1 FROM dbo.ToastClientGroup WITH (UPDLOCK, HOLDLOCK) WHERE ClientId = @ClientId AND GroupId = @GroupId)
    BEGIN
        INSERT dbo.ToastClientGroup(ClientId, GroupId) VALUES (@ClientId, @GroupId);
        SET @Changes += @@ROWCOUNT;
    END
    COMMIT;
    SELECT @Changes AS Changes;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK;
    THROW;
END CATCH;
'@

foreach ($computer in $computers) {
    if ($PSCmdlet.ShouldProcess("$computer -> $Tag", 'Register computer and add notification group membership')) {
        $result = Invoke-ToastSql -ConnectionString $connectionString -SqlCredential $credential -CommandText $sql -Parameters @{ ComputerName = $computer; GroupName = $Tag } -CommandTimeoutSeconds $config.CommandTimeoutSeconds
        $changeCount += [int]$result.Rows[0]['Changes']
        [pscustomobject]@{ ComputerName = $computer; Tag = $Tag }
    }
}
} catch {
    Write-ToastLog -Path $logPath -Level Error -Component $component -RunId $runId -ErrorKey 'Import' `
        -Message "AD import failed ($($_.Exception.GetType().Name))."
    throw
} finally {
    Write-ToastLog -Path $logPath -Level Info -Component $component -RunId $runId `
        -Message "AD import finished; computers=$computerCount; changes=$changeCount."
}
