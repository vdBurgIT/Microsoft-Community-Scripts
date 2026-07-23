# 🖥️ Set-ScreensaverLogout

Starts the screensaver after a period of inactivity and signs the user out when
it does. For shared desktops, RD hosts and VDI.

## What it does

Three parts:

1. **Registry per profile.** Loads each user's `NTUSER.DAT` hive and sets
   `ScreenSaveActive`, `ScreenSaveTimeOut` and `ScreenSaverIsSecure`. The default
   profile is included, so new users inherit the setting.
2. **A logoff helper.** A one-line script in `C:\ProgramData\LogoutOnScreensaver`
   that calls `shutdown.exe /l /f`.
3. **A scheduled task.** Triggers on Security event 4802 (screensaver invoked)
   and runs the helper as the interactive user.

## Why not just lock the screen

On a shared workstation a locked session is not enough. Ten locked sessions
later, the machine is out of memory, licences are held by people who went home,
and the next shift cannot sign in. Signing out actually frees the seat.

## How to run

```powershell
.\Set-ScreensaverLogout.ps1
.\Set-ScreensaverLogout.ps1 -TimeoutSeconds 900 -WhatIf
```

In Intune: **Devices → Scripts and remediations → Platform scripts**, device
context, 64-bit. It must run as SYSTEM to write into other users' hives.

## Where it bites

**Event 4802 has to be audited or nothing happens.** The task trigger listens for
it, and by default "Audit Other Logon/Logoff Events" is off. No audit, no event,
no logoff, and the script looks like it did nothing. Turn it on through a
configuration profile:

```
Audit Other Logon/Logoff Events → Success
```

**Signed-in users are skipped.** Their hive is already mounted, so `reg.exe load`
fails. The script warns per profile and moves on. Run it before users sign in, or
accept that active sessions pick it up on the next run.

**`shutdown /l /f` is forceful.** Unsaved work goes with it. That is the intent
on a kiosk or shift-work machine, and a bad surprise on a personal laptop. This
is not a script for regular endpoints.

**Registry values are strings, not integers.** `ScreenSaveTimeOut` set as a DWORD
is silently ignored by Windows. The script writes it as `String`. If you adapt
this, keep that.

**Hive unloads need the handles released.** There is a `[GC]::Collect()` before
`reg.exe unload` for exactly that reason. Remove it and you get orphaned
`TempHive_*` keys under `HKU`.
