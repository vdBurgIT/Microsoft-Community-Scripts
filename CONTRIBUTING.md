# Contributing

Scripts welcome. Fixes welcome. Caveats you learned the hard way, extremely
welcome.

Nothing here is a gate. If your script works and does something useful, open the
PR and we'll sort out the polish together.

## Where files go

```
scripts/<Area>/<Verb-Noun>/
├── <Verb-Noun>.ps1
└── README.md
```

Area is the product you'd go looking in first: `SharePoint`, `Intune`, `Entra`,
`Exchange`, `Microsoft365`, `Azure`. Make a new one if yours doesn't fit.

Anything the script needs (config sample, CSV template, helper functions) goes
in that same folder. Keeping each script self-contained is the whole point,
because the folder is what people copy out.

## The script

**Use an approved verb.** `Get-Verb` lists them. `Get`, `Export`, `Set`, `New`,
`Remove`, `Invoke` cover most cases.

**Write comment-based help.** `.SYNOPSIS` and at least one `.EXAMPLE`. Put a
comment above each parameter and it becomes the parameter help automatically.

**Return objects, don't print them.** `Write-Host` is for progress and
summaries. The result goes to the pipeline, so this works:

```powershell
./Get-Something.ps1 | Export-Csv out.csv
./Get-Something.ps1 | Where-Object Enabled
```

**No hardcoded tenant names, GUIDs, paths or customer data.** Parameters with
sensible defaults. This one is not negotiable: it's a public repo, and a tenant
ID in a commit is forever.

**Fail with something actionable.** "Run again with -TenantId" beats a stack
trace.

**Anything that changes something supports `-WhatIf`.** Add
`[CmdletBinding(SupportsShouldProcess)]` and wrap each change in
`$PSCmdlet.ShouldProcess(...)`. People will run your script against production
before they read your README.

**Target the right PowerShell.** Scripts deployed through Intune platform
scripts run in Windows PowerShell 5.1, not 7. Say so with `#Requires -Version 5.1`
and skip the 7-only syntax.

**English** for code, comments, help and console output. Scripts end up in
customer tenants and on shared screens.

## The README

Four questions, in whatever order reads best:

1. What does it do?
2. Why does it exist? What's the manual alternative you're avoiding?
3. How do you run it? A few real examples beat a parameter dump.
4. **Where does it bite?**

That last one carries the most weight. The parameter list is already in
`Get-Help -Full`. What nobody can guess is that the Intune automount policy
accepts a malformed value, deploys cleanly, reports success, and syncs nothing.
Write down the thing that cost you an afternoon.

Permissions, licence tiers, throttling behaviour and anything that quietly
returns partial results all belong here too.

## One gotcha worth stealing

Put a blank line between `#Requires` and your comment-based help:

```powershell
#Requires -Version 7.2

<#
.SYNOPSIS
    ...
#>
```

Without it PowerShell ignores the entire help block and `Get-Help` falls back to
bare syntax. No warning, no error, just help that isn't there 🙃

## Before you open the PR

Run your script once more and check `git status`. Output files hold tenant IDs,
site IDs and URLs. `.gitignore` catches the common filenames, but it can't catch
the one you named `export-final-v2.csv`.

Then add a row to the table in [README.md](README.md) so people can find it.

## Reporting something broken

Open an issue with the error text and a rough shape of your tenant. Multi-geo,
GCC High, a Dutch or German locale that renames every SharePoint library,
Business Premium instead of E5: those differences are usually the reason
something works for one person and not another.

If you already know the fix, skip the issue and send the PR 🚀
