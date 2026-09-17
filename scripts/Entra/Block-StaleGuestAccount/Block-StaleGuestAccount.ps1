#Requires -Version 7.2

<#
.SYNOPSIS
    Blocks sign-in on guest accounts that never accepted their invitation or have
    not signed in for months.

.DESCRIPTION
    Guests accumulate. Someone shares a document with an external colleague, that
    colleague changes jobs, and the account stays in the directory with whatever
    access it had. Blocking sign-in is the reversible middle step: the account and
    its permissions stay in place, so you can undo it in one click when somebody
    turns out to still need it.

    Two groups are picked up:

    - Guests that never signed in and were invited longer ago than
      -PendingAcceptanceDays
    - Guests whose last sign-in is older than -DaysInactive

    Member accounts are never touched. The filter is applied server-side and
    checked again per account before anything is written.

    Supports -WhatIf. Run it that way first.

.PARAMETER DaysInactive
    A guest that has signed in, but not within this many days, gets blocked.

.PARAMETER PendingAcceptanceDays
    A guest that never signed in and was invited longer ago than this gets
    blocked.

.PARAMETER MaxToBlock
    Safety cap. The script stops after this many accounts and tells you. Raise it
    deliberately once you have read the -WhatIf output.

.PARAMETER ExcludeUpn
    Accounts to leave alone, by user principal name or mail address. Wildcards
    are allowed, so '*@partner.com' works.

.PARAMETER SkipRoleCheck
    Skip the check for guests holding a directory role. The check costs the
    Directory.Read.All scope; without it those accounts are treated like any
    other guest.

.PARAMETER Unblock
    Turn it around and re-enable the accounts you pass through -ExcludeUpn. Only
    accounts named there are touched.

.PARAMETER CsvPath
    Write the result to this CSV, so you have a record of what was blocked and
    when.

.EXAMPLE
    # Always start here
    ./Block-StaleGuestAccount.ps1 -WhatIf

.EXAMPLE
    ./Block-StaleGuestAccount.ps1 -DaysInactive 180 -CsvPath ./blocked-guests.csv

.EXAMPLE
    # Leave a partner domain out of it
    ./Block-StaleGuestAccount.ps1 -ExcludeUpn '*partner.com*', 'auditor@contoso.com'

.EXAMPLE
    # Put one back
    ./Block-StaleGuestAccount.ps1 -Unblock -ExcludeUpn 'anna@contoso.com'

.NOTES
    Graph scopes: User.ReadWrite.All and AuditLog.Read.All, plus
    Directory.Read.All unless you pass -SkipRoleCheck. User Administrator or
    Global Administrator on the role side.

    signInActivity needs Microsoft Entra ID P1 or P2. On a tenant without it,
    every guest reads as "never signed in" and this script would block the lot,
    so it refuses to run rather than let that happen.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    # Days without a sign-in before a guest is blocked
    [ValidateRange(1, 3650)]
    [int]$DaysInactive = 90,

    # Days an invitation may stay unaccepted before the guest is blocked
    [ValidateRange(1, 3650)]
    [int]$PendingAcceptanceDays = 30,

    # Stop after this many accounts
    [ValidateRange(1, 10000)]
    [int]$MaxToBlock = 50,

    # Accounts to leave alone (wildcards allowed)
    [string[]]$ExcludeUpn,

    # Do not check for guests holding a directory role
    [switch]$SkipRoleCheck,

    # Re-enable the accounts named in -ExcludeUpn instead of blocking anything
    [switch]$Unblock,

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
        throw "These scopes were not granted: $($stillMissing -join ', '). Sign in as a User Administrator or Global Administrator and accept the consent prompt."
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

function Test-Excluded {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Upn, [string[]]$Pattern)

    if (-not $Pattern) { return $false }
    foreach ($p in $Pattern) {
        if ($Upn -like $p) { return $true }
    }
    return $false
}

# ================================================================= sign in ==

$scopes = @('User.ReadWrite.All', 'AuditLog.Read.All')
if (-not $SkipRoleCheck) { $scopes += 'Directory.Read.All' }

$context = Initialize-GraphSession -Scope $scopes
Write-Host "Signed in as : $($context.Account)"
Write-Host "Tenant       : $($context.TenantId)"

