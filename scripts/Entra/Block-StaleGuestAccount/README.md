# 🚪 Block-StaleGuestAccount

Blocks sign-in on guests that never accepted their invitation or stopped showing
up.

## What it does

Finds guest accounts that are either past `-PendingAcceptanceDays` without ever
signing in, or past `-DaysInactive` since their last sign-in, and sets
`accountEnabled` to false. Member accounts are never touched.

Supports `-WhatIf`, stops at `-MaxToBlock`, and `-Unblock` puts named accounts
back.

## Why it exists

Guests arrive one shared document at a time and never leave. Most tenants have
more guests than employees and no idea which ones still need access.

Blocking rather than deleting is deliberate. The account keeps its group
memberships and its sharing permissions, so when somebody turns out to still need
it, you re-enable it and everything works. Delete the account and the person who
shared the file gets to do it all again.

## How to run

```powershell
./Block-StaleGuestAccount.ps1 -WhatIf
./Block-StaleGuestAccount.ps1 -DaysInactive 180 -CsvPath ./blocked-guests.csv
./Block-StaleGuestAccount.ps1 -ExcludeUpn '*partner.com*', 'auditor@contoso.com'
./Block-StaleGuestAccount.ps1 -Unblock -ExcludeUpn 'anna@contoso.com'
```

Graph scopes: `User.ReadWrite.All`, `AuditLog.Read.All`, and `Directory.Read.All`
unless you pass `-SkipRoleCheck`.

## Where it bites

**It refuses to run on a tenant without Entra ID P1.** No P1 means no
`signInActivity`, which means every guest reads as abandoned. Blocking on that
data would hit the entire guest directory, so the script throws instead. This is
the one place where failing is the feature.

**Guests can hold admin roles.** Rare, and exactly the account you do not want to
block by accident. The role check is on by default and costs the
`Directory.Read.All` scope. `-SkipRoleCheck` turns it off and accepts the risk.

**Guest UPNs are mangled.** An invited `anna@partner.com` becomes
`anna_partner.com#EXT#@contoso.onmicrosoft.com`. `-ExcludeUpn` is matched against
both the UPN and the mail address, so `'*partner.com*'` catches both shapes.
Check your `-WhatIf` output before assuming a pattern matched.

**`-MaxToBlock` defaults to 50.** Not because 50 is a meaningful number, but
because a wrong `-DaysInactive` on a first run should be annoying rather than
expensive. Raise it once you have read the list.

**Blocked is not gone.** The guests still count towards your directory, they
still appear in people pickers, and they still hold whatever was shared with
them. This buys you a safe first step, not a clean directory. Delete them once
you are confident, and remember that deleting a guest does not remove the sharing
links that pointed at them.
