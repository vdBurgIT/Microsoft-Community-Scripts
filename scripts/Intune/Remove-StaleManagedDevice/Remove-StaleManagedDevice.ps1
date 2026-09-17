#Requires -Version 7.2

<#
.SYNOPSIS
    Removes Intune device records that have not checked in for months, so the
    device list matches reality again.

.DESCRIPTION
    Every laptop that was reimaged, every phone that was traded in and every test
    VM that got deleted leaves a record behind in Intune. They inflate your device
    count, they show up as non-compliant, and they make the compliance percentage
    on the dashboard meaningless.

    Devices are selected on lastSyncDateTime. Two ways to clear them:

    - Delete removes the Intune record only. Nothing is sent to the device. This
      is what you want for hardware that no longer exists.
    - Retire unenrols the device and pulls company data off it if it ever checks
      in again. This is what you want for a device you are not sure about.

    Supports -WhatIf, and stops at -MaxToRemove so a wrong -DaysInactive cannot
    empty your tenant.

.PARAMETER DaysInactive
    A device counts as stale after this many days without a sync.

.PARAMETER Action
    Delete removes the record in Intune. Retire unenrols the device. Delete is
    the default.

.PARAMETER OperatingSystem
    Limit to one platform, for example Windows, iOS, Android or macOS. Matched
    against the operatingSystem property.

.PARAMETER OwnerType
    Limit to company or personal devices.

.PARAMETER ExcludeDeviceName
    Device names to leave alone. Wildcards are allowed.

.PARAMETER MaxToRemove
    Safety cap on how many devices are touched in one run.

.PARAMETER ReportOnly
    List what matches and change nothing. Same idea as -WhatIf, but it returns
    the full device detail instead of the ShouldProcess lines.

.PARAMETER CsvPath
    Write the result to this CSV. Worth doing: the Intune record is gone
    afterwards, and this is your only copy of the serial numbers.

.EXAMPLE
    # Look first
    ./Remove-StaleManagedDevice.ps1 -ReportOnly

.EXAMPLE
    ./Remove-StaleManagedDevice.ps1 -DaysInactive 180 -WhatIf

.EXAMPLE
    # Windows only, keep a record of what went
    ./Remove-StaleManagedDevice.ps1 -DaysInactive 180 -OperatingSystem Windows -CsvPath ./removed-devices.csv

.EXAMPLE
    # Unenrol instead of deleting the record
    ./Remove-StaleManagedDevice.ps1 -Action Retire -DaysInactive 120

.NOTES
    Graph scopes: DeviceManagementManagedDevices.ReadWrite.All for -Action Delete,
    and DeviceManagementManagedDevices.PrivilegedOperations.All for
    -Action Retire. Intune Administrator on the role side.

    Deleting the Intune record does not remove the device from Entra ID, and it
    does not remove it from Windows Autopilot. Those are three separate objects
    and this script only touches the first one.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    # Days without a check-in before a device counts as stale
    [ValidateRange(1, 3650)]
    [int]$DaysInactive = 90,

    # Delete the Intune record, or retire (unenrol) the device
    [ValidateSet('Delete', 'Retire')]
    [string]$Action = 'Delete',

    # Limit to one platform, e.g. Windows, iOS, Android, macOS
    [string]$OperatingSystem,

    # Limit to company or personal devices
    [ValidateSet('Any', 'Company', 'Personal')]
    [string]$OwnerType = 'Any',

    # Device names to leave alone (wildcards allowed)
    [string[]]$ExcludeDeviceName,

    # Stop after this many devices
    [ValidateRange(1, 100000)]
    [int]$MaxToRemove = 100,

    # List matches and change nothing
    [switch]$ReportOnly,

    # Optional CSV log path
    [string]$CsvPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# =============================================================== helpers ====

function Initialize-GraphSession {
    param([Parameter(Mandatory)][string[]]$Scope)

    if (-not (Get-Module -ListAvailable -Name 'Microsoft.Graph.Authentication')) {
        Write-Host 'Installing module Microsoft.Graph.Authentication (one time)...' -ForegroundColor Yellow
        Install-Module Microsoft.Graph.Authentication -Scope CurrentUser -Force -AllowClobber
    }
    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop

    $context = Get-MgContext
    $missing = if ($context) { @($Scope | Where-Object { @($context.Scopes) -notcontains $_ }) } else { $Scope }

    if ($missing.Count -gt 0) {
        $splat = @{ Scopes = $Scope; ContextScope = 'CurrentUser'; ErrorAction = 'Stop' }
        if ((Get-Command Connect-MgGraph).Parameters.ContainsKey('NoWelcome')) { $splat.NoWelcome = $true }
        Connect-MgGraph @splat
        $context = Get-MgContext
    }

    if (-not $context) { throw 'Sign-in failed: no Graph context.' }

    $stillMissing = @($Scope | Where-Object { @($context.Scopes) -notcontains $_ })
    if ($stillMissing.Count -gt 0) {
        throw "These scopes were not granted: $($stillMissing -join ', '). Sign in as an Intune Administrator and accept the consent prompt."
    }

    return $context
}

