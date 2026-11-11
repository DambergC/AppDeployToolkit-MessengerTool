Set-StrictMode -Version Latest

function Import-ToastADComputers {
    <#
    .SYNOPSIS
    Imports AD computers and synchronizes SQL tag membership for AD groups.
    .DESCRIPTION
    Reuses the standalone import script, including logging, validation and
    parameterized SQL. Importing an AD group synchronizes its recursive computer
    membership to the tag; filter and OU imports remain add-only.
    Computers removed from the tag are also deleted from SQL when they have no
    remaining tags. Computers with other tags are preserved, including when
    the selected AD group is empty. WhatIf previews additions and removals.
    Importing this module does not connect to AD or SQL.
    .PARAMETER ConfigPath
    Path to the administrator's local configuration data file.
    .PARAMETER Tag
    SQL notification group name (1-128 characters), not an AD attribute.
    .PARAMETER Filter
    Get-ADComputer filter. Defaults to all computers. A custom filter cannot
    be combined with an AD group SearchBase.
    .PARAMETER SearchBase
    Distinguished name of an OU/container or AD group. Groups are expanded
    recursively and only computer members are imported. When an AD group is
    selected, existing tag memberships are synchronized to its current members.
    Omit to search AD.
    .EXAMPLE
    Import-ToastADComputers -ConfigPath C:\Toast\admin.local.psd1 -Tag Pilot -SearchBase 'CN=Pilot,OU=Groups,DC=example,DC=test' -WhatIf
    Previews recursive group membership without changing SQL. AD/configuration
    reads and normal server logging still occur.
    .EXAMPLE
    $rows = @(Import-ToastADComputers -ConfigPath C:\Toast\admin.local.psd1 -Tag Pilot -SearchBase 'OU=PCs,DC=example,DC=test' -Filter 'Enabled -eq $true')
    Collects imported computers for a GUI grid.
    .OUTPUTS
    System.Management.Automation.PSCustomObject
    One object with ComputerName and Tag per processed computer, including
    existing memberships. No success objects during WhatIf.
    .NOTES
    Requires Windows, RSAT ActiveDirectory and administrator SQL permissions.
    Errors propagate to the caller; an import can partially succeed before a
    later computer fails. Keep src\Server and the sibling modules deployed.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ConfigPath,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][ValidateLength(1,128)][string]$Tag,
        [ValidateNotNullOrEmpty()][string]$Filter = '*',
        [ValidateNotNullOrEmpty()][string]$SearchBase
    )

    # The script owns per-computer ShouldProcess; forward WhatIf and Confirm.
    & "$PSScriptRoot\..\Server\Import-ToastADComputers.ps1" @PSBoundParameters
}

function Send-ToastMessage {
    <#
    .SYNOPSIS
    Queues a notification and returns its message ID for GUI use.
    .DESCRIPTION
    Reuses the standalone sender's validation, SQL and logging. Returns an
    object rather than parsing its console status text. Queueing is not proof
    of delivery or acknowledgement. WhatIf skips the entire send operation,
    including configuration reads, port checks, SQL and server logging.
    .PARAMETER ConfigPath
    Path to the administrator's local configuration data file.
    .PARAMETER GroupName
    Existing SQL notification group name (1-128 characters).
    .PARAMETER Title
    Required plain-text dialog title.
    .PARAMETER Body
    Required plain-text message. URLs are text, not clickable actions.
    .PARAMETER Subtitle
    Optional independent subtitle. A blank value uses the client default.
    .PARAMETER ExpiresUtc
    Future DateTimeOffset, timezone-qualified DateTime, or ISO 8601 text with
    Z/offset. Specify either this or ActiveDuration with DurationUnit.
    .PARAMETER ActiveDuration
    Positive integer duration, calculated by SQL at queue time.
    .PARAMETER DurationUnit
    Unit for ActiveDuration: Days, Hours or Minutes.
    .PARAMETER AcknowledgeButtonText
    Optional single acknowledgement button label, at most 200 characters.
    Blank uses the existing sender default. Timeout is reserved.
    .PARAMETER RepeatIntervalSeconds
    Positive integer repeat interval in seconds. Use this or minutes, not both,
    together with RepeatCount. Omit repeat settings for one display.
    .PARAMETER RepeatIntervalMinutes
    Positive integer repeat interval in minutes, instead of seconds.
    .PARAMETER RepeatCount
    Total acknowledgement count, at least 2, including the first display.
    Repetitions never extend the message expiry.
    .PARAMETER CheckSqlPort
    Enables the TCP precheck by default. Disabling it does not skip SQL
    authentication, TLS validation or normal error handling.
    .EXAMPLE
    $message = Send-ToastMessage -ConfigPath C:\Toast\admin.local.psd1 -GroupName Pilot -Title Maintenance -Body 'Save your work.' -ActiveDuration 2 -DurationUnit Hours
    $message.MessageId
    Queues a message and reads the returned ID without parsing console text.
    .EXAMPLE
    Send-ToastMessage -ConfigPath C:\Toast\admin.local.psd1 -GroupName Pilot -Title Test -Body Preview -ActiveDuration 15 -DurationUnit Minutes -WhatIf
    Previews the operation without connecting to SQL or queueing a message.
    .OUTPUTS
    System.Management.Automation.PSCustomObject
    One object with MessageId (Int64) and GroupName after successful queueing.
    No success object when WhatIf is used or confirmation is declined.
    .NOTES
    Requires Windows and administrator SQL permissions. Errors propagate to
    the caller. Keep src\Server and the sibling modules deployed.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ConfigPath,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][ValidateLength(1,128)][string]$GroupName,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Title,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Body,
        [AllowNull()][AllowEmptyString()][string]$Subtitle,
        [AllowNull()]$ExpiresUtc,
        [AllowNull()]$ActiveDuration,
        [ValidateSet('Days','Hours','Minutes')][string]$DurationUnit,
        [AllowNull()][AllowEmptyString()][string]$AcknowledgeButtonText,
        [Nullable[int]]$RepeatIntervalSeconds,
        [Nullable[int]]$RepeatIntervalMinutes,
        [Nullable[int]]$RepeatCount,
        [bool]$CheckSqlPort = $true
    )

    if ($PSCmdlet.ShouldProcess($GroupName, 'Queue notification message')) {
        $sendParameters = @{}
        foreach ($key in $PSBoundParameters.Keys) {
            if ($key -notin @('WhatIf', 'Confirm')) {
                $sendParameters[$key] = $PSBoundParameters[$key]
            }
        }
        & "$PSScriptRoot\..\Server\Send-ToastMessage.ps1" @sendParameters -PassThru
    }
}

Export-ModuleMember -Function Import-ToastADComputers, Send-ToastMessage
