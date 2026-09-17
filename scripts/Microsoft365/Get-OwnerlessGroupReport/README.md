# 👥 Get-OwnerlessGroupReport

Microsoft 365 groups and Teams with no owner, one owner, or only blocked owners.

## What it does

Checks every Microsoft 365 group and gives it a status:

- `NoOwner`: nobody owns it
- `OwnersBlocked`: every owner is blocked from signing in, which is no owner with
  extra steps
- `SingleOwner`: one owner, one resignation away from `NoOwner`
- `Ok`: two or more owners who can sign in

Nothing is changed. Adding an owner is a decision, not a cleanup.

## Why it exists

Owners leave. The group stays, with its Team, its SharePoint site and its
mailbox, and now nobody can add a member, approve a join request or delete it.
The first person to notice is the one who needed access today, and the ticket
lands on you.

`OwnersBlocked` is the status people miss. The group has an owner on paper, so it
does not show up in the obvious report, and that owner left in March.

## How to run

```powershell
./Get-OwnerlessGroupReport.ps1
./Get-OwnerlessGroupReport.ps1 -Status NoOwner, OwnersBlocked, SingleOwner, Ok -IncludeMemberCount -CsvPath ./groups.csv
./Get-OwnerlessGroupReport.ps1 -Status NoOwner -TeamsOnly
```

Graph scopes: `Group.Read.All` and `User.Read.All`.

## Where it bites

**Microsoft 365 groups only.** Security groups and distribution lists are not
covered. This is about the groups that carry a Team, a site and a mailbox, which
are the ones where an absent owner actually blocks people.

**There is a built-in policy for this.** The ownerless group policy in the
Microsoft 365 admin centre, under Settings > Org settings > Microsoft 365 Groups,
emails the most active members and asks one of them to take over. Turn it on.
Run this first so you know how big the backlog is, and run it again afterwards to
see whether anyone actually accepted.

**Public and ownerless is the combination that matters.** A public group can be
joined by anyone in the tenant and read by anyone in the tenant, and there is
nobody to notice. The summary counts those separately.

**Member counts cost an extra call per group.** `-IncludeMemberCount` uses the
`$count` endpoint, which needs the `ConsistencyLevel: eventual` header. Worth it:
"a group nobody owns" reads differently once you know it has 340 people in it.

**Group expiry only runs where the policy is on.** The `Expires` column is empty
unless you have a Microsoft 365 group expiration policy, which needs Entra ID P1.
Without it, `LastRenewed` is just the creation date and nothing ever expires.

**Dynamic groups still need owners.** The membership takes care of itself, the
Team settings and the site permissions do not. Those show with `DynamicRule` set
to true so you can tell them apart.