function Invoke-GraphCall {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [string]$Method = 'GET',
        $Body,
        [int]$MaxAttempts = 5
    )

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            $splat = @{ Method = $Method; Uri = $Uri; OutputType = 'Hashtable'; ErrorAction = 'Stop' }
            if ($null -ne $Body) {
                $splat.Body = ($Body | ConvertTo-Json -Depth 10 -Compress)
                $splat.ContentType = 'application/json'
            }
            return Invoke-MgGraphRequest @splat
        }
        catch {
            $status = 0
            if ($_.Exception.PSObject.Properties.Name -contains 'Response' -and $_.Exception.Response) {
                $status = [int]$_.Exception.Response.StatusCode
            }
            if ($status -notin @(429, 500, 502, 503, 504) -or $attempt -eq $MaxAttempts) { throw }

            $wait = [math]::Pow(2, $attempt)
            Write-Verbose "Graph returned $status, retrying in $wait s (attempt $attempt/$MaxAttempts)"
            Start-Sleep -Seconds $wait
        }
    }
}

function Invoke-GraphPaged {
    param([Parameter(Mandatory)][string]$Uri, [string]$Activity)

    $items = [System.Collections.Generic.List[object]]::new()
    $next = $Uri

    while ($next) {
        $resp = Invoke-GraphCall -Uri $next
        if ($resp.ContainsKey('value') -and $resp['value']) {
            foreach ($v in $resp['value']) { $items.Add($v) }
        }
        if ($Activity) { Write-Progress -Activity $Activity -Status "$($items.Count) so far" }
        $next = if ($resp.ContainsKey('@odata.nextLink')) { $resp['@odata.nextLink'] } else { $null }
    }

    if ($Activity) { Write-Progress -Activity $Activity -Completed }
    return $items
}

function Get-GraphValue {
    param($Item, [Parameter(Mandatory)][string]$Key, $Default = $null)

    if ($Item -is [hashtable] -and $Item.ContainsKey($Key) -and $null -ne $Item[$Key]) {
        return $Item[$Key]
    }
    return $Default
}

# ================================================================= sign in ==

$scope = if ($Action -eq 'Retire' -and -not $ReportOnly) {
    @('DeviceManagementManagedDevices.PrivilegedOperations.All', 'DeviceManagementManagedDevices.ReadWrite.All')
}
else {
    @('DeviceManagementManagedDevices.ReadWrite.All')
}

$context = Initialize-GraphSession -Scope $scope
Write-Host "Signed in as : $($context.Account)"
Write-Host "Tenant       : $($context.TenantId)"

# ================================================================== fetch ===

$select = 'id,deviceName,managedDeviceName,serialNumber,operatingSystem,osVersion,model,manufacturer,' +
    'userPrincipalName,userDisplayName,lastSyncDateTime,enrolledDateTime,complianceState,' +
    'managedDeviceOwnerType,managementAgent,azureADDeviceId,deviceEnrollmentType'

Write-Host 'Fetching managed devices...' -ForegroundColor Cyan
$devices = Invoke-GraphPaged -Activity 'Fetching devices' -Uri ('https://graph.microsoft.com/v1.0/deviceManagement/managedDevices' +
    "?`$select=$select&`$top=1000")

Write-Host "  $($devices.Count) device record(s)."
if ($devices.Count -eq 0) { return @() }

# ================================================================ select ====

$now = [datetime]::UtcNow
$cutoff = $now.AddDays(-$DaysInactive)
$candidates = [System.Collections.Generic.List[object]]::new()

