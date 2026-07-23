# Microsoft Community Scripts

**Community scripts for Microsoft admins. The PowerShell for jobs the portal
makes you click through forty-seven times.**

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%20%7C%207%2B-5391FE.svg?logo=powershell&logoColor=white)](https://learn.microsoft.com/powershell/scripting/install/installing-powershell)
[![PRs welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](CONTRIBUTING.md)

Every M365 admin has a folder called `scripts`. Half-finished PowerShell, a
hardcoded tenant name from a customer you offboarded in 2022, no help text, and
one comment that just says `# TODO fix properly`. Mine looked exactly like that.

This is that folder, cleaned up and opened, so it stops being mine and starts
being ours 🤝

## What's in here

| Script | Area | Saves you from |
| --- | --- | --- |
| [Get-SpoLibraryIds](scripts/SharePoint/Get-SpoLibraryIds/) | SharePoint | Clicking "Copy library ID" on every site before you can fill in the OneDrive automount policy |
| [Disable-SelfServicePurchase](scripts/Microsoft365/Disable-SelfServicePurchase/) | Microsoft 365 | Users buying their own licences on a personal credit card |
| [Enable-SentItemsCopy](scripts/Exchange/Enable-SentItemsCopy/) | Exchange | Three people answering the same shared-mailbox thread |
| [Register-AutopilotDevice](scripts/Intune/Register-AutopilotDevice/) | Intune | Collecting hardware hashes by hand for devices your RMM already manages |
| [Export-AutopilotHash](scripts/Intune/Export-AutopilotHash/) | Intune | The USB stick, the CSV, and the technician holding both |
| [Remove-InboxApp](scripts/Intune/Remove-InboxApp/) | Intune | Candy Crush on a company laptop, twice, because the provisioned package came back |
| [Add-TeamsFirewallRule](scripts/Intune/Add-TeamsFirewallRule/) | Intune | Teams calls dropping to audio-only because a user dismissed a firewall prompt |
| [Set-ScreensaverLogout](scripts/Intune/Set-ScreensaverLogout/) | Intune | Ten locked sessions on a shared desktop and no memory left |
| [Clear-LocalGuestsGroup](scripts/Intune/Clear-LocalGuestsGroup/) | Intune | An audit finding about a group that was supposed to be empty |

## Grab and go

No module to install, nothing to import, no dependency tree. Take the folder you
need and run it:

```powershell
git clone https://github.com/vdBurgIT/Microsoft-Community-Scripts.git
cd Microsoft-Community-Scripts/scripts/SharePoint/Get-SpoLibraryIds
./Get-SpoLibraryIds.ps1
```

Every folder has a README with the caveats spelled out, and every script answers
`Get-Help ./Script.ps1 -Full`. Anything that changes something supports
`-WhatIf`.

## Help make this the good one

There are plenty of script repos out there. Most are a dump of `.ps1` files with
a one-line README and no clue whether anything still works against the current
Graph API. Aiming higher here.

**Found a script that breaks in your tenant?** Open an issue with the error and
roughly what your tenant looks like. Multi-geo, GCC High, a Dutch or German
locale that renames every built-in group: those are exactly the cases that get
missed.

**Got a script sitting in your own folder?** Send it. It does not have to be
polished. A working script with a rough README beats a perfect script nobody
wrote.

**Spotted a caveat we did not document?** That is the most valuable PR in the
repo. Anyone can list parameters. Knowing that the Intune automount policy
accepts a malformed value and then syncs nothing is the part that saves someone
a Thursday.

**Just here to fork it?** Also fine. MIT, take what you need 🎁

Start with [CONTRIBUTING.md](CONTRIBUTING.md). It is short, and mostly about
where files go.

## The shape of things

```
scripts/
└── <Area>/               SharePoint, Intune, Entra, Exchange, Microsoft365, Azure, ...
    └── <ScriptName>/     one folder per script or package
        ├── <ScriptName>.ps1
        └── README.md
```

One folder per script, and that folder is the unit you hand to a colleague. If a
script needs a config file, a sample CSV or three helper functions, they live
right there next to it. No shared `lib/` turning every script into a dependency
puzzle.

## Related

The Microsoft 365 and Intune blueprint these scripts tend to serve lives at
[goldenmaster.cloud](https://goldenmaster.cloud).

## License

[MIT](LICENSE). Use it, change it, ship it in your own toolkit. No attribution
dance required.
