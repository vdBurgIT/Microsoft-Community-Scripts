#Requires -Version 5.1

<#
.SYNOPSIS
    Turns on the screensaver after a period of inactivity and signs the user out
    when it kicks in. Built for shared and multi-session desktops.

.DESCRIPTION
    On a shared workstation, a locked session is not enough. The next person
    finds ten locked sessions, a machine out of memory, and licences held by
    people who went home hours ago.

    This does three things:

    1. Sets the screensaver timeout in every existing user profile, by loading
       each NTUSER.DAT hive in turn, plus the default profile so new users
       inherit it.
    2. Drops a small helper script that calls a logoff.
    3. Registers a scheduled task that fires the helper on Security event 4802
       (the screensaver was invoked), running as the interactive user.

    Deploy through Intune as a device-scoped platform script. It has to run as
    SYSTEM to write into other people's hives.

.PARAMETER TimeoutSeconds
    Idle time before the screensaver starts. Defaults to 300 (five minutes).

.PARAMETER TaskName
    Name of the scheduled task. An existing task with this name is replaced.

.PARAMETER HelperDirectory
    Where the logoff helper script is written.

.EXAMPLE
    .\Set-ScreensaverLogout.ps1

.EXAMPLE
    .\Set-ScreensaverLogout.ps1 -TimeoutSeconds 900 -WhatIf

.NOTES
    Event 4802 only shows up if "Audit Other Logon/Logoff Events" is enabled for
    success. Without it the task never fires and nothing happens. See the README.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateRange(60, 86400)]
    [int]$TimeoutSeconds = 300,

    [string]$TaskName = 'LogoutOnScreensaver',

    [string]$HelperDirectory = 'C:\ProgramData\LogoutOnScreensaver'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ------------------------------------------------- 1. per-profile registry ---

$profileRoots = @(Get-ChildItem 'C:\Users' -Directory |
    Where-Object Name -notin 'Public', 'Default User', 'All Users')

# Include the default profile so users who have never signed in get it too.
$defaultProfile = Get-Item 'C:\Users\Default' -ErrorAction SilentlyContinue
if ($defaultProfile -and $profileRoots.Name -notcontains 'Default') {
    $profileRoots += $defaultProfile
}

$touched = [System.Collections.Generic.List[string]]::new()

foreach ($profileRoot in $profileRoots) {
    $hiveFile = Join-Path $profileRoot.FullName 'NTUSER.DAT'
    if (-not (Test-Path -LiteralPath $hiveFile)) { continue }

    if (-not $PSCmdlet.ShouldProcess($profileRoot.Name, 'Set screensaver timeout')) { continue }

    $hiveName = "TempHive_$($profileRoot.Name)"
    $loaded = $false

    try {
        & reg.exe load "HKU\$hiveName" $hiveFile 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            # Usually means the user is signed in and the hive is already mounted.
            Write-Warning "Skipped $($profileRoot.Name): profile hive is in use."
            continue
        }
        $loaded = $true

        $desktopKey = "Registry::HKU\$hiveName\Control Panel\Desktop"
        Set-ItemProperty -Path $desktopKey -Name 'ScreenSaveActive' -Value '1' -Type String
        Set-ItemProperty -Path $desktopKey -Name 'ScreenSaveTimeOut' -Value "$TimeoutSeconds" -Type String
        Set-ItemProperty -Path $desktopKey -Name 'ScreenSaverIsSecure' -Value '1' -Type String

        $touched.Add($profileRoot.Name)
    }
    finally {
        if ($loaded) {
            [GC]::Collect()   # release handles, otherwise the unload fails
            & reg.exe unload "HKU\$hiveName" 2>&1 | Out-Null
        }
    }
}

Write-Host "Screensaver timeout set for $($touched.Count) profile(s): $($touched -join ', ')"

# --------------------------------------------------------- 2. logoff helper ---

$helperPath = Join-Path $HelperDirectory 'LogoutScript.ps1'

if ($PSCmdlet.ShouldProcess($helperPath, 'Write logoff helper')) {
    if (-not (Test-Path -LiteralPath $HelperDirectory)) {
        New-Item -Path $HelperDirectory -ItemType Directory -Force | Out-Null
    }

    @'
# Started by the LogoutOnScreensaver scheduled task on Security event 4802.
shutdown.exe /l /f
'@ | Set-Content -LiteralPath $helperPath -Encoding UTF8

    Write-Host "Logoff helper written to $helperPath"
}

# -------------------------------------------------------- 3. scheduled task ---

if ($PSCmdlet.ShouldProcess($TaskName, 'Register scheduled task')) {

    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host "Replaced existing task '$TaskName'."
    }

    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$helperPath`""

    $trigger = New-ScheduledTaskTrigger -OnEvent -LogName Security -EventId 4802

    $principal = New-ScheduledTaskPrincipal -GroupId 'NT AUTHORITY\INTERACTIVE' -RunLevel Limited

    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal | Out-Null

    Write-Host "Scheduled task '$TaskName' registered."
}

return [pscustomobject]@{
    TimeoutSeconds  = $TimeoutSeconds
    ProfilesTouched = $touched
    HelperPath      = $helperPath
    TaskName        = $TaskName
}
