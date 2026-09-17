#Requires -Version 7.2

<#
.SYNOPSIS
    Exports who has which licence, whether it came from a group or a direct
    assignment, and how many of each SKU are sitting unused.

.DESCRIPTION
    Two views of the same data:

    - Per SKU: how many you bought, how many are assigned, how many are free.
      Printed every run, and returned on its own with -Summary.
    - Per user and SKU: one row per licence, with the group it came from when it
      is group-based, and the error state when the assignment failed.

    Group-based assignment is where the surprises live. A user can hold the same
    SKU twice, once direct and once through a group, and removing the group does
    not free the licence. Both rows show up here.

    Licences on blocked accounts get their own count in the summary. That is
    usually the cheapest money you will find all week.

    Nothing is changed.

.PARAMETER Summary
    Return the per-SKU summary instead of the per-user rows.

.PARAMETER SkuPartNumber
    Limit to one or more SKUs, for example SPE_E3 or ENTERPRISEPACK. Wildcards
    are allowed.

.PARAMETER DisabledUsersOnly
    Only return licences held by accounts that cannot sign in.

.PARAMETER ErrorsOnly
    Only return assignments in an error state. These are almost always a missing
    usage location or a service plan conflict.

.PARAMETER IncludeUnlicensedUsers
    Also return a row for every account with no licence at all.

.PARAMETER CsvPath
    Also write the result to this CSV.

.EXAMPLE
    ./Get-LicenseAssignmentReport.ps1

.EXAMPLE
    # What did we buy and what is actually in use
    ./Get-LicenseAssignmentReport.ps1 -Summary

.EXAMPLE
    # Licences on accounts that cannot sign in
    ./Get-LicenseAssignmentReport.ps1 -DisabledUsersOnly -CsvPath ./licences-on-blocked-accounts.csv

.EXAMPLE
    # Assignments that failed
    ./Get-LicenseAssignmentReport.ps1 -ErrorsOnly

.NOTES
    Graph scopes: Organization.Read.All, User.Read.All, and Group.Read.All to
    turn group IDs into group names. Global Reader is enough.

    SKU part numbers are not product names. ENTERPRISEPACK is Microsoft 365 E3
    and SPE_E5 is Microsoft 365 E5. Microsoft publishes the full mapping as
    "Product names and service plan identifiers for licensing" on Microsoft
    Learn, and it changes often enough that hardcoding it here would age badly.
#>

[CmdletBinding()]
param(
    # Return the per-SKU summary instead of the per-user rows
    [switch]$Summary,

    # Limit to these SKU part numbers (wildcards allowed)
    [string[]]$SkuPartNumber,

    # Only licences held by blocked accounts
    [switch]$DisabledUsersOnly,

    # Only assignments in an error state
    [switch]$ErrorsOnly,

    # Also return accounts with no licence
    [switch]$IncludeUnlicensedUsers,

    # Optional CSV export path
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
        throw "These scopes were not granted: $($stillMissing -join ', '). Sign in with an account that can consent, or ask an admin to consent for 'Microsoft Graph Command Line Tools'."
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

function Test-NameMatch {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value, [string[]]$Pattern)

    if (-not $Pattern) { return $true }
    foreach ($p in $Pattern) {
        if ($Value -like $p) { return $true }
    }
    return $false
}

# ================================================================= sign in ==

$context = Initialize-GraphSession -Scope @('Organization.Read.All', 'User.Read.All', 'Group.Read.All')
Write-Host "Signed in as : $($context.Account)"
Write-Host "Tenant       : $($context.TenantId)"

# =================================================================== SKUs ===

Write-Host 'Fetching subscribed SKUs...' -ForegroundColor Cyan
$skus = Invoke-GraphPaged -Uri 'https://graph.microsoft.com/v1.0/subscribedSkus'

$skuById = @{}
foreach ($sku in $skus) {
    $id = [string](Get-GraphValue -Item $sku -Key 'skuId')
    if ($id) { $skuById[$id] = [string](Get-GraphValue -Item $sku -Key 'skuPartNumber') }
}

