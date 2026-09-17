#Requires -Version 5.1

<#
.SYNOPSIS
    Turns off POP, IMAP and authenticated SMTP per mailbox, so password spray
    attempts have nothing left to land on.

.DESCRIPTION
    POP and IMAP do not understand modern authentication, which means they do not
    understand MFA either. Authenticated SMTP is the same story and stays on for
    the one multifunction printer nobody wants to touch.

    Walks the mailboxes in scope, reports which protocols are on, and switches
    off the ones you named. Mailboxes already correct are reported as NoChange
    and skipped, so this is safe on a schedule: mailboxes created after your last
    run get picked up automatically.

    The organisation-wide SMTP AUTH setting is read first and printed, because
    the per-mailbox value only matters once you know what it is inheriting from.

    Supports -WhatIf.

.PARAMETER Protocol
    Which protocols to act on. ActiveSync is deliberately not in the default: it
    is the one that stops mail on phones.

.PARAMETER Identity
    Specific mailboxes. Leave empty for everything in scope.

.PARAMETER RecipientTypeDetails
    Mailbox types to include.

.PARAMETER Enable
    Turn the named protocols back on instead of off.

.PARAMETER CsvPath
    Also write the result to this CSV.

.EXAMPLE
    Connect-ExchangeOnline
    .\Disable-LegacyMailProtocol.ps1 -WhatIf

.EXAMPLE
    .\Disable-LegacyMailProtocol.ps1

.EXAMPLE
    # Include ActiveSync, once you have checked nobody is on a native mail app
    .\Disable-LegacyMailProtocol.ps1 -Protocol Pop, Imap, SmtpAuth, ActiveSync

.EXAMPLE
    # Put SMTP AUTH back for the mailbox the scanner uses
    .\Disable-LegacyMailProtocol.ps1 -Enable -Protocol SmtpAuth -Identity scanner@contoso.com

.NOTES
    Needs the ExchangeOnlineManagement module and a session from
    Connect-ExchangeOnline. Recipient Management is enough; Global Administrator
    is not needed.

    SmtpClientAuthenticationDisabled is inverted and tri-state. $null means the
    mailbox follows the organisation setting, $true means SMTP AUTH is off for
    this mailbox, $false means it is on even when the organisation has it off.
    That last case is how you keep one scanner working after disabling SMTP AUTH
    tenant-wide, and it is also how people accidentally leave a mailbox open.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    # Protocols to act on
    [ValidateSet('Pop', 'Imap', 'SmtpAuth', 'ActiveSync')]
    [string[]]$Protocol = @('Pop', 'Imap', 'SmtpAuth'),

    # Specific mailboxes
    [string[]]$Identity,

    # Mailbox types in scope
    [string[]]$RecipientTypeDetails = @('UserMailbox', 'SharedMailbox'),

    # Turn the protocols back on instead of off
    [switch]$Enable,

    # Optional CSV export path
    [string]$CsvPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not (Get-Command Get-CASMailbox -ErrorAction SilentlyContinue)) {
    throw 'Get-CASMailbox is not available. Run Connect-ExchangeOnline first (Install-Module ExchangeOnlineManagement).'
}

# ---------------------------------------------------------------- mapping ---

# Inverted marks the odd one out: SmtpClientAuthenticationDisabled is $true when
# the protocol is off, where every other property is $true when it is on.
$map = @{
    Pop        = @{ Property = 'PopEnabled'; Inverted = $false; Label = 'POP3' }
    Imap       = @{ Property = 'ImapEnabled'; Inverted = $false; Label = 'IMAP4' }
    ActiveSync = @{ Property = 'ActiveSyncEnabled'; Inverted = $false; Label = 'Exchange ActiveSync' }
    SmtpAuth   = @{ Property = 'SmtpClientAuthenticationDisabled'; Inverted = $true; Label = 'authenticated SMTP' }
}

$turnOn = $Enable.IsPresent

if ($Protocol -contains 'ActiveSync' -and -not $turnOn) {
    Write-Warning 'ActiveSync is in scope. Native mail apps on phones use it, and they stop working the moment this runs.'
}

# ------------------------------------------------- organisation baseline ---

try {
    $transport = Get-TransportConfig -ErrorAction Stop
    $orgSmtpDisabled = $transport.SmtpClientAuthenticationDisabled
    $orgLabel = if ($orgSmtpDisabled) { 'off' } else { 'on' }
    Write-Host "SMTP AUTH organisation-wide: $orgLabel (Set-TransportConfig -SmtpClientAuthenticationDisabled `$$orgSmtpDisabled)"
}
catch {
    Write-Warning "Could not read the organisation SMTP AUTH setting: $($_.Exception.Message)"
}

