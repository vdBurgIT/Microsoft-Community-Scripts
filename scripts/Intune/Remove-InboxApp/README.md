# 📦 Remove-InboxApp

Strips consumer apps and OEM bloatware off a Windows device, for the current
user and for everyone who signs in after them.

## What it does

Two passes, and the second one is the point:

1. **Installed packages** get removed with `-AllUsers`, clearing them for
   everyone who already has a profile.
2. **Provisioned packages** get removed from the image, so the next user to sign
   in does not get a fresh Candy Crush.

Skipping step two is the classic mistake. The apps come back for user number
two, and you get to explain why the "debloat" script did not debloat.

## How to run

```powershell
.\Remove-InboxApp.ps1
.\Remove-InboxApp.ps1 -WhatIf
```

Add your own OEM junk without restating the whole list:

```powershell
.\Remove-InboxApp.ps1 -AdditionalApp 'Dell.Optimizer', 'RealtekSemiconductorCorp.RealtekAudioControl'
```

In Intune: **Devices → Scripts and remediations → Platform scripts**, device
context, 64-bit.

## Where it bites

**`Microsoft.DesktopAppInstaller` is deliberately not in the list.** That package
is winget. Plenty of debloat scripts on the internet remove it and then wonder
why app deployment stopped working. If you copy this list somewhere else, leave
that one out too.

**Some packages refuse to go.** System-critical packages are protected and throw
on removal. That is expected noise. Failures land in the output with
`Result = 'Failed'` instead of stopping the run.

**Removing apps in the default list may not be what you want.** `*onenote*` also
catches the OneNote store app, which some organisations still use.
`Microsoft.MicrosoftStickyNotes` has genuine fans. Read the list before you
deploy it fleet-wide, and trim with `-AppName`.

**Timing matters during Autopilot.** Run it too early in ESP and provisioned
packages can reinstall behind you. Run it as a platform script after enrolment,
or accept that you may need a second pass.

**This does not stop Windows reinstalling suggestions.** Consumer experience
apps come back through Content Delivery Manager unless you also disable it
through policy. That is a configuration profile job, not a script job.