if ($Unblock -and -not $ExcludeUpn) {
    throw '-Unblock needs -ExcludeUpn. Naming the accounts to re-enable is deliberate: there is no "unblock everything".'
}

# ================================================================== fetch ===

$select = 'id,displayName,userPrincipalName,mail,userType,accountEnabled,createdDateTime,' +
    'externalUserState,externalUserStateChangeDateTime,signInActivity'

Write-Host 'Fetching guest accounts...' -ForegroundColor Cyan
$guests = Invoke-GraphPaged -Activity 'Fetching guests' -Uri ('https://graph.microsoft.com/v1.0/users' +
    "?`$filter=userType eq 'Guest'&`$select=$select&`$top=500")

Write-Host "  $($guests.Count) guest(s)."
if ($guests.Count -eq 0) { return @() }

# A tenant without Entra ID P1 returns no signInActivity at all, which would make
# every guest look abandoned. Refuse rather than block the entire guest directory.
if (-not $Unblock) {
    $withActivity = @($guests | Where-Object { $null -ne (Get-GraphValue -Item $_ -Key 'signInActivity') }).Count
    if ($withActivity -eq 0) {
        throw @'
Not one guest came back with signInActivity, so there is no way to tell an
abandoned account from an active one. That is what a tenant without Microsoft
Entra ID P1 looks like.

Check the licence tier first. Blocking on this data would hit every guest you
have.
'@
    }
}

# =============================================================== role check ==

$roleHolder = @{}

if (-not $SkipRoleCheck) {
    Write-Host 'Checking which guests hold a directory role...' -ForegroundColor Cyan
    try {
        foreach ($role in (Invoke-GraphPaged -Uri 'https://graph.microsoft.com/v1.0/directoryRoles?$select=id,displayName')) {
            $roleId = [string](Get-GraphValue -Item $role -Key 'id')
            $roleName = [string](Get-GraphValue -Item $role -Key 'displayName')

            foreach ($member in (Invoke-GraphPaged -Uri "https://graph.microsoft.com/v1.0/directoryRoles/$roleId/members?`$select=id&`$top=999")) {
                $memberId = [string](Get-GraphValue -Item $member -Key 'id')
                if (-not $memberId) { continue }
                $roleHolder[$memberId] = if ($roleHolder.ContainsKey($memberId)) { "$($roleHolder[$memberId]), $roleName" } else { $roleName }
            }
        }
        Write-Host "  $($roleHolder.Count) principal(s) hold a role."
    }
    catch {
        throw "The directory role check failed: $($_.Exception.Message). Fix the permissions or re-run with -SkipRoleCheck if you accept that risk."
    }
}

# ================================================================ decide =====

$now = [datetime]::UtcNow
$signInCutoff = $now.AddDays(-$DaysInactive)
$inviteCutoff = $now.AddDays(-$PendingAcceptanceDays)

$targets = [System.Collections.Generic.List[object]]::new()
$results = [System.Collections.Generic.List[object]]::new()

