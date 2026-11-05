$global:ToastMessengerLogErrorState = @{}
$script:ToastLogMaxBytes = 10MB
$script:ToastLogArchiveCount = 5
Set-StrictMode -Version Latest

function New-ToastLogRunId {
    [CmdletBinding()]
    param()
    return [guid]::NewGuid().ToString('N')
}

function Get-ToastLogRoot {
    [CmdletBinding()]
    param()
    return Join-Path ([Environment]::GetFolderPath('Windows')) 'Temp\AppDeployToolkit-MessengerTool\Logs'
}

function Get-ToastClientLogPath {
    [CmdletBinding()]
    param()
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    if ($identity.IsSystem) {
        return Join-Path (Get-ToastLogRoot) 'Client\SYSTEM\Client.log'
    }
    return Join-Path (Get-ToastLogRoot) "Client\Users\$($identity.User.Value)\Client.log"
}

function Get-ToastServerLogPath {
    [CmdletBinding()]
    param()
    return Join-Path (Get-ToastLogRoot) 'Server\Server.log'
}

function Write-ToastLogLine {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Component,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][ValidateSet('Debug','Info','Warning','Error')][string]$Level,
        [Parameter(Mandatory)][string]$Message,
        [AllowNull()][Nullable[long]]$MessageId
    )

    $now = [DateTimeOffset]::Now
    $type = switch ($Level) {
        'Debug' { 1 }
        'Info' { 1 }
        'Warning' { 2 }
        'Error' { 3 }
    }
    $context = "RunId=$RunId;Level=$Level;ProcessId=$PID"
    if ($null -ne $MessageId) { $context += ";MessageId=$MessageId" }
    $safeMessage = ($Message -replace '[\r\n]+', ' ') -replace '\]LOG\]!>', '] LOG! >'
    $line = '<![LOG[' + $safeMessage + ']LOG]!><time="' +
        $now.ToString('HH:mm:ss.fffzzz', [Globalization.CultureInfo]::InvariantCulture) +
        '" date="' + $now.ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture) +
        '" component="' + $Component + '" context="' + $context +
        '" type="' + $type + '" thread="' + [Threading.Thread]::CurrentThread.ManagedThreadId + '" file="" line="">'
    $bytes = [Text.Encoding]::UTF8.GetBytes($line + "`r`n")
    $lockPath = "$Path.lock"
    $lock = $null
    $watch = [Diagnostics.Stopwatch]::StartNew()
    try {
        while ($null -eq $lock) {
            try {
                $lock = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
            } catch [IO.IOException] {
                if ($watch.Elapsed.TotalSeconds -ge 5) { throw }
                Start-Sleep -Milliseconds 50
            }
        }

        if ([IO.File]::Exists($Path) -and ([IO.FileInfo]::new($Path).Length + $bytes.Length) -gt $script:ToastLogMaxBytes) {
            $oldest = "$Path.$script:ToastLogArchiveCount"
            if ([IO.File]::Exists($oldest)) { [IO.File]::Delete($oldest) }
            for ($index = $script:ToastLogArchiveCount - 1; $index -ge 1; $index--) {
                $source = "$Path.$index"
                if ([IO.File]::Exists($source)) { [IO.File]::Move($source, "$Path.$($index + 1)") }
            }
            [IO.File]::Move($Path, "$Path.1")
        }

        $stream = [IO.File]::Open($Path, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::Read)
        try {
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush()
        } finally {
            $stream.Dispose()
        }
    } finally {
        if ($null -ne $lock) { $lock.Dispose() }
    }
}

function Write-ToastLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][ValidateSet('Debug','Info','Warning','Error')][string]$Level,
        [Parameter(Mandatory)][string]$Component,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Message,
        [AllowNull()][Nullable[long]]$MessageId,
        [string]$ErrorKey
    )

    try {
        if ($Level -in @('Warning','Error') -and -not [string]::IsNullOrWhiteSpace($ErrorKey)) {
            $key = "$Path|$Component|$RunId|$ErrorKey|$Message"
            $now = [DateTimeOffset]::UtcNow
            if ($global:ToastMessengerLogErrorState.ContainsKey($key)) {
                $state = $global:ToastMessengerLogErrorState[$key]
                $state.Count++
                if (($now - $state.LastSummaryUtc).TotalMinutes -lt 5) { return }
                $message = "Repeated error persists ($($state.Count) occurrences): $Message"
                $state.Count = 0
                $state.LastSummaryUtc = $now
            } else {
                $global:ToastMessengerLogErrorState[$key] = @{ Count = 0; LastSummaryUtc = $now }
            }
        }
        Write-ToastLogLine -Path $Path -Component $Component -RunId $RunId -Level $Level -Message $Message -MessageId $MessageId
    } catch {
        try { Write-Warning "Local log write failed for '$Path' ($($_.Exception.GetType().Name)); application processing continues." } catch { }
    }
}

function Clear-ToastLogError {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Component,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$ErrorKey
    )
    try {
        $prefix = "$Path|$Component|$RunId|$ErrorKey|"
        $keys = @($global:ToastMessengerLogErrorState.Keys | Where-Object { $_.StartsWith($prefix, [StringComparison]::Ordinal) })
        if ($keys.Count -eq 0) { return }
        $count = 0
        foreach ($key in $keys) {
            $count += $global:ToastMessengerLogErrorState[$key].Count
            [void]$global:ToastMessengerLogErrorState.Remove($key)
        }
        Write-ToastLog -Path $Path -Level Info -Component $Component -RunId $RunId `
            -Message "Recovered after $ErrorKey errors ($count additional occurrences)."
    } catch {
        try { Write-Warning "Local log recovery notification failed for '$Path' ($($_.Exception.GetType().Name))." } catch { }
    }
}

Export-ModuleMember -Function New-ToastLogRunId,Get-ToastLogRoot,Get-ToastClientLogPath,Get-ToastServerLogPath,Write-ToastLog,Clear-ToastLogError