foreach ($device in $devices) {

    $lastSync = Get-GraphValue -Item $device -Key 'lastSyncDateTime'

    # A record with no sync date at all never completed enrolment. Leave it
    # alone: there is no date to judge it by.
    if ($null -eq $lastSync) { continue }
    if ([datetime]$lastSync -ge $cutoff) { continue }

    $name = [string](Get-GraphValue -Item $device -Key 'deviceName')
    $os = [string](Get-GraphValue -Item $device -Key 'operatingSystem')
    $owner = [string](Get-GraphValue -Item $device -Key 'managedDeviceOwnerType')

    if ($OperatingSystem -and $os -notlike "*$OperatingSystem*") { continue }
    if ($OwnerType -ne 'Any' -and $owner -ne $OwnerType.ToLower()) { continue }

    if ($ExcludeDeviceName) {
        $skip = $false
        foreach ($pattern in $ExcludeDeviceName) {
            if ($name -like $pattern) { $skip = $true; break }
        }
        if ($skip) { continue }
    }

    $candidates.Add([pscustomobject]@{
        Id               = [string](Get-GraphValue -Item $device -Key 'id')
        DeviceName       = $name
        SerialNumber     = [string](Get-GraphValue -Item $device -Key 'serialNumber')
        OperatingSystem  = $os
        OsVersion        = [string](Get-GraphValue -Item $device -Key 'osVersion')
        Model            = [string](Get-GraphValue -Item $device -Key 'model')
        Manufacturer     = [string](Get-GraphValue -Item $device -Key 'manufacturer')
        User             = [string](Get-GraphValue -Item $device -Key 'userPrincipalName')
        OwnerType        = $owner
        ComplianceState  = [string](Get-GraphValue -Item $device -Key 'complianceState')
        LastSync         = $lastSync
        DaysSinceSync    = [int]($now - [datetime]$lastSync).TotalDays
        Enrolled         = Get-GraphValue -Item $device -Key 'enrolledDateTime'
        AzureAdDeviceId  = [string](Get-GraphValue -Item $device -Key 'azureADDeviceId')
        Action           = 'Pending'
    })
}

$sorted = @($candidates | Sort-Object DaysSinceSync -Descending)

Write-Host ''
Write-Host "Cutoff       : $DaysInactive day(s), so no sync since $($cutoff.ToString('yyyy-MM-dd'))"
Write-Host "Stale        : $($sorted.Count) of $($devices.Count)" -ForegroundColor Yellow

if ($ReportOnly) {
    foreach ($row in $sorted) { $row.Action = 'ReportOnly' }
    if ($CsvPath) {
        $sorted | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $CsvPath
        Write-Host "CSV          : $CsvPath" -ForegroundColor Green
    }
    return $sorted
}

if ($sorted.Count -eq 0) { return $sorted }

$targets = $sorted
if ($sorted.Count -gt $MaxToRemove) {
    Write-Warning "$($sorted.Count) devices match but -MaxToRemove is $MaxToRemove. Only the $MaxToRemove longest-quiet are processed."
    $targets = @($sorted | Select-Object -First $MaxToRemove)
}

# ================================================================== apply ===

$done = 0

foreach ($target in $targets) {
    $label = "$($target.DeviceName) [$($target.SerialNumber)], last sync $($target.DaysSinceSync) day(s) ago"

    if ($PSCmdlet.ShouldProcess($label, "$Action Intune record")) {
        try {
            if ($Action -eq 'Retire') {
                Invoke-GraphCall -Method POST -Uri "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/$($target.Id)/retire" | Out-Null
            }
            else {
                Invoke-GraphCall -Method DELETE -Uri "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/$($target.Id)" | Out-Null
            }
            $target.Action = "$($Action)d"
        }
        catch {
            $target.Action = "Failed: $($_.Exception.Message)"
            Write-Warning "$($target.DeviceName): $($_.Exception.Message)"
        }
    }
    else {
        $target.Action = 'Skipped'
    }

    $done++
    Write-Progress -Activity "$Action stale devices" -Status "$done / $($targets.Count)" `
        -PercentComplete ([int](100 * $done / $targets.Count))
}

Write-Progress -Activity "$Action stale devices" -Completed

# ================================================================ summary ===

$ok = @($targets | Where-Object Action -eq "$($Action)d").Count
$failed = @($targets | Where-Object { $_.Action -like 'Failed*' }).Count

Write-Host ''
Write-Host "$Action complete. Done: $ok. Failed: $failed."

if ($CsvPath) {
    $sorted | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $CsvPath
    Write-Host "CSV          : $CsvPath" -ForegroundColor Green
}

if ($ok -gt 0) {
    Write-Host ''
    Write-Host 'The matching objects in Entra ID and Windows Autopilot are still there. Clean those up separately if the hardware is really gone.' -ForegroundColor Cyan
}

return $sorted
