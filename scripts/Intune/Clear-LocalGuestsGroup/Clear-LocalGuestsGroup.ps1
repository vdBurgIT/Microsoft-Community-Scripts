#Requires -Version 5.1

<#
.SYNOPSIS
    Empties the local Guests group on a Windows device.

.DESCRIPTION
    The built-in Guests group is usually empty and the Guest account is usually
    disabled. "Usually" is doing a lot of work in that sentence. Imaged machines,
    old migrations and helpful third-party installers all have a habit of leaving
    something in there.

    This removes every member and leaves the group itself alone. The built-in
    Guest account is not deleted, only unlinked from the group.

    Deploy through Intune as a device-scoped platform script, or run it as a
    remediation.

.PARAMETER GroupName
    Name of the group to empty. Defaults to Guests. On a non-English Windows
    install the display name differs, so pass the local name or the SID.

.EXAMPLE
    .\Clear-LocalGuestsGroup.ps1

.EXAMPLE
    # See what would go without removing anything
    .\Clear-LocalGuestsGroup.ps1 -WhatIf

.EXAMPLE
    # Dutch Windows
    .\Clear-LocalGuestsGroup.ps1 -GroupName 'Gasten'
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$GroupName = 'Guests'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

try {
    $group = Get-LocalGroup -Name $GroupName -ErrorAction Stop
}
catch {
    throw "Local group '$GroupName' was not found. On a localised Windows install the name differs; pass -GroupName with the local name, or use the SID S-1-5-32-546."
}

$members = @(Get-LocalGroupMember -Group $group -ErrorAction SilentlyContinue)

if ($members.Count -eq 0) {
    Write-Host "Group '$GroupName' is already empty."
    return @()
}

$removed = [System.Collections.Generic.List[object]]::new()

foreach ($member in $members) {
    if ($PSCmdlet.ShouldProcess($member.Name, "Remove from local group '$GroupName'")) {
        try {
            Remove-LocalGroupMember -Group $group -Member $member.Name -ErrorAction Stop
            $removed.Add([pscustomobject]@{ Member = $member.Name; Result = 'Removed'; Error = $null })
        }
        catch {
            # One stubborn member should not stop the rest.
            $removed.Add([pscustomobject]@{ Member = $member.Name; Result = 'Failed'; Error = $_.Exception.Message })
            Write-Warning "Could not remove $($member.Name): $($_.Exception.Message)"
        }
    }
}

$ok = @($removed | Where-Object Result -eq 'Removed').Count
Write-Host "Removed $ok of $($members.Count) member(s) from '$GroupName'."

return $removed
