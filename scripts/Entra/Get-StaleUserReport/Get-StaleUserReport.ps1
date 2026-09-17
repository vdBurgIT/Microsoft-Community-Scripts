#Requires -Version 7.2

<#
.SYNOPSIS
    Reports Entra ID accounts that have not signed in for a while, with the
    licences they are still holding on to.

.DESCRIPTION
    Reads last interactive and last non-interactive sign-in from the
    signInActivity property and works out how long each account has been quiet.
    Accounts that never signed in at all are reported separately, because a
    never-used account is a different problem from a forgotten one.

    Nothing is changed. The result goes to the pipeline, so pipe it into
    Export-Csv, Out-GridView, or hand it to whoever owns the licence budget.

.PARAMETER DaysInactive
    An account counts as stale after this many days without a sign-in.

.PARAMETER IncludeGuests
    Also report guest accounts. Off by default: guests are a separate cleanup
    with separate rules. Block-StaleGuestAccount handles those.

.PARAMETER IncludeDisabled
    Also report accounts that are already blocked from signing in.

.PARAMETER LicensedOnly
    Only report accounts holding at least one licence. That is the list that
    costs money every month.

.PARAMETER IncludeActive
    Return every account instead of only the stale ones.

.PARAMETER CsvPath
    Also write the result to this CSV.

.EXAMPLE
    ./Get-StaleUserReport.ps1

.EXAMPLE
    # Licensed accounts quiet for half a year, straight into a CSV
    ./Get-StaleUserReport.ps1 -DaysInactive 180 -LicensedOnly -CsvPath ./stale-users.csv

.EXAMPLE
    # The full picture, longest quiet first
    ./Get-StaleUserReport.ps1 -IncludeGuests -IncludeDisabled -IncludeActive |
        Sort-Object DaysSinceSignIn -Descending

.NOTES
    Graph scopes: User.Read.All and AuditLog.Read.All.

    signInActivity needs Microsoft Entra ID P1 or P2. Without it Graph returns
    the users and leaves signInActivity out, which makes every account look like
    it never signed in. The script warns when that happens instead of handing you
    a report full of false positives.
#>

