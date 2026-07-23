# 📨 Enable-SentItemsCopy

Keeps a copy in the shared mailbox when someone sends as, or on behalf of, that
mailbox.

## What it does

Sets `MessageCopyForSentAsEnabled` and `MessageCopyForSendOnBehalfEnabled` on
every shared mailbox. Mailboxes already configured correctly are reported as
`NoChange` and skipped.

## Why it exists

Default behaviour: a reply sent from `info@` lands in the sender's personal Sent
Items and nowhere else. The rest of the team sees an unanswered thread, so two
more people answer it. The customer gets three replies and forms an opinion about
your organisation.

## How to run

```powershell
Install-Module ExchangeOnlineManagement -Scope CurrentUser
Connect-ExchangeOnline

.\Enable-SentItemsCopy.ps1
.\Enable-SentItemsCopy.ps1 -WhatIf
```

Specific mailboxes, or delegated user mailboxes as well:

```powershell
.\Enable-SentItemsCopy.ps1 -Identity info@contoso.com, support@contoso.com
.\Enable-SentItemsCopy.ps1 -IncludeUserMailboxes
```

Turn it back off with `-Disable`.

## Where it bites

**New shared mailboxes do not inherit this.** There is no tenant-wide default to
set. Every mailbox created after your last run is back to the old behaviour, so
either schedule this or add it to your mailbox creation runbook.

**Outlook caches aggressively.** The change is instant server-side, but a desktop
Outlook client in cached mode can take a while to reflect it. Do not conclude it
failed because the first test message went to the wrong folder.

**`-IncludeUserMailboxes` hits everything.** It covers regular user mailboxes,
not just the ones with delegates. Usually harmless, occasionally surprising for
people who delegate their own mailbox to an assistant. Run it with `-WhatIf`
first to see the scope.

**Recipient Management is enough.** No Global Administrator needed.