foreach ($guest in $guests) {

    # Belt and braces: the $filter already did this, but this script disables
    # accounts, so it checks again before deciding anything.
    if ([string](Get-GraphValue -Item $guest -Key 'userType') -ne 'Guest') { continue }

    $id = [string](Get-GraphValue -Item $guest -Key 'id')
    $upn = [string](Get-GraphValue -Item $guest -Key 'userPrincipalName')
    $mail = [string](Get-GraphValue -Item $guest -Key 'mail')
    $enabled = [bool](Get-GraphValue -Item $guest -Key 'accountEnabled' -Default $false)
    $state = [string](Get-GraphValue -Item $guest -Key 'externalUserState')
    $created = Get-GraphValue -Item $guest -Key 'createdDateTime'

    $activity = Get-GraphValue -Item $guest -Key 'signInActivity'
    $interactive = Get-GraphValue -Item $activity -Key 'lastSignInDateTime'
    $nonInteractive = Get-GraphValue -Item $activity -Key 'lastNonInteractiveSignInDateTime'
    $last = @($interactive, $nonInteractive) | Where-Object { $null -ne $_ } |
        Sort-Object -Descending | Select-Object -First 1

    $excluded = (Test-Excluded -Upn $upn -Pattern $ExcludeUpn) -or
                ($mail -and (Test-Excluded -Upn $mail -Pattern $ExcludeUpn))

    if ($Unblock) {
        if ($excluded -and -not $enabled) {
            $targets.Add([pscustomobject]@{ Guest = $guest; Id = $id; Upn = $upn; Reason = 'NamedInExcludeUpn' })
        }
        continue
    }

    if ($excluded) {
        $results.Add([pscustomobject]@{ UserPrincipalName = $upn; Mail = $mail; Reason = 'Excluded'; Action = 'Skipped'; LastSignIn = $last })
        continue
    }

    if (-not $enabled) {
        $results.Add([pscustomobject]@{ UserPrincipalName = $upn; Mail = $mail; Reason = 'AlreadyBlocked'; Action = 'NoChange'; LastSignIn = $last })
        continue
    }

    if ($roleHolder.ContainsKey($id)) {
        $results.Add([pscustomobject]@{ UserPrincipalName = $upn; Mail = $mail; Reason = "HoldsRole: $($roleHolder[$id])"; Action = 'Skipped'; LastSignIn = $last })
        continue
    }

    $reason = $null

    if ($null -eq $last) {
        # Never signed in. Only counts once the invitation has had time to land.
        if ($null -ne $created -and [datetime]$created -lt $inviteCutoff) {
            $reason = if ($state -eq 'PendingAcceptance') { 'InvitationNeverAccepted' } else { 'NeverSignedIn' }
        }
    }
    elseif ([datetime]$last -lt $signInCutoff) {
        $reason = 'NoSignInSince: ' + ([datetime]$last).ToString('yyyy-MM-dd')
    }

    if ($reason) {
        $targets.Add([pscustomobject]@{ Guest = $guest; Id = $id; Upn = $upn; Reason = $reason })
    }
    else {
        $results.Add([pscustomobject]@{ UserPrincipalName = $upn; Mail = $mail; Reason = 'Active'; Action = 'NoChange'; LastSignIn = $last })
    }
}

# ================================================================== apply ===

$verb = if ($Unblock) { 'Unblock' } else { 'Block' }
$newState = $Unblock.IsPresent

Write-Host ''
Write-Host "Candidates for $($verb.ToLower()): $($targets.Count)" -ForegroundColor Yellow

if ($targets.Count -gt $MaxToBlock) {
    Write-Warning "$($targets.Count) accounts match but -MaxToBlock is $MaxToBlock. Only the first $MaxToBlock are processed. Re-run with a higher cap once you have checked the list."
    $targets = $targets[0..($MaxToBlock - 1)]
}

foreach ($target in $targets) {
    if ($PSCmdlet.ShouldProcess($target.Upn, "$verb sign-in ($($target.Reason))")) {
        try {
            Invoke-GraphCall -Method PATCH -Uri "https://graph.microsoft.com/v1.0/users/$($target.Id)" `
                -Body @{ accountEnabled = $newState } | Out-Null

            $results.Add([pscustomobject]@{
                UserPrincipalName = $target.Upn
                Mail              = [string](Get-GraphValue -Item $target.Guest -Key 'mail')
                Reason            = $target.Reason
                Action            = "$($verb)ed"
                LastSignIn        = $null
            })
        }
        catch {
            $results.Add([pscustomobject]@{
                UserPrincipalName = $target.Upn
                Mail              = [string](Get-GraphValue -Item $target.Guest -Key 'mail')
                Reason            = $target.Reason
                Action            = "Failed: $($_.Exception.Message)"
                LastSignIn        = $null
            })
            Write-Warning "$($target.Upn): $($_.Exception.Message)"
        }
    }
}

# ================================================================ summary ===

$changed = @($results | Where-Object Action -eq "$($verb)ed").Count
$skipped = @($results | Where-Object Action -eq 'Skipped').Count
$failed = @($results | Where-Object { $_.Action -like 'Failed*' }).Count

Write-Host ''
Write-Host "$($verb)ed: $changed. Skipped: $skipped. Failed: $failed."

if ($CsvPath) {
    $results | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $CsvPath
    Write-Host "CSV     : $CsvPath" -ForegroundColor Green
}

if (-not $Unblock -and $changed -gt 0) {
    Write-Host ''
    Write-Host 'Blocked, not deleted. Group memberships and sharing permissions are still there, so this is reversible with -Unblock.' -ForegroundColor Cyan
}

return $results
