# 🧹 Clear-LocalGuestsGroup

Empties the local Guests group. Small script, boring job, occasionally saves an
audit finding.

## What it does

Removes every member from the local Guests group and leaves the group itself in
place. The built-in Guest account is not deleted, only unlinked.

## Why it exists

The Guests group is supposed to be empty. On a freshly installed machine it is.
On a machine that came from an image built in 2019, was migrated twice, and had
a badly behaved line-of-business installer run against it, it sometimes is not.

Anything in that group inherits guest-level access to the device. It costs
nothing to check, so check.

## How to run

```powershell
.\Clear-LocalGuestsGroup.ps1
.\Clear-LocalGuestsGroup.ps1 -WhatIf
```

Good fit for an Intune remediation: detect membership, remediate with this.

## Where it bites

**The group name is localised.** On Dutch Windows it is `Gasten`, on German
`Gäste`. The script fails with a clear message rather than silently doing
nothing, but you still need to pass the right name:

```powershell
.\Clear-LocalGuestsGroup.ps1 -GroupName 'Gasten'
```

A locale-proof alternative is to look the group up by its well-known SID
`S-1-5-32-546` and pass the resolved name.

**One failing member does not stop the run.** Domain accounts and orphaned SIDs
can refuse removal. Those get a warning and land in the returned objects with
`Result = 'Failed'`, and the script carries on with the rest.

**Needs elevation.** Running it as a standard user gets you an access denied on
the first removal.
