# 🧾 Get-LicenseAssignmentReport

Who has which licence, where it came from, and how many you are paying for and
not using.

## What it does

Two views:

- Per SKU: bought, assigned, available, and how many sit on blocked accounts.
  Printed every run, returned on its own with `-Summary`.
- Per user and SKU: one row per licence, with the group when it is group-based
  and the error state when the assignment failed.

Nothing is changed.

## Why it exists

The licences page in the admin centre shows totals. It does not show you the
forty E3 licences sitting on accounts that were blocked eight months ago, and it
does not export the per-user detail in a shape you can pivot.

Group-based licensing makes it worse rather than better: a user can hold the same
SKU twice, once direct and once through a group, and removing them from the group
frees nothing.

## How to run

```powershell
./Get-LicenseAssignmentReport.ps1
./Get-LicenseAssignmentReport.ps1 -Summary
./Get-LicenseAssignmentReport.ps1 -DisabledUsersOnly -CsvPath ./licences-on-blocked-accounts.csv
./Get-LicenseAssignmentReport.ps1 -ErrorsOnly
```

Graph scopes: `Organization.Read.All`, `User.Read.All`, `Group.Read.All`.

## Where it bites

**SKU part numbers are not product names.** `ENTERPRISEPACK` is Microsoft 365 E3.
`SPE_E5` is Microsoft 365 E5. `STANDARDPACK` is E1. Microsoft publishes the full
mapping as "Product names and service plan identifiers for licensing" on
Microsoft Learn. It changes often enough that hardcoding it in this script would
age badly, so you get the part number and a link.

**Direct and group assignment stack.** Both show up as separate rows with the
same SKU for the same user. `consumedUnits` counts the user once. If your per-user
row count does not match the summary, this is why, and it is also why removing
someone from a licensing group sometimes frees nothing at all.

**An assignment error is almost always a missing usage location.** Graph will not
assign a licence to an account without `usageLocation` set. `-ErrorsOnly` gives
you that list, and the `UsageLocation` column is usually empty on every row in
it.

**`InWarningState` means the subscription lapsed.** Those units are in the grace
period after expiry. Everything still works, which is exactly why nobody notices
until it stops. The summary calls it out separately.

**Available is not the same as safe to cancel.** A licence pool with headroom is
also a licence pool that can absorb next month's starters. Take the
`OnBlockedAccount` count to the conversation instead: that one is money going
nowhere.

**Guests can hold licences.** Rare, usually accidental, and included here with
`UserType` set to `Guest`.
