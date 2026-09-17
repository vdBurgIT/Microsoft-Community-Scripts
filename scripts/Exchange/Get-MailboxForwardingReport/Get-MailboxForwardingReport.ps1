#Requires -Version 5.1

<#
.SYNOPSIS
    Finds every mailbox that forwards mail outside the organisation, both through
    the mailbox setting and through inbox rules.

.DESCRIPTION
    Two places mail can leave the building, and admins usually check one of them.

    - The mailbox setting (ForwardingSmtpAddress and ForwardingAddress). Visible
      in the admin centre, easy to audit.
    - Inbox rules with a forward, forward-as-attachment or redirect action. Set
      by the user, invisible in the admin centre, and the first thing that gets
      created after a mailbox is taken over.

    Every destination is compared against your accepted domains, so internal
    forwarding to a colleague does not drown out the one rule sending copies to a
    personal address.

    Nothing is changed.

.PARAMETER Identity
    Specific mailboxes to check. Leave empty to check everything in scope.

.PARAMETER RecipientTypeDetails
    Mailbox types to include.

.PARAMETER ExternalOnly
    Only report forwarding to a domain that is not an accepted domain.

.PARAMETER SkipInboxRules
    Only check the mailbox setting. Much faster, and misses the half that
    matters, so use it when you already know the rules are clean.

.PARAMETER CsvPath
    Also write the result to this CSV.

.EXAMPLE
    Connect-ExchangeOnline
    .\Get-MailboxForwardingReport.ps1

.EXAMPLE
    # Only mail leaving the organisation, into a CSV
    .\Get-MailboxForwardingReport.ps1 -ExternalOnly -CsvPath .\forwarding.csv

.EXAMPLE
    # Quick sweep of the mailbox setting on a big tenant
    .\Get-MailboxForwardingReport.ps1 -SkipInboxRules

.EXAMPLE
    # One mailbox, after a phishing report
    .\Get-MailboxForwardingReport.ps1 -Identity anna@contoso.com

.NOTES
    Needs the ExchangeOnlineManagement module and a session from
    Connect-ExchangeOnline.

    Get-InboxRule does not work for View-Only Organization Management or for the
    Global Reader role in Microsoft Entra ID. You need a role that can actually
    read mailbox contents, for example Organization Management or a custom role
    with the Mail Recipients role assigned.

    Reading inbox rules means one call per mailbox and Exchange Online throttles
    it. Budget roughly a second per mailbox and do not run it in the middle of a
    migration.
#>

[CmdletBinding()]
param(
    # Specific mailboxes to check
    [string[]]$Identity,

    # Mailbox types in scope
    [string[]]$RecipientTypeDetails = @('UserMailbox', 'SharedMailbox'),

    # Only forwarding that leaves the organisation
    [switch]$ExternalOnly,

    # Skip the inbox rule sweep
    [switch]$SkipInboxRules,

    # Optional CSV export path
    [string]$CsvPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not (Get-Command Get-Mailbox -ErrorAction SilentlyContinue)) {
    throw 'Get-Mailbox is not available. Run Connect-ExchangeOnline first (Install-Module ExchangeOnlineManagement).'
}

# ================================================== accepted domains ========

Write-Host 'Reading accepted domains...' -ForegroundColor Cyan
$acceptedDomains = @(Get-AcceptedDomain | ForEach-Object { "$($_.DomainName)".ToLower() })
Write-Host "  $($acceptedDomains.Count) accepted domain(s)."

function Test-ExternalAddress {
    <# An address counts as external when its domain is not an accepted domain.
       Rule actions can hold a display name instead of an address, in which case
       there is nothing to judge and we say so. #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Address)

    if ([string]::IsNullOrWhiteSpace($Address) -or $Address -notmatch '@') { return $null }

    $domain = ($Address -split '@')[-1].Trim().TrimEnd('>', ']', ')').ToLower()
    return (-not ($acceptedDomains -contains $domain))
}

function Get-AddressText {
    <# Rule actions come back as recipient objects with varying shapes. Pull out
       something that is actually an address where possible. #>
    param($Recipient)

    if ($null -eq $Recipient) { return '' }

    $text = "$Recipient"

    # The common Exchange Online shape is "Display Name [SMTP:user@contoso.com]".
    if ($text -match '(?i)smtp:([^\]\s;]+)') { return $Matches[1] }
    if ($text -match '([^\s<>\[\];"]+@[^\s<>\[\];"]+)') { return $Matches[1] }

    return $text
}

function Get-MailboxProperty {
    <# Get-EXOMailbox only returns the properties you asked for, and StrictMode
       turns a missing one into a terminating error. This keeps the report
       running against whichever cmdlet ended up being used. #>
    param($Mailbox, [Parameter(Mandatory)][string]$Name)

    if ($Mailbox -and $Mailbox.PSObject.Properties.Name -contains $Name) {
        return $Mailbox.$Name
    }
    return $null
}

# ======================================================== mailboxes =========

$useExo = $null -ne (Get-Command Get-EXOMailbox -ErrorAction SilentlyContinue)

Write-Host 'Fetching mailboxes...' -ForegroundColor Cyan

# Ask for the forwarding properties by name. Get-EXOMailbox returns the Minimum
# property set otherwise, and the forwarding fields are not in it.
$wanted = @(
    'DisplayName', 'PrimarySmtpAddress', 'RecipientTypeDetails',
    'ForwardingAddress', 'ForwardingSmtpAddress', 'DeliverToMailboxAndForward'
)

