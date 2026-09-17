# 🎯 Get-PolicyAssignmentReport

Every Intune policy, script and app with the groups it targets, in one table.

## What it does

Walks configuration profiles, settings catalog policies, compliance policies,
platform scripts, remediations and optionally apps, then returns one row per
assignment with the group name, whether it is an include or an exclude, and the
install intent for apps.

Policies with no assignment get a row too, marked `None`.

Nothing is changed.

## Why it exists

Two questions the portal cannot answer:

- Which policies hit this group? You find out by opening every profile and
  reading the Assignments tab.
- Which policies were never deployed? Somebody built them during a project, the
  project ended, and they have been sitting there ever since.

Both are one `Where-Object` away once the data is in a table.

## How to run

```powershell
./Get-PolicyAssignmentReport.ps1
./Get-PolicyAssignmentReport.ps1 -IncludeApps -CsvPath ./intune-assignments.csv
./Get-PolicyAssignmentReport.ps1 -IncludeApps -GroupName '*Pilot*'
./Get-PolicyAssignmentReport.ps1 -PolicyType Compliance | Where-Object AssignmentMode -eq 'None'
```

Graph scopes: `DeviceManagementConfiguration.Read.All`, `Group.Read.All`, and
`DeviceManagementApps.Read.All` with `-IncludeApps`.

## Where it bites

**This runs against the Graph beta endpoint.** Settings catalog policies,
platform scripts and remediations have no v1.0 equivalent, so there is no choice.
Microsoft changes beta without notice. If a policy type suddenly comes back
empty, that is the first thing to check.

**Settings catalog policies use `name`, not `displayName`.** Every other policy
type uses `displayName`. Read the wrong one and you get a report full of blanks,
which is a mistake people make once.

**A deleted group leaves its assignment behind.** The assignment keeps the group
ID, and the group is gone. Those rows show `(group not found)` instead of a bare
GUID nobody can look up.

**An exclude beats an include.** A user in both an included and an excluded group
does not get the policy. The report shows both rows and leaves the conclusion to
you, because working out the effective result also needs the group memberships.

**Filters are not shown.** Assignment filters sit next to the target and narrow
it further. A row here says the policy targets the group, not that every device
in it receives the policy.

**Apps make the run noticeably longer.** A tenant with a large app catalogue
means one assignment call per app, batched twenty at a time. `-IncludeApps` is
off by default for that reason.
