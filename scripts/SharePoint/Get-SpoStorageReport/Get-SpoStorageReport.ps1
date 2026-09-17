#Requires -Version 7.2

<#
.SYNOPSIS
    Exports SharePoint site storage and activity, and points out the sites that
    are full and the ones nobody has touched in months.

.DESCRIPTION
    Pulls the SharePoint site usage report out of the Graph reporting API and
    turns it into something you can sort. Per site you get storage used, storage
    allocated, how full that is, file counts, page views and the date of the last
    activity.

    Two questions this answers without opening the admin centre:

    - Which sites are close to their quota, before somebody cannot save a file
    - Which sites have had no activity at all, so the storage they hold is going
      nowhere useful

    Nothing is changed.

.PARAMETER Period
    Reporting window: D7, D30, D90 or D180. The activity columns cover this
    window; storage is the current figure either way.

.PARAMETER DormantDays
    A site with no activity in this many days is flagged as dormant.

.PARAMETER NearQuotaPercent
    Flag sites using at least this percentage of their allocated storage.

.PARAMETER MinStorageMb
    Only return sites holding at least this much. Filters out the long tail of
    empty sites.

.PARAMETER DormantOnly
    Only return sites flagged as dormant.

.PARAMETER IncludeDeleted
    Include sites the report marks as deleted. They still hold storage until the
    retention window runs out.

.PARAMETER CsvPath
    Also write the result to this CSV.

.EXAMPLE
    ./Get-SpoStorageReport.ps1

.EXAMPLE
    # The big, quiet sites
    ./Get-SpoStorageReport.ps1 -Period D90 -DormantOnly -MinStorageMb 1024 -CsvPath ./dormant-sites.csv

.EXAMPLE
    # Sorted by how full they are
    ./Get-SpoStorageReport.ps1 | Sort-Object PercentUsed -Descending | Select-Object -First 20

.NOTES
    Graph scope: Reports.Read.All. Reports Reader, SharePoint Administrator or
    Global Reader on the role side.

    Storage figures lag by roughly a day, same as the admin centre. Do not use
    this to confirm a cleanup you ran an hour ago.

    If the tenant has "Display concealed user, group, and site names" switched on
    in the Microsoft 365 admin centre, the site URLs and owner names come back as
    meaningless identifiers. The script says so instead of handing you a report
    you cannot act on.
#>

[CmdletBinding()]
param(
    # Reporting window
    [ValidateSet('D7', 'D30', 'D90', 'D180')]
    [string]$Period = 'D30',

    # Days without activity before a site is called dormant
    [ValidateRange(1, 3650)]
    [int]$DormantDays = 90,

    # Flag sites at or above this percentage of their quota
    [ValidateRange(1, 100)]
    [int]$NearQuotaPercent = 90,

    # Only sites holding at least this much storage, in MB
    [int]$MinStorageMb = 0,

    # Only return dormant sites
    [switch]$DormantOnly,

    # Include sites marked as deleted
    [switch]$IncludeDeleted,

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
        throw "These scopes were not granted: $($stillMissing -join ', '). Sign in as a Reports Reader or Global Reader and accept the consent prompt."
    }

    return $context
}

function Get-CsvField {
    <# Report column names contain spaces and Microsoft has renamed them before.
       StrictMode turns a missing column into a terminating error, so look it up
       instead of reaching for it. #>
    param($Row, [Parameter(Mandatory)][string]$Name, $Default = $null)

    if ($Row -and $Row.PSObject.Properties.Name -contains $Name) {
        $value = $Row.$Name
        if (-not [string]::IsNullOrWhiteSpace("$value")) { return $value }
    }
    return $Default
}

# ================================================================= sign in ==

$context = Initialize-GraphSession -Scope @('Reports.Read.All')
Write-Host "Signed in as : $($context.Account)"
Write-Host "Tenant       : $($context.TenantId)"

# ================================================================== fetch ===

# The endpoint answers with a 302 to a short-lived download URL and the file is
# CSV, not JSON. -OutputFilePath follows the redirect and writes the file.
$tempFile = Join-Path ([IO.Path]::GetTempPath()) "spo-site-usage-$([guid]::NewGuid()).csv"

Write-Host "Fetching the site usage report (period $Period)..." -ForegroundColor Cyan

try {
    Invoke-MgGraphRequest -Method GET -OutputFilePath $tempFile `
        -Uri "https://graph.microsoft.com/v1.0/reports/getSharePointSiteUsageDetail(period='$Period')" `
        -ErrorAction Stop

    $report = @(Import-Csv -Path $tempFile)
}
finally {
    if (Test-Path $tempFile) { Remove-Item $tempFile -Force -ErrorAction SilentlyContinue }
}