Write-Host "  $($skus.Count) SKU(s)."

# ================================================================== users ===

$select = 'id,displayName,userPrincipalName,accountEnabled,userType,department,jobTitle,' +
    'usageLocation,onPremisesSyncEnabled,assignedLicenses,licenseAssignmentStates'

Write-Host 'Fetching users...' -ForegroundColor Cyan
$users = Invoke-GraphPaged -Activity 'Fetching users' -Uri ('https://graph.microsoft.com/v1.0/users' +
    "?`$select=$select&`$top=999")

Write-Host "  $($users.Count) account(s)."
if ($users.Count -eq 0) { throw 'Graph returned no users.' }

# ============================================================= group names ==

$groupIds = [System.Collections.Generic.HashSet[string]]::new()

foreach ($user in $users) {
    foreach ($state in @(Get-GraphValue -Item $user -Key 'licenseAssignmentStates' -Default @())) {
        $byGroup = [string](Get-GraphValue -Item $state -Key 'assignedByGroup')
        if ($byGroup) { $null = $groupIds.Add($byGroup) }
    }
}

$groupNames = @{}

if ($groupIds.Count -gt 0) {
    Write-Host "Resolving $($groupIds.Count) licensing group(s)..." -ForegroundColor Cyan
    foreach ($id in $groupIds) {
        try {
            $group = Invoke-GraphCall -Uri "https://graph.microsoft.com/v1.0/groups/$id`?`$select=displayName"
            $groupNames[$id] = [string](Get-GraphValue -Item $group -Key 'displayName')
        }
        catch {
            # A group that was deleted while it still had licences assigned.
            $groupNames[$id] = '(group not found)'
        }
    }
}

# ================================================================== build ===

$rows = [System.Collections.Generic.List[object]]::new()
$disabledAccountCount = @{}

foreach ($user in $users) {

    $upn = [string](Get-GraphValue -Item $user -Key 'userPrincipalName')
    $enabled = [bool](Get-GraphValue -Item $user -Key 'accountEnabled' -Default $false)
    $states = @(Get-GraphValue -Item $user -Key 'licenseAssignmentStates' -Default @())

    if ($states.Count -eq 0) {
        if (-not $IncludeUnlicensedUsers -or $Summary) { continue }
        if ($DisabledUsersOnly -and $enabled) { continue }
        if ($ErrorsOnly) { continue }

        $rows.Add([pscustomobject]@{
            UserPrincipalName = $upn
            DisplayName       = [string](Get-GraphValue -Item $user -Key 'displayName')
            Enabled           = $enabled
            SkuPartNumber     = '(none)'
            AssignedVia       = ''
            State             = 'Unlicensed'
            AssignmentError   = ''
            UsageLocation     = [string](Get-GraphValue -Item $user -Key 'usageLocation')
            Department        = [string](Get-GraphValue -Item $user -Key 'department')
            UserType          = [string](Get-GraphValue -Item $user -Key 'userType' -Default 'Member')
            SkuId             = ''
        })
        continue
    }

    foreach ($state in $states) {
        $skuId = [string](Get-GraphValue -Item $state -Key 'skuId')
        $part = if ($skuById.ContainsKey($skuId)) { $skuById[$skuId] } else { $skuId }

        # Count before filtering: the summary should describe the tenant, not
        # whatever subset the switches left behind.
        if (-not $disabledAccountCount.ContainsKey($skuId)) { $disabledAccountCount[$skuId] = 0 }
        if (-not $enabled) { $disabledAccountCount[$skuId]++ }

        if (-not (Test-NameMatch -Value $part -Pattern $SkuPartNumber)) { continue }
        if ($DisabledUsersOnly -and $enabled) { continue }

        $assignmentError = [string](Get-GraphValue -Item $state -Key 'error' -Default 'None')
        if ($ErrorsOnly -and $assignmentError -in @('None', '')) { continue }

        $byGroup = [string](Get-GraphValue -Item $state -Key 'assignedByGroup')
        $via = if ($byGroup) {
            'Group: ' + $(if ($groupNames.ContainsKey($byGroup)) { $groupNames[$byGroup] } else { $byGroup })
        }
        else { 'Direct' }

        $rows.Add([pscustomobject]@{
            UserPrincipalName = $upn
            DisplayName       = [string](Get-GraphValue -Item $user -Key 'displayName')
            Enabled           = $enabled
            SkuPartNumber     = $part
            AssignedVia       = $via
            State             = [string](Get-GraphValue -Item $state -Key 'state')
            AssignmentError   = $assignmentError
            UsageLocation     = [string](Get-GraphValue -Item $user -Key 'usageLocation')
            Department        = [string](Get-GraphValue -Item $user -Key 'department')
            UserType          = [string](Get-GraphValue -Item $user -Key 'userType' -Default 'Member')
            SkuId             = $skuId
        })
    }
}

