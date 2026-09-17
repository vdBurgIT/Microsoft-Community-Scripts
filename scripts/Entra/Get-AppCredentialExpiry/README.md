# 🔑 Get-AppCredentialExpiry

Every client secret and certificate in the tenant, with the date it expires and
the owner to chase.

## What it does

Walks your app registrations, optionally the enterprise applications too, and
returns one row per credential: type, name, start, end, days left, status and
owners. Already-expired credentials are included by default.

Nothing is changed. Secret values cannot be read back and this does not try.

## Why it exists

A client secret expires on a Saturday and something stops working on Monday. The
portal shows expiry per app registration, on a tab, one app at a time. Nobody
checks fifty apps by hand, so the first sign is the outage.

The owners column is the useful half. Knowing a secret expires in nine days is
only half a job if nobody knows whose secret it is.

## How to run

```powershell
./Get-AppCredentialExpiry.ps1
./Get-AppCredentialExpiry.ps1 -DaysAhead 90 -IncludeServicePrincipals
./Get-AppCredentialExpiry.ps1 -DaysAhead 0 -CsvPath ./app-credentials.csv
```

Graph scopes: `Application.Read.All`, plus `User.Read.All` for the owner lookup.

## Where it bites

**Enterprise applications are mostly Microsoft's.** A tenant has hundreds of
first-party service principals and their certificates rotate on their own. The
script filters those out by `appOwnerOrganizationId`, so `-IncludeServicePrincipals`
returns yours. Use `-IncludeMicrosoftApps` if you really want the lot.

**An expired credential does not mean a broken app.** Apps often carry several
secrets. One expired and two valid is normal, and it is also how you end up with
eleven secrets on one registration. Sort by `DisplayName` to see that pattern.

**SAML signing certificates live on the service principal, not the app
registration.** If you are chasing a SAML app whose sign-in is about to break,
you need `-IncludeServicePrincipals` or you will not see it.

**No owner is common and not harmless.** App registrations created by someone who
has left keep working and belong to nobody. Those show up with an empty `Owners`
column, and they are the ones that turn into an incident.

**Owner lookup costs one call per object.** In a tenant with a few thousand
registrations that is the slow part of the run. `-SkipOwners` drops it.