# ------------------------------------------------------------- mailboxes ---

Write-Host 'Fetching CAS mailbox settings...' -ForegroundColor Cyan

$mailboxes = if ($Identity) {
    @($Identity | ForEach-Object { Get-CASMailbox -Identity $_ -ErrorAction Stop })
}
else {
    @(Get-CASMailbox -ResultSize Unlimited -RecipientTypeDetails $RecipientTypeDetails)
}

Write-Host "  $($mailboxes.Count) mailbox(es) in scope."
if ($mailboxes.Count -eq 0) { return @() }

# ---------------------------------------------------------------- change ---

$results = [System.Collections.Generic.List[object]]::new()
$index = 0

foreach ($mailbox in $mailboxes) {
    $index++
    $smtp = "$($mailbox.PrimarySmtpAddress)"

    Write-Progress -Activity 'Checking mailboxes' -Status "$index / $($mailboxes.Count): $smtp" `
        -PercentComplete ([int](100 * $index / $mailboxes.Count))

    $changes = @{}
    $before = @{}

    foreach ($name in $Protocol) {
        $entry = $map[$name]
        $property = $entry.Property

        $current = if ($mailbox.PSObject.Properties.Name -contains $property) { $mailbox.$property } else { $null }
        $before[$name] = $current

        # Work out the value the property should hold, which is inverted for
        # SmtpClientAuthenticationDisabled.
        $wanted = if ($entry.Inverted) { -not $turnOn } else { $turnOn }

        if ($current -ne $wanted) { $changes[$property] = $wanted }
    }

    $row = [pscustomobject]@{
        Mailbox     = $smtp
        DisplayName = "$($mailbox.DisplayName)"
        Pop         = if ($before.ContainsKey('Pop')) { $before['Pop'] } else { '' }
        Imap        = if ($before.ContainsKey('Imap')) { $before['Imap'] } else { '' }
        ActiveSync  = if ($before.ContainsKey('ActiveSync')) { $before['ActiveSync'] } else { '' }
        SmtpAuthOff = if ($before.ContainsKey('SmtpAuth')) { $before['SmtpAuth'] } else { '' }
        Changed     = ($changes.Keys -join ', ')
        Action      = 'NoChange'
    }

    if ($changes.Count -eq 0) {
        $results.Add($row)
        continue
    }

    $labels = @($Protocol | Where-Object { $changes.ContainsKey($map[$_].Property) } | ForEach-Object { $map[$_].Label })
    $what = if ($turnOn) { "Enable $($labels -join ', ')" } else { "Disable $($labels -join ', ')" }

    if ($PSCmdlet.ShouldProcess($smtp, $what)) {
        try {
            Set-CASMailbox -Identity $smtp @changes -ErrorAction Stop
            $row.Action = if ($turnOn) { 'Enabled' } else { 'Disabled' }
        }
        catch {
            # A shared mailbox without a licence, or one mid-migration, will
            # refuse. One refusal should not end the run.
            $row.Action = "Failed: $($_.Exception.Message)"
            Write-Warning "${smtp}: $($_.Exception.Message)"
        }
    }
    else {
        $row.Action = 'Skipped'
    }

    $results.Add($row)
}

Write-Progress -Activity 'Checking mailboxes' -Completed

# --------------------------------------------------------------- summary ---

$changed = @($results | Where-Object { $_.Action -in @('Enabled', 'Disabled') }).Count
$noChange = @($results | Where-Object Action -eq 'NoChange').Count
$failed = @($results | Where-Object { $_.Action -like 'Failed*' }).Count

Write-Host ''
Write-Host "Protocols    : $($Protocol -join ', ')"
Write-Host "Changed      : $changed"
Write-Host "Already right: $noChange"
Write-Host "Failed       : $failed"

if ($CsvPath) {
    $results | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $CsvPath
    Write-Host "CSV          : $CsvPath" -ForegroundColor Green
}

if (-not $turnOn -and $Protocol -contains 'SmtpAuth') {
    Write-Host ''
    Write-Host 'Turning SMTP AUTH off per mailbox is the safe order. Once nothing breaks, switch it off for the whole organisation with Set-TransportConfig -SmtpClientAuthenticationDisabled $true.' -ForegroundColor Cyan
}

return $results
