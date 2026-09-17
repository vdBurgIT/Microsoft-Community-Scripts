# 🧊 Get-StaleUserReport

Accounts that have not signed in for months, and the licences they are still
holding.

## What it does

Reads `signInActivity` from every account, works out how long each one has been
quiet, and returns the stale ones with their licence count, department and
creation date. Accounts that never signed in at all get their own status, because
that is a different problem from a forgotten account.

Nothing is changed. The result goes to the pipeline.

## Why it exists

Licence reviews start with a question nobody can answer from the portal: who is
not using this. The Entra portal shows last sign-in per user, one user at a time.
Getting the whole tenant into a spreadsheet means Graph, and by the time you have
written the paging and the date maths it is an hour later.

## How to run

```powershell
./Get-StaleUserReport.ps1
./Get-StaleUserReport.ps1 -DaysInactive 180 -LicensedOnly -CsvPath ./stale-users.csv
```

Everything, guests included, longest quiet first:

```powershell
./Get-StaleUserReport.ps1 -IncludeGuests -IncludeDisabled -IncludeActive |
    Sort-Object DaysSinceSignIn -Descending
```

Graph scopes: `User.Read.All` and `AuditLog.Read.All`.

## Where it bites

**`signInActivity` needs Entra ID P1 or P2.** Without it Graph happily returns
the users and silently leaves the property out, which makes every account look
like it never signed in. The script checks for that and warns instead of handing
you a report full of false positives. If you see that warning, check your licence
tier before acting on anything.

**Non-interactive sign-in counts.** An account with no interactive sign-in for a
year can still be signing in every five minutes through a refresh token or a
service. The script takes the most recent of the two dates. If you only look at
`LastSignIn` you will disable something that is very much in use.

**Synced accounts belong to Active Directory.** Disabling one in Entra gets
undone by the next sync cycle. The summary counts them separately so you know
which ones need doing on-premises.

**`lastSuccessfulSignInDateTime` is a third date.** It exists on the resource and
records the last sign-in that actually succeeded, as opposed to the last attempt.
This script does not use it, because the two dates it does use answer the "is
anyone using this account" question and the third one mostly adds noise.

**Sign-in data goes back 30 days for reporting, but `signInActivity` is not
capped that way.** It keeps the real last sign-in even when the sign-in logs
themselves have rolled off, which is why this uses the property rather than the
audit log.
