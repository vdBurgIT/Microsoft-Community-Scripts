# 👑 Get-AdminRoleReport

Who holds which admin role, including the people who got there through a group.

## What it does

Reads the activated directory roles and their members, expands role-assignable
groups into the people inside them, and optionally adds PIM-eligible assignments.
One row per assignment, with the account state and whether it came from
on-premises.

Nothing is changed.

## Why it exists

The role blade shows a group as one line. If that group has nine members, your
access review has nine people in it and your document has one. Audit findings are
made of that gap.

The same goes for PIM: an account with no active role can still activate Global
Administrator whenever it likes. Leave eligible assignments out and the report is
comforting rather than accurate.

## How to run

```powershell
./Get-AdminRoleReport.ps1
./Get-AdminRoleReport.ps1 -IncludeEligible -CsvPath ./admin-roles.csv
./Get-AdminRoleReport.ps1 -RoleName 'Global Administrator'
```

Graph scopes: `Directory.Read.All`, plus `RoleManagement.Read.Directory` for
`-IncludeEligible`.

## Where it bites

**Only activated roles appear.** `directoryRoles` returns the roles that exist in
the tenant, which are the ones that have had a member at some point. A built-in
role nobody has ever used is not there. That is correct, but it surprises people
who expect all 100-odd roles in the output.

**PIM needs Entra ID P2.** Without it the eligibility endpoint answers with an
error. The script warns and keeps the active assignments rather than failing the
whole run.

**Scoped assignments are not expanded.** An administrative-unit-scoped role shows
as an assignment without saying which unit it covers. Treat a row as "holds the
role somewhere" and check the scope in the portal for the ones that matter.

**Service principals hold roles too.** They show up with `PrincipalType` set to
`ServicePrincipal` and no UPN. An app with Privileged Role Administrator is worth
more of your attention than a person with it, and it is the row people skip past.

**Two Global Administrators is the floor.** The summary warns below two, because
one means nobody can help when that account is locked out, and it warns above
five, because that is usually three people who needed a narrower role.