$mailboxes = if ($Identity) {
    @($Identity | ForEach-Object {
        if ($useExo) {
            Get-EXOMailbox -Identity $_ -Properties $wanted -ErrorAction Stop
        }
        else {
            Get-Mailbox -Identity $_ -ErrorAction Stop
        }
    })
}
elseif ($useExo) {
    # The REST cmdlet is several times faster on a tenant of any size.
    @(Get-EXOMailbox -ResultSize Unlimited -RecipientTypeDetails $RecipientTypeDetails -Properties $wanted)
}
else {
    @(Get-Mailbox -ResultSize Unlimited -RecipientTypeDetails $RecipientTypeDetails)
}

Write-Host "  $($mailboxes.Count) mailbox(es) in scope."
if ($mailboxes.Count -eq 0) { return @() }

# =================================================== mailbox forwarding =====

$rows = [System.Collections.Generic.List[object]]::new()

foreach ($mailbox in $mailboxes) {

    $smtpForward = "$(Get-MailboxProperty -Mailbox $mailbox -Name 'ForwardingSmtpAddress')"
    $recipientForward = "$(Get-MailboxProperty -Mailbox $mailbox -Name 'ForwardingAddress')"

    foreach ($pair in @(
        @{ Value = $smtpForward; Field = 'ForwardingSmtpAddress' },
        @{ Value = $recipientForward; Field = 'ForwardingAddress' }
    )) {
        if ([string]::IsNullOrWhiteSpace($pair.Value)) { continue }

        $address = Get-AddressText -Recipient $pair.Value
        $external = Test-ExternalAddress -Address $address
        if ($ExternalOnly -and $external -ne $true) { continue }

        $rows.Add([pscustomobject]@{
            Mailbox                    = "$(Get-MailboxProperty -Mailbox $mailbox -Name 'PrimarySmtpAddress')"
            DisplayName                = "$(Get-MailboxProperty -Mailbox $mailbox -Name 'DisplayName')"
            MailboxType                = "$(Get-MailboxProperty -Mailbox $mailbox -Name 'RecipientTypeDetails')"
            Source                     = $pair.Field
            RuleName                   = ''
            RuleEnabled                = ''
            ForwardsTo                 = $address
            IsExternal                 = $external
            DeliverToMailboxAndForward = Get-MailboxProperty -Mailbox $mailbox -Name 'DeliverToMailboxAndForward'
        })
    }
}

Write-Host "  $($rows.Count) mailbox-level forward(s)."

# ======================================================== inbox rules =======

if (-not $SkipInboxRules) {
    Write-Host 'Reading inbox rules (one call per mailbox, this takes a while)...' -ForegroundColor Cyan

    $ruleActions = @('ForwardTo', 'ForwardAsAttachmentTo', 'RedirectTo')
    $failed = [System.Collections.Generic.List[string]]::new()
    $index = 0

    foreach ($mailbox in $mailboxes) {
        $index++
        $smtp = "$(Get-MailboxProperty -Mailbox $mailbox -Name 'PrimarySmtpAddress')"

        Write-Progress -Activity 'Reading inbox rules' -Status "$index / $($mailboxes.Count): $smtp" `
            -PercentComplete ([int](100 * $index / $mailboxes.Count))

        $rules = @()
        try {
            $rules = @(Get-InboxRule -Mailbox $smtp -ErrorAction Stop)
        }
        catch {
            # A mailbox that is on hold, inactive or mid-migration will refuse.
            # Collect those and report them at the end instead of stopping.
            $failed.Add("${smtp}: $($_.Exception.Message)")
            continue
        }

        foreach ($rule in $rules) {
            foreach ($action in $ruleActions) {
                $recipients = @($rule.$action)
                if ($recipients.Count -eq 0) { continue }

                foreach ($recipient in $recipients) {
                    if ($null -eq $recipient) { continue }

                    $address = Get-AddressText -Recipient $recipient
                    $external = Test-ExternalAddress -Address $address
                    if ($ExternalOnly -and $external -ne $true) { continue }

                    $rows.Add([pscustomobject]@{
                        Mailbox                    = $smtp
                        DisplayName                = "$(Get-MailboxProperty -Mailbox $mailbox -Name 'DisplayName')"
                        MailboxType                = "$(Get-MailboxProperty -Mailbox $mailbox -Name 'RecipientTypeDetails')"
                        Source                     = "InboxRule/$action"
                        RuleName                   = "$($rule.Name)"
                        RuleEnabled                = $rule.Enabled
                        ForwardsTo                 = $address
                        IsExternal                 = $external
                        DeliverToMailboxAndForward = ''
                    })
                }
            }
        }
    }

    Write-Progress -Activity 'Reading inbox rules' -Completed

    if ($failed.Count -gt 0) {
        Write-Warning "$($failed.Count) mailbox(es) could not be read:"
        $failed | ForEach-Object { Write-Host "  - $_" -ForegroundColor DarkYellow }
    }
}

# ================================================================ summary ===

$sorted = @($rows | Sort-Object @{ Expression = 'IsExternal'; Descending = $true }, Mailbox, Source)

$external = @($sorted | Where-Object { $_.IsExternal -eq $true })
$viaRules = @($external | Where-Object { $_.Source -like 'InboxRule/*' })

Write-Host ''
Write-Host "Forwards     : $($sorted.Count)"
Write-Host "External     : $($external.Count)" -ForegroundColor $(if ($external.Count -gt 0) { 'Yellow' } else { 'Green' })
Write-Host "Via a rule   : $($viaRules.Count)" -ForegroundColor $(if ($viaRules.Count -gt 0) { 'Red' } else { 'Green' })

if ($CsvPath) {
    $sorted | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $CsvPath
    Write-Host "CSV          : $CsvPath" -ForegroundColor Green
}

if ($viaRules.Count -gt 0) {
    Write-Host ''
    Write-Warning ('Inbox rules forwarding outside the organisation are worth a look one by one. ' +
        'Some are a user being practical about a second address. Some are not.')
}

return $sorted
