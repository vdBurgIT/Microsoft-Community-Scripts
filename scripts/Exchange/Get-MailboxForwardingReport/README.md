# ↪️ Get-MailboxForwardingReport

Every mailbox that sends mail out of the organisation, through the setting or
through a rule.

## What it does

Checks both places mail can leave:

- The mailbox setting, `ForwardingSmtpAddress` and `ForwardingAddress`
- Inbox rules with a forward, forward-as-attachment or redirect action

Each destination is compared against your accepted domains, so internal
forwarding does not bury the one rule sending copies to a personal address.

Nothing is changed.

## Why it exists

Mailbox-level forwarding is visible in the admin centre and gets audited.
Rule-level forwarding is set by the user, is invisible in the admin centre, and
is the first thing an attacker creates after taking over a mailbox: a rule that
copies everything out and files the original away.

Checking one and not the other is the common mistake, and it is the one that
matters.

## How to run

```powershell
Install-Module ExchangeOnlineManagement -Scope CurrentUser
Connect-ExchangeOnline

.\Get-MailboxForwardingReport.ps1
.\Get-MailboxForwardingReport.ps1 -ExternalOnly -CsvPath .\forwarding.csv
.\Get-MailboxForwardingReport.ps1 -SkipInboxRules
.\Get-MailboxForwardingReport.ps1 -Identity anna@contoso.com
```

## Where it bites

**`Get-InboxRule` does not work for View-Only Organization Management, and it
does not work for the Global Reader role in Entra ID.** You need a role that can
read mailbox contents. Organization Management works. So does a custom role group
with the Mail Recipients role. This is the most common reason the rule half comes
back empty.

**It is one call per mailbox and Exchange Online throttles it.** Budget roughly a
second per mailbox. Five hundred mailboxes is an eight-minute run, and it is not
something to start in the middle of a migration. `-SkipInboxRules` gives you the
mailbox setting in seconds, and misses the interesting half.

**Mailboxes on hold or mid-migration refuse.** Those are collected and listed at
the end rather than stopping the run. Read that list: a mailbox you could not
check is not a mailbox that came back clean.

**Rule actions are not always addresses.** A rule can forward to a contact or a
distribution list, in which case you get a display name rather than an SMTP
address. The script pulls an address out where the string contains one and falls
back to the raw text otherwise. `IsExternal` is empty for those, because there is
no domain to judge.

**An outbound spam policy can already be blocking this.** Automatic forwarding to
external recipients is off by default in the anti-spam outbound policy in newer
tenants. A rule can exist, be enabled, and quietly deliver nothing. Finding the
rule is still worth it: somebody created it, and you want to know why.

**Shared mailboxes are included by default.** They are a common place for a
forward that was set up years ago for a person who has left.
