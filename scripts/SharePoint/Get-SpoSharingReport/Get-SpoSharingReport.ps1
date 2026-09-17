#Requires -Version 7.2

<#
.SYNOPSIS
    Reports the external sharing setting of every SharePoint site and flags the
    ones that are more open than your baseline.

.DESCRIPTION
    The tenant-level sharing setting is the ceiling, not the rule. Each site
    carries its own SharingCapability, and a site created from a template, moved
    from another tenant or opened up for one project keeps whatever it was given.

    This reads every site, compares it against the baseline you name, and returns
    the sites that sit above it. The tenant setting is printed first so the
    numbers have context.

    Nothing is changed. Set-PnPTenantSite is the cmdlet for that, one site at a
    time, after you have read this list.

.PARAMETER TenantAdminUrl
    Your SharePoint admin centre URL, for example https://contoso-admin.sharepoint.com.

.PARAMETER ClientId
    Application (client) ID of the Entra app registration PnP.PowerShell signs in
    with. Falls back to the ENTRAID_CLIENT_ID environment variable.

.PARAMETER Baseline
    The sharing level a site is allowed to have. Anything more permissive is
    flagged. Values run from closed to open: Disabled,
    ExistingExternalUserSharingOnly, ExternalUserSharingOnly,
    ExternalUserAndGuestSharing.

.PARAMETER IncludeOneDriveSites
    Also report personal OneDrive sites. They have their own sharing setting and
    are usually the ones nobody has looked at.

.PARAMETER Template
    Only sites on this template, for example STS#3 for team sites or
    SITEPAGEPUBLISHING#0 for communication sites.

.PARAMETER AllSites
    Return every site, not just the ones above the baseline.

.PARAMETER CsvPath
    Also write the result to this CSV.

.EXAMPLE
    .\Get-SpoSharingReport.ps1 -TenantAdminUrl https://contoso-admin.sharepoint.com -ClientId $appId

.EXAMPLE
    # Anything that allows anonymous links
    .\Get-SpoSharingReport.ps1 -TenantAdminUrl https://contoso-admin.sharepoint.com `
        -Baseline ExternalUserSharingOnly -CsvPath .\sharing.csv

.EXAMPLE
    # The full picture, OneDrive included
    .\Get-SpoSharingReport.ps1 -TenantAdminUrl https://contoso-admin.sharepoint.com `
        -AllSites -IncludeOneDriveSites

.NOTES
    Needs PnP.PowerShell and SharePoint Administrator or Global Administrator.

    Since 9 September 2024 PnP.PowerShell no longer ships a shared multi-tenant
    app, so -ClientId is not optional. Register one once with
    Register-PnPEntraIDAppForInteractiveLogin, or set ENTRAID_CLIENT_ID and
    forget about it.
#>

[CmdletBinding()]
param(
    # SharePoint admin centre URL
    [Parameter(Mandatory)]
    [string]$TenantAdminUrl,

    # Client ID of your PnP app registration
    [string]$ClientId = $env:ENTRAID_CLIENT_ID,

    # Sharing level a site is allowed to have
    [ValidateSet('Disabled', 'ExistingExternalUserSharingOnly', 'ExternalUserSharingOnly', 'ExternalUserAndGuestSharing')]
    [string]$Baseline = 'ExternalUserSharingOnly',

    # Include personal OneDrive sites
    [switch]$IncludeOneDriveSites,

    # Only sites on this template
    [string]$Template,

    # Return every site, not only the ones above the baseline
    [switch]$AllSites,

    # Optional CSV export path
    [string]$CsvPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ------------------------------------------------------------------ setup ---

if (-not (Get-Module -ListAvailable -Name PnP.PowerShell)) {
    throw 'PnP.PowerShell is not installed. Run: Install-Module PnP.PowerShell -Scope CurrentUser'
}
Import-Module PnP.PowerShell -ErrorAction Stop

if ([string]::IsNullOrWhiteSpace($ClientId)) {
    throw @'
No ClientId. PnP.PowerShell needs your own Entra app registration to sign in.

Register one once:

    Register-PnPEntraIDAppForInteractiveLogin -ApplicationName 'PnP PowerShell' -Tenant contoso.onmicrosoft.com

Then pass -ClientId, or set the ENTRAID_CLIENT_ID environment variable.
'@
}

Write-Host "Connecting to $TenantAdminUrl ..." -ForegroundColor Cyan
Connect-PnPOnline -Url $TenantAdminUrl -Interactive -ClientId $ClientId -ErrorAction Stop

# Closed to open. The index is what makes "more permissive than" a comparison
# instead of a list of special cases.
$order = @(
    'Disabled'
    'ExistingExternalUserSharingOnly'
    'ExternalUserSharingOnly'
    'ExternalUserAndGuestSharing'
)

# A hashtable lookup rather than IndexOf: PowerShell hashtable keys are
# case-insensitive, and the casing Graph and SPO use is not always the casing in
# the ValidateSet.
$rank = @{}
for ($i = 0; $i -lt $order.Count; $i++) { $rank[$order[$i]] = $i }

function Get-SharingRank {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Capability)

    if ($script:rank.ContainsKey($Capability)) { return $script:rank[$Capability] }
    return -1
}