[CmdletBinding()]
param(
    # Days without a sign-in before an account counts as stale
    [ValidateRange(1, 3650)]
    [int]$DaysInactive = 90,

    # Include guest accounts as well as members
    [switch]$IncludeGuests,

    # Include accounts that are already blocked from signing in
    [switch]$IncludeDisabled,

    # Only accounts that hold at least one licence
    [switch]$LicensedOnly,

    # Return active accounts too, not just the stale ones
    [switch]$IncludeActive,

    # Optional CSV export path
    [string]$CsvPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# =============================================================== helpers ====

function Initialize-GraphSession {
    <# Installs the auth module if needed and signs in only when the current
       session is missing a scope this script uses. #>
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
    <# One request, with a backoff on throttling and transient server errors. #>
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
    <# GET that follows every nextLink and returns the collected items. #>
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
    <# Hashtables from Graph omit properties that have no value, and StrictMode
       turns a missing key into a terminating error. This keeps that noise out
       of the rest of the script. #>
    param($Item, [Parameter(Mandatory)][string]$Key, $Default = $null)

    if ($Item -is [hashtable] -and $Item.ContainsKey($Key) -and $null -ne $Item[$Key]) {
        return $Item[$Key]
    }
    return $Default
}

# ================================================================= sign in ==

$context = Initialize-GraphSession -Scope @('User.Read.All', 'AuditLog.Read.All')
Write-Host "Signed in as : $($context.Account)"
Write-Host "Tenant       : $($context.TenantId)"

# ================================================================== fetch ===

$select = 'id,displayName,userPrincipalName,userType,accountEnabled,createdDateTime,' +
    'department,jobTitle,onPremisesSyncEnabled,assignedLicenses,signInActivity'

# 500 is the real ceiling once signInActivity is selected. Asking for 999 does
# not fail, it just silently pages at 500 anyway.
$uri = "https://graph.microsoft.com/v1.0/users?`$select=$select&`$top=500"

Write-Host 'Fetching users...' -ForegroundColor Cyan
$users = Invoke-GraphPaged -Uri $uri -Activity 'Fetching users'
Write-Host "  $($users.Count) account(s) returned."

if ($users.Count -eq 0) { throw 'Graph returned no users.' }

$withActivity = @($users | Where-Object { $null -ne (Get-GraphValue -Item $_ -Key 'signInActivity') }).Count
if ($withActivity -eq 0) {
    Write-Warning ('No account came back with signInActivity. That is what a tenant without Entra ID P1 ' +
        'looks like, and it makes every account below read as "never signed in". Check your licence tier ' +
        'before acting on this report.')
}

# ================================================================ analyse ===

$now = [datetime]::UtcNow
$cutoff = $now.AddDays(-$DaysInactive)
$rows = [System.Collections.Generic.List[object]]::new()

foreach ($user in $users) {

    $userType = [string](Get-GraphValue -Item $user -Key 'userType' -Default 'Member')
    if (-not $IncludeGuests -and $userType -eq 'Guest') { continue }

    $enabled = [bool](Get-GraphValue -Item $user -Key 'accountEnabled' -Default $false)
    if (-not $IncludeDisabled -and -not $enabled) { continue }

    $licences = @(Get-GraphValue -Item $user -Key 'assignedLicenses' -Default @())
    if ($LicensedOnly -and $licences.Count -eq 0) { continue }

    $activity = Get-GraphValue -Item $user -Key 'signInActivity'
    $interactive = Get-GraphValue -Item $activity -Key 'lastSignInDateTime'
    $nonInteractive = Get-GraphValue -Item $activity -Key 'lastNonInteractiveSignInDateTime'

    # Non-interactive covers service and token refresh traffic. An account with
    # only non-interactive activity is still in use by something, so treat the
    # most recent of the two as the real answer.
    $last = @($interactive, $nonInteractive) | Where-Object { $null -ne $_ } |
        Sort-Object -Descending | Select-Object -First 1

    $created = Get-GraphValue -Item $user -Key 'createdDateTime'

    $daysSinceSignIn = if ($null -ne $last) { [int]($now - [datetime]$last).TotalDays } else { $null }
    $daysSinceCreated = if ($null -ne $created) { [int]($now - [datetime]$created).TotalDays } else { $null }

    $status = if ($null -eq $last) { 'NeverSignedIn' }
              elseif ([datetime]$last -lt $cutoff) { 'Stale' }
              else { 'Active' }

    if (-not $IncludeActive -and $status -eq 'Active') { continue }

    $rows.Add([pscustomobject]@{
        DisplayName              = [string](Get-GraphValue -Item $user -Key 'displayName')
        UserPrincipalName        = [string](Get-GraphValue -Item $user -Key 'userPrincipalName')
        UserType                 = $userType
        Status                   = $status
        Enabled                  = $enabled
        DaysSinceSignIn          = $daysSinceSignIn
        LastSignIn               = $interactive
        LastNonInteractiveSignIn = $nonInteractive
        LicenseCount             = $licences.Count
        Department               = [string](Get-GraphValue -Item $user -Key 'department')
        JobTitle                 = [string](Get-GraphValue -Item $user -Key 'jobTitle')
        SyncedFromOnPrem         = [bool](Get-GraphValue -Item $user -Key 'onPremisesSyncEnabled' -Default $false)
        Created                  = $created
        DaysSinceCreated         = $daysSinceCreated
        Id                       = [string](Get-GraphValue -Item $user -Key 'id')
    })
}

$sorted = @($rows | Sort-Object @{ Expression = 'DaysSinceSignIn'; Descending = $true }, DisplayName)

# ================================================================ summary ===

$never = @($sorted | Where-Object Status -eq 'NeverSignedIn')
$stale = @($sorted | Where-Object Status -eq 'Stale')
$licensedStale = @($sorted | Where-Object { $_.Status -ne 'Active' -and $_.LicenseCount -gt 0 })

Write-Host ''
Write-Host "Cutoff       : $DaysInactive day(s), so before $($cutoff.ToString('yyyy-MM-dd'))"
Write-Host "Stale        : $($stale.Count)" -ForegroundColor Yellow
Write-Host "Never used   : $($never.Count)" -ForegroundColor Yellow
Write-Host "Licensed     : $($licensedStale.Count) of those still hold a licence" -ForegroundColor Yellow

if ($CsvPath) {
    $sorted | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $CsvPath
    Write-Host "CSV          : $CsvPath" -ForegroundColor Green
}

# Synced accounts are managed on-premises. Disabling them in Entra alone gets
# undone by the next sync cycle, so flag it here rather than in a footnote.
$synced = @($sorted | Where-Object SyncedFromOnPrem)
if ($synced.Count -gt 0) {
    Write-Host ''
    Write-Warning "$($synced.Count) of these are synced from Active Directory. Disable those in AD, not in Entra, or the next sync brings them back."
}

return $sorted
