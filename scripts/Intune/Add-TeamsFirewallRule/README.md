# 🔥 Add-TeamsFirewallRule

Creates the inbound firewall rules Teams needs, before a user gets asked a
question they cannot answer.

## What it does

The first time Teams wants to listen for incoming call media, Windows Firewall
pops the "allow this app" dialog. A standard user has no rights to approve it,
so it gets dismissed. From then on calls quietly degrade: no incoming video, or
audio that routes the long way round through a relay.

This creates the rules as SYSTEM, up front:

- TCP and UDP on ports 3478 to 3481, scoped to the Teams executable
- One program-level rule for Teams itself

Rules that already exist are left alone, so re-running it is free.

## How to run

```powershell
.\Add-TeamsFirewallRule.ps1
.\Add-TeamsFirewallRule.ps1 -WhatIf
```

In Intune: **Devices → Scripts and remediations → Platform scripts**, run in
64-bit PowerShell, not in the user context.

## Where it bites

**The default path is classic Teams.** `C:\Program Files (x86)\Microsoft\Teams\
current\Teams.exe` does not exist on a device that only has new Teams. New Teams
lives under `WindowsApps` with a version number in the path, so resolve it first:

```powershell
$p = (Get-AppxPackage MSTeams).InstallLocation + '\ms-teams.exe'
.\Add-TeamsFirewallRule.ps1 -ProgramPath $p
```

The script warns when the path does not exist but still creates the rules. A
rule pointing at a missing executable is inert, not harmful.

**New Teams updates change the path.** Because the package folder carries the
version, rules can go stale after an update. If you are fully on new Teams,
consider a program-less rule scoped to the ports only, or re-run this on a
schedule.

**Ports alone are not enough.** The program rule matters. Media negotiation does
not always land in the 3478-3481 range, especially with a firewall or SD-WAN in
between doing its own thing.
