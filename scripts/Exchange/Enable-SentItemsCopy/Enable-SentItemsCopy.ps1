#Requires -Version 5.1

<#
.SYNOPSIS
    Makes Exchange Online keep a copy in the shared mailbox when someone sends
    as, or on behalf of, that mailbox.

.DESCRIPTION
    Default behaviour: a reply sent from the info@ shared mailbox lands in the
    sender's personal Sent Items and nowhere else. The rest of the team has no
    idea the customer already got an answer, so two more people reply.

    Setting MessageCopyForSentAsEnabled and MessageCopyForSendOnBehalfEnabled
    puts the copy in the shared mailbox where the team can see it.

    Runs against every shared mailbox by default. Add -IncludeUserMailboxes if
    you want delegated user mailboxes covered as well.

.PARAMETER Identity
    Specific mailboxes to change. Leave empty to process everything in scope.

.PARAMETER IncludeUserMailboxes
    Also process regular user mailboxes, not just shared ones.

.PARAMETER Disable
    Turn the behaviour off again instead of on.

.EXAMPLE
    Connect-ExchangeOnline
    .\Enable-SentItemsCopy.ps1

.EXAMPLE
    .\Enable-SentItemsCopy.ps1 -WhatIf

.EXAMPLE
    .\Enable-SentItemsCopy.ps1 -Identity info@contoso.com, support@contoso.com

.NOTES
    Needs the ExchangeOnlineManagement module and a session opened with
    Connect-ExchangeOnline. Recipient Management is enough; you do not need
    Global Administrator.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string[]]$Identity,

    [switch]$IncludeUserMailboxes,

    [switch]$Disable
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not (Get-Command Get-Mailbox -ErrorAction SilentlyContinue)) {
    throw 'Get-Mailbox is not available. Run Connect-ExchangeOnline first (Install-Module ExchangeOnlineManagement).'
}

$targetValue = -not $Disable
$verb = if ($Disable) { 'Disable' } else { 'Enable' }

$types = if ($IncludeUserMailboxes) { 'SharedMailbox', 'UserMailbox' } else { 'SharedMailbox' }

$mailboxes = if ($Identity) {
    @($Identity | ForEach-Object { Get-Mailbox -Identity $_ -ErrorAction Stop })
}
else {
    @(Get-Mailbox -ResultSize Unlimited -RecipientTypeDetails $types)
}

Write-Host "Mailboxes in scope: $($mailboxes.Count)"

$results = [System.Collections.Generic.List[object]]::new()

foreach ($mailbox in $mailboxes) {

    $alreadyCorrect = $mailbox.MessageCopyForSentAsEnabled -eq $targetValue -and
                      $mailbox.MessageCopyForSendOnBehalfEnabled -eq $targetValue

    if ($alreadyCorrect) {
        $results.Add([pscustomobject]@{
                Mailbox = $mailbox.PrimarySmtpAddress
                Type    = $mailbox.RecipientTypeDetails
                Action  = 'NoChange'
            })
        continue
    }

    if ($PSCmdlet.ShouldProcess($mailbox.PrimarySmtpAddress, "$verb sent items copy")) {
        try {
            Set-Mailbox -Identity $mailbox.PrimarySmtpAddress `
                -MessageCopyForSentAsEnabled $targetValue `
                -MessageCopyForSendOnBehalfEnabled $targetValue `
                -ErrorAction Stop

            $results.Add([pscustomobject]@{
                    Mailbox = $mailbox.PrimarySmtpAddress
                    Type    = $mailbox.RecipientTypeDetails
                    Action  = "$($verb)d"
                })
        }
        catch {
            $results.Add([pscustomobject]@{
                    Mailbox = $mailbox.PrimarySmtpAddress
                    Type    = $mailbox.RecipientTypeDetails
                    Action  = "Failed: $($_.Exception.Message)"
                })
            Write-Warning "$($mailbox.PrimarySmtpAddress): $($_.Exception.Message)"
        }
    }
}

$changed = @($results | Where-Object Action -like "$verb*").Count
Write-Host "Changed: $changed. Already correct: $(@($results | Where-Object Action -eq 'NoChange').Count)."

return $results
