[CmdletBinding()]
param([Parameter(Mandatory)][string]$ConfigPath,[switch]$Register,[switch]$Once,[int]$PollSeconds=30)
Set-StrictMode -Version Latest
Import-Module "$PSScriptRoot\..\Module\ToastSql.psm1" -Force
$config=Import-ToastConfig -Path $ConfigPath -RequiredProperties @('ApiUri','ClientName','ClientGroups','AppDeployToolkitModulePath','RequestTimeoutSeconds','MaxRetryCount','RetryDelaySeconds') -NullableProperties @('ClientName','AppDeployToolkitModulePath') -NonEmptyProperties @('ClientGroups') -ResolveClientName
foreach ($integerSetting in @('RequestTimeoutSeconds','MaxRetryCount','RetryDelaySeconds')) {
    $value = $config[$integerSetting]
    $minimum = if ($integerSetting -eq 'RequestTimeoutSeconds') { 1 } else { 0 }
    if (($value -isnot [int] -and $value -isnot [long]) -or $value -lt $minimum -or $value -gt [int]::MaxValue) {
        throw "Config file '$ConfigPath' setting $integerSetting must be an integer greater than or equal to $minimum."
    }
}
$apiBaseUri = $null
if (-not [uri]::TryCreate([string]$config.ApiUri, [System.UriKind]::Absolute, [ref]$apiBaseUri) -or $apiBaseUri.Scheme -ne 'https') {
    throw "Config file '$ConfigPath' setting ApiUri must be an absolute https URL, for example 'https://messenger.example.test/api'."
}
$apiBaseUrl = $apiBaseUri.AbsoluteUri.TrimEnd('/')
Set-ToastClientDependencyOptions -AppDeployToolkitModulePath $config.AppDeployToolkitModulePath
$computer=$config.ClientName
$clientUrl = "$apiBaseUrl/Clients/$([uri]::EscapeDataString($computer))"
$displayedToastOccurrenceRetentionMinutes = 60
$displayedToastOccurrences = @{}
$transientHttpStatusCodes = @(408, 429, 500, 502, 503, 504)
function Get-ToastOccurrenceKey {
    param(
        [Parameter(Mandatory)][long]$MessageId,
        [Parameter(Mandatory)][int]$ShowCount
    )

    return "${MessageId}:${ShowCount}"
}
function Clear-StaleDisplayedToastOccurrences {
    $cutoffUtc = [datetime]::UtcNow.AddMinutes(-$displayedToastOccurrenceRetentionMinutes)
    foreach ($key in @($script:displayedToastOccurrences.Keys)) {
        if ($script:displayedToastOccurrences[$key] -lt $cutoffUtc) {
            [void]$script:displayedToastOccurrences.Remove($key)
        }
    }
}
function Get-ToastApiStatusCode {
    param([Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$ErrorRecord)

    $exception = $ErrorRecord.Exception
    while ($null -ne $exception) {
        $responseProperty = $exception.PSObject.Properties['Response']
        if ($null -ne $responseProperty -and $null -ne $responseProperty.Value) {
            $statusCodeProperty = $responseProperty.Value.PSObject.Properties['StatusCode']
            if ($null -ne $statusCodeProperty -and $null -ne $statusCodeProperty.Value) {
                return [int]$statusCodeProperty.Value
            }
        }

        $exception = $exception.InnerException
    }

    return $null
}
function Test-ToastApiTransientError {
    param([Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$ErrorRecord)

    $statusCode = Get-ToastApiStatusCode -ErrorRecord $ErrorRecord
    if ($null -ne $statusCode) {
        return $statusCode -in $script:transientHttpStatusCodes
    }

    # No HTTP response at all: DNS, connection, TLS, or timeout failures.
    $exception = $ErrorRecord.Exception
    while ($null -ne $exception) {
        if ($exception -is [System.Net.WebException] -or
            $exception -is [System.Net.Http.HttpRequestException] -or
            $exception -is [System.Threading.Tasks.TaskCanceledException] -or
            $exception -is [System.TimeoutException] -or
            $exception -is [System.IO.IOException] -or
            $exception -is [System.Net.Sockets.SocketException]) {
            return $true
        }

        $exception = $exception.InnerException
    }

    return $false
}
function Invoke-ToastApiRequest {
    param(
        [Parameter(Mandatory)][ValidateSet('Get','Post','Put')][string]$Method,
        [Parameter(Mandatory)][string]$Uri,
        $Body,
        [switch]$ConflictAfterRetryIsSuccess
    )

    $request = @{
        Method = $Method
        Uri = $Uri
        UseDefaultCredentials = $true
        TimeoutSec = $config.RequestTimeoutSeconds
        ErrorAction = 'Stop'
    }
    if ($PSBoundParameters.ContainsKey('Body')) {
        $request.ContentType = 'application/json; charset=utf-8'
        $request.Body = [System.Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $Body -Depth 5 -Compress))
    }

    $maxAttempts = [int]$config.MaxRetryCount + 1
    $delaySeconds = [int]$config.RetryDelaySeconds
    $hadTransientFailure = $false
    for ($attempt = 1; ; $attempt++) {
        try {
            return Invoke-RestMethod @request
        } catch {
            $errorRecord = $_
            if ($ConflictAfterRetryIsSuccess -and $hadTransientFailure -and (Get-ToastApiStatusCode -ErrorRecord $errorRecord) -eq 409) {
                # The earlier attempt most likely reached the server before the connection failed; the lease is
                # single-use, so the conflict means the acknowledgement was already recorded.
                Write-Verbose "$Method $Uri returned 409 after a transient failure; treating the request as already applied."
                return
            }

            if ($attempt -ge $maxAttempts -or -not (Test-ToastApiTransientError -ErrorRecord $errorRecord)) {
                throw $errorRecord
            }

            $hadTransientFailure = $true
            Write-Verbose "Transient error on $Method $Uri (attempt $attempt of $maxAttempts): $($errorRecord.Exception.Message). Retrying in $delaySeconds second(s)."
            if ($delaySeconds -gt 0) {
                Start-Sleep -Seconds $delaySeconds
                $delaySeconds = [Math]::Min($delaySeconds * 2, 60)
            }
        }
    }
}
function Invoke-ToastDeliveryRecord {
    param(
        [Parameter(Mandatory)][long]$MessageId,
        [Parameter(Mandatory)][ValidateSet('Delivered','Failed')][string]$Status,
        [string]$ErrorMessage,
        [Parameter(Mandatory)][guid]$LeaseId
    )

    $body = [ordered]@{
        messageId = $MessageId
        leaseId = $LeaseId.ToString()
        status = $Status
        errorMessage = if ([string]::IsNullOrEmpty($ErrorMessage)) { $null } else { $ErrorMessage }
    }

    Invoke-ToastApiRequest -Method Put -Uri $script:clientUrl -Body $body -ConflictAfterRetryIsSuccess | Out-Null
}
function Get-ToastPendingRows {
    $response = Invoke-ToastApiRequest -Method Get -Uri $script:clientUrl
    return @($response | Where-Object { $null -ne $_ })
}
function Invoke-Registration {
    $body = [ordered]@{
        computerName = $computer
        groups = @($config.ClientGroups | ForEach-Object { [string]$_ })
    }
    Invoke-ToastApiRequest -Method Post -Uri "$apiBaseUrl/Clients" -Body $body | Out-Null
}
if($Register){Invoke-Registration;Write-Output "Registered $computer";if($Once){return}}
function Invoke-Poll {
    Clear-StaleDisplayedToastOccurrences
    $rows=Get-ToastPendingRows
    foreach($row in $rows){
        $occurrenceKey = Get-ToastOccurrenceKey -MessageId $row.MessageId -ShowCount $row.ShowCount
        if ($script:displayedToastOccurrences.ContainsKey($occurrenceKey)) {
            try {
                Invoke-ToastDeliveryRecord -MessageId $row.MessageId -Status Delivered -LeaseId $row.LeaseId
                [void]$script:displayedToastOccurrences.Remove($occurrenceKey)
            } catch {
                $script:displayedToastOccurrences[$occurrenceKey] = [datetime]::UtcNow
                Write-Warning "Toast message $($row.MessageId) was already displayed locally but delivery acknowledgement still failed: $($_.Exception.Message)"
            }

            continue
        }

        try{
            Invoke-ToastNotification -ToastRow $row
        }catch{
            $toastErrorRecord = $_
            $toastErrorMessage = $toastErrorRecord.Exception.Message
            try {
                Invoke-ToastDeliveryRecord -MessageId $row.MessageId -Status Failed -ErrorMessage $toastErrorMessage -LeaseId $row.LeaseId
                continue
            } catch {
                throw $toastErrorRecord
            }
        }

        try {
            Invoke-ToastDeliveryRecord -MessageId $row.MessageId -Status 'Delivered' -LeaseId $row.LeaseId
        } catch {
            if (Test-ToastApiTransientError -ErrorRecord $_) {
                $script:displayedToastOccurrences[$occurrenceKey] = [datetime]::UtcNow
                Write-Warning "Displayed toast message $($row.MessageId) but could not record delivery status after retry: $($_.Exception.Message)"
                continue
            }

            throw
        }

        if ($script:displayedToastOccurrences.ContainsKey($occurrenceKey)) {
            [void]$script:displayedToastOccurrences.Remove($occurrenceKey)
        }
    }
}
do{Invoke-Poll;if($Once){break};Start-Sleep -Seconds $PollSeconds}while($true)