$baselineIndex = Get-SharingRank -Capability $Baseline

function Get-SiteProperty {
    <# Site properties vary by template and by how the site was created, and
       StrictMode turns a missing one into a terminating error. #>
    param($Site, [Parameter(Mandatory)][string]$Name)

    if ($Site -and $Site.PSObject.Properties.Name -contains $Name) {
        return $Site.$Name
    }
    return $null
}

# ------------------------------------------------------- tenant baseline ---

try {
    $tenant = Get-PnPTenant -ErrorAction Stop
    $tenantSharing = Get-SiteProperty -Site $tenant -Name 'SharingCapability'
    Write-Host "Tenant sharing setting : $tenantSharing"
}
catch {
    Write-Warning "Could not read the tenant sharing setting: $($_.Exception.Message)"
}

Write-Host "Baseline for this run  : $Baseline"

# ---------------------------------------------------------------- sites ---

Write-Host 'Fetching sites (-Detailed, so this takes a moment)...' -ForegroundColor Cyan

# Without -Detailed, SharingCapability comes back as a default value rather than
# the real one. The report would be confidently wrong.
$splat = @{ Detailed = $true; ErrorAction = 'Stop' }
if ($IncludeOneDriveSites) { $splat.IncludeOneDriveSites = $true }
if ($Template) { $splat.Template = $Template }

$sites = @(Get-PnPTenantSite @splat)
Write-Host "  $($sites.Count) site(s)."

if ($sites.Count -eq 0) { return @() }

# --------------------------------------------------------------- analyse ---

$rows = [System.Collections.Generic.List[object]]::new()

foreach ($site in $sites) {

    $capability = "$(Get-SiteProperty -Site $site -Name 'SharingCapability')"
    $aboveBaseline = ((Get-SharingRank -Capability $capability) -gt $baselineIndex)

    if (-not $AllSites -and -not $aboveBaseline) { continue }

    $storageBytes = Get-SiteProperty -Site $site -Name 'StorageUsageCurrent'

    $rows.Add([pscustomobject]@{
        Title              = "$(Get-SiteProperty -Site $site -Name 'Title')"
        Url                = "$(Get-SiteProperty -Site $site -Name 'Url')"
        Template           = "$(Get-SiteProperty -Site $site -Name 'Template')"
        SharingCapability  = $capability
        AboveBaseline      = $aboveBaseline
        LockState          = "$(Get-SiteProperty -Site $site -Name 'LockState')"
        Owner              = "$(Get-SiteProperty -Site $site -Name 'Owner')"
        # StorageUsageCurrent is already in MB, despite what the name suggests.
        StorageUsedMb      = $storageBytes
        LastContentChange  = Get-SiteProperty -Site $site -Name 'LastContentModifiedDate'
        GroupId            = "$(Get-SiteProperty -Site $site -Name 'GroupId')"
    })
}

$sorted = @($rows | Sort-Object @{ Expression = 'AboveBaseline'; Descending = $true }, Title)

# --------------------------------------------------------------- summary ---

Write-Host ''
Write-Host 'Sites per sharing level:'
$sites | Group-Object { "$(Get-SiteProperty -Site $_ -Name 'SharingCapability')" } |
    Sort-Object Name | ForEach-Object { Write-Host ("  {0,-32} {1}" -f $_.Name, $_.Count) }

$above = @($sorted | Where-Object AboveBaseline)

Write-Host ''
Write-Host "Above baseline : $($above.Count) of $($sites.Count)" -ForegroundColor $(if ($above.Count -gt 0) { 'Yellow' } else { 'Green' })

if ($CsvPath) {
    $sorted | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $CsvPath
    Write-Host "CSV            : $CsvPath" -ForegroundColor Green
}

if ($above.Count -gt 0) {
    Write-Host ''
    Write-Host 'Bring one back down with:' -ForegroundColor Cyan
    Write-Host '  Set-PnPTenantSite -Identity <url> -SharingCapability ExternalUserSharingOnly'
    Write-Host 'Existing shared links keep working. Tightening the setting stops new ones.' -ForegroundColor DarkGray
}

return $sorted
