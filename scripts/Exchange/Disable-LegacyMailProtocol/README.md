# 🔒 Disable-LegacyMailProtocol

Turns off POP, IMAP and authenticated SMTP per mailbox.

## What it does

Reads the CAS mailbox settings for every mailbox in scope, reports which
protocols are on, and switches off the ones you named. Mailboxes already correct
are reported as `NoChange` and skipped, so this is safe to schedule: mailboxes
created since the last run get picked up.

The organisation-wide SMTP AUTH setting is printed first, because the per-mailbox
value only makes sense once you know what it inherits from.

Supports `-WhatIf`.

## Why it exists

POP and IMAP do not understand modern authentication, which means they do not
understand MFA either. Password spray campaigns target them for exactly that
reason. Authenticated SMTP is the same story and stays on for the one
multifunction printer nobody wants to touch.

Turning them off tenant-wide is one setting. Turning them off per mailbox while
keeping the scanner working is this script.

## How to run

```powershell
Install-Module ExchangeOnlineManagement -Scope CurrentUser
Connect-ExchangeOnline

.\Disable-LegacyMailProtocol.ps1 -WhatIf
.\Disable-LegacyMailProtocol.ps1
.\Disable-LegacyMailProtocol.ps1 -Protocol Pop, Imap, SmtpAuth, ActiveSync
.\Disable-LegacyMailProtocol.ps1 -Enable -Protocol SmtpAuth -Identity scanner@contoso.com
```

Recipient Management is enough. Global Administrator is not needed.

## Where it bites

**`SmtpClientAuthenticationDisabled` is inverted and has three states.** `$null`
means the mailbox follows the organisation setting. `$true` means SMTP AUTH is
off for this mailbox. `$false` means it is on even when the organisation has it
off. That last one is how you keep a scanner working after disabling SMTP AUTH
tenant-wide, and it is also how a mailbox stays open after somebody "fixed" a
ticket two years ago.

**The safe order is per mailbox first, tenant-wide second.** Switch it off for
everyone who does not need it, wait for the tickets, then run
`Set-TransportConfig -SmtpClientAuthenticationDisabled $true` so new mailboxes
inherit the right default. Doing it the other way round means every application
breaks at once.

**ActiveSync is not in the default set on purpose.** It is the protocol native
mail apps on phones use. Disable it and mail stops on every iPhone that is not
using Outlook. The script warns when you put it in scope.

**Authentication policies are the stronger control.** Blocking legacy
authentication with a Conditional Access policy or an authentication policy stops
the protocols at the door instead of per mailbox. This script is the
defence-in-depth layer, and the one you can run today without a Conditional
Access change window.

**Mailboxes in the middle of a migration refuse the change.** Those are reported
as `Failed` with the message and the run continues.

**New mailboxes inherit the tenant default, not your last run.** Until you have
set the organisation-wide switch, every mailbox created after this runs is back
to the old behaviour. Schedule it or add it to the mailbox creation runbook.