Write-Host "  $($report.Count) site(s) in the report."
if ($report.Count -eq 0) { return @() }

# ================================================================ analyse ===

$now = [datetime]::UtcNow
$rows = [System.Collections.Generic.List[object]]::new()
$concealed = 0

foreach ($row in $report) {

    $isDeleted = "$(Get-CsvField -Row $row -Name 'Is Deleted' -Default 'False')" -eq 'True'
    if ($isDeleted -and -not $IncludeDeleted) { continue }

    $url = "$(Get-CsvField -Row $row -Name 'Site URL')"
    $owner = "$(Get-CsvField -Row $row -Name 'Owner Display Name')"

    # Concealed names come back without a protocol, so there is no URL to click.
    if ($url -and $url -notmatch '^https?://') { $concealed++ }

    $usedBytes = [double](Get-CsvField -Row $row -Name 'Storage Used (Byte)' -Default 0)
    $quotaBytes = [double](Get-CsvField -Row $row -Name 'Storage Allocated (Byte)' -Default 0)

    $usedMb = [math]::Round($usedBytes / 1MB, 1)
    $quotaMb = [math]::Round($quotaBytes / 1MB, 1)
    $percent = if ($quotaBytes -gt 0) { [math]::Round(100 * $usedBytes / $quotaBytes, 1) } else { $null }

    if ($MinStorageMb -gt 0 -and $usedMb -lt $MinStorageMb) { continue }

    $lastActivityRaw = Get-CsvField -Row $row -Name 'Last Activity Date'
    $lastActivity = $null
    $daysIdle = $null

    if ($null -ne $lastActivityRaw) {
        $parsed = [datetime]::MinValue
        if ([datetime]::TryParse("$lastActivityRaw", [ref]$parsed)) {
            $lastActivity = $parsed
            $daysIdle = [int]($now - $parsed).TotalDays
        }
    }

    # No activity date at all means nothing happened in the whole window, which
    # is at least as dormant as an old date.
    $isDormant = ($null -eq $daysIdle) -or ($daysIdle -ge $DormantDays)
    if ($DormantOnly -and -not $isDormant) { continue }

    $rows.Add([pscustomobject]@{
        SiteUrl       = $url
        Owner         = $owner
        Template      = "$(Get-CsvField -Row $row -Name 'Root Web Template')"
        StorageUsedMb = $usedMb
        QuotaMb       = $quotaMb
        PercentUsed   = $percent
        NearQuota     = ($null -ne $percent -and $percent -ge $NearQuotaPercent)
        FileCount     = [int](Get-CsvField -Row $row -Name 'File Count' -Default 0)
        ActiveFiles   = [int](Get-CsvField -Row $row -Name 'Active File Count' -Default 0)
        PageViews     = [int](Get-CsvField -Row $row -Name 'Page View Count' -Default 0)
        LastActivity  = $lastActivity
        DaysIdle      = $daysIdle
        Dormant       = $isDormant
        IsDeleted     = $isDeleted
        SiteId        = "$(Get-CsvField -Row $row -Name 'Site Id')"
    })
}

$sorted = @($rows | Sort-Object StorageUsedMb -Descending)

# ================================================================ summary ===

$totalGb = [math]::Round((($sorted | Measure-Object -Property StorageUsedMb -Sum).Sum / 1024), 1)
$dormant = @($sorted | Where-Object Dormant)
$nearQuota = @($sorted | Where-Object NearQuota)
$dormantGb = [math]::Round((($dormant | Measure-Object -Property StorageUsedMb -Sum).Sum / 1024), 1)

Write-Host ''
Write-Host "Sites        : $($sorted.Count)"
Write-Host "Storage      : $totalGb GB"
Write-Host "Dormant      : $($dormant.Count) site(s) holding $dormantGb GB (no activity in $DormantDays day(s))" -ForegroundColor Yellow
Write-Host "Near quota   : $($nearQuota.Count) site(s) at or over $NearQuotaPercent%" -ForegroundColor $(if ($nearQuota.Count -gt 0) { 'Yellow' } else { 'Green' })

if ($CsvPath) {
    $sorted | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $CsvPath
    Write-Host "CSV          : $CsvPath" -ForegroundColor Green
}

if ($concealed -gt 0) {
    Write-Host ''
    Write-Warning ("$concealed site(s) came back with a concealed name. That is the " +
        '"Display concealed user, group, and site names" privacy setting in the Microsoft 365 admin centre, ' +
        'under Settings > Org settings > Reports. Turn it off to get real URLs back.')
}

return $sorted