# ================================================================= summary ==

$summaryRows = [System.Collections.Generic.List[object]]::new()

foreach ($sku in $skus) {
    $skuId = [string](Get-GraphValue -Item $sku -Key 'skuId')
    $part = [string](Get-GraphValue -Item $sku -Key 'skuPartNumber')

    if (-not (Test-NameMatch -Value $part -Pattern $SkuPartNumber)) { continue }

    $prepaid = Get-GraphValue -Item $sku -Key 'prepaidUnits'
    $total = [int](Get-GraphValue -Item $prepaid -Key 'enabled' -Default 0)
    $warning = [int](Get-GraphValue -Item $prepaid -Key 'warning' -Default 0)
    $consumed = [int](Get-GraphValue -Item $sku -Key 'consumedUnits' -Default 0)
    $onDisabled = if ($disabledAccountCount.ContainsKey($skuId)) { $disabledAccountCount[$skuId] } else { 0 }

    $summaryRows.Add([pscustomobject]@{
        SkuPartNumber    = $part
        Total            = $total
        Assigned         = $consumed
        Available        = $total - $consumed
        OnBlockedAccount = $onDisabled
        InWarningState   = $warning
        CapabilityStatus = [string](Get-GraphValue -Item $sku -Key 'capabilityStatus')
        SkuId            = $skuId
    })
}

$summarySorted = @($summaryRows | Sort-Object SkuPartNumber)

Write-Host ''
Write-Host 'Licences per SKU:'
$summarySorted | Format-Table SkuPartNumber, Total, Assigned, Available, OnBlockedAccount -AutoSize |
    Out-String -Width 200 | Write-Host

$wasted = ($summarySorted | Measure-Object -Property OnBlockedAccount -Sum).Sum
$free = ($summarySorted | Measure-Object -Property Available -Sum).Sum

Write-Host "Unassigned licences      : $free"
Write-Host "On blocked accounts      : $wasted" -ForegroundColor $(if ($wasted -gt 0) { 'Yellow' } else { 'Green' })

$errored = @($rows | Where-Object { $_.AssignmentError -notin @('None', '', 'Unlicensed') })
if ($errored.Count -gt 0) {
    Write-Warning "$($errored.Count) assignment(s) are in an error state. A missing usage location is the usual cause."
}

# ================================================================== output ==

$result = if ($Summary) { $summarySorted } else { @($rows | Sort-Object UserPrincipalName, SkuPartNumber) }

if ($CsvPath) {
    $result | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $CsvPath
    Write-Host "CSV                      : $CsvPath" -ForegroundColor Green
}

# A subscription in warning state is past its expiry and inside the grace
# period. It still works, which is exactly why nobody notices.
$expiring = @($summarySorted | Where-Object InWarningState -gt 0)
if ($expiring.Count -gt 0) {
    Write-Host ''
    Write-Warning "$($expiring.Count) SKU(s) have units in a warning state, which means the subscription lapsed and is in its grace period: $($expiring.SkuPartNumber -join ', ')"
}

return $result
