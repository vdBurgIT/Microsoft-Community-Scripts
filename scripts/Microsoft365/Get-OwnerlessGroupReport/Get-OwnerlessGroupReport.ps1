#Requires -Version 7.2

<#
.SYNOPSIS
    Finds Microsoft 365 groups and Teams with no owner, one owner, or an owner
    whose account is blocked.

.DESCRIPTION
    Owners leave. The group stays, along with its Team, its SharePoint site and
    its mailbox, and now nobody can add a member, approve a request or delete it.
    The first person to notice is usually the one who needed access today.

    Every Microsoft 365 group is checked and given a status:

    - NoOwner: nobody owns it
    - OwnersBlocked: every owner is blocked from signing in, which is no owner
      with extra steps
    - SingleOwner: one owner, which is one resignation away from NoOwner
    - Ok: two or more owners who can sign in

    Nothing is changed. Adding an owner is a decision, not a cleanup.

.PARAMETER Status
    Which statuses to return. The default leaves out the healthy groups.

.PARAMETER TeamsOnly
    Only groups that are backed by a Team.

.PARAMETER IncludeMemberCount
    Also count members. One extra call per group, and it turns "a group nobody
    owns" into "a group nobody owns with 340 people in it".

.PARAMETER CsvPath
    Also write the result to this CSV.

.EXAMPLE
    ./Get-OwnerlessGroupReport.ps1

.EXAMPLE
    # Everything, with member counts, into a CSV
    ./Get-OwnerlessGroupReport.ps1 -Status NoOwner, OwnersBlocked, SingleOwner, Ok `
        -IncludeMemberCount -CsvPath ./groups.csv

.EXAMPLE
    # Just the Teams that nobody owns
    ./Get-OwnerlessGroupReport.ps1 -Status NoOwner -TeamsOnly

.NOTES
    Graph scopes: Group.Read.All and User.Read.All.

    Security groups and distribution lists are not covered. This is about
    Microsoft 365 groups, the ones that carry a Team, a site and a mailbox.

    Microsoft has an ownerless group policy that emails the most active members
    and asks them to take over. It lives in the Microsoft 365 admin centre under
    Settings > Org settings > Microsoft 365 Groups. Worth turning on, and worth
    running this first so you know how big the backlog is.
#>

[CmdletBinding()]
param(
    # Which statuses to return
    [ValidateSet('NoOwner', 'OwnersBlocked', 'SingleOwner', 'Ok')]
    [string[]]$Status = @('NoOwner', 'OwnersBlocked', 'SingleOwner'),

    # Only Team-backed groups
    [switch]$TeamsOnly,

    # Also count members
    [switch]$IncludeMemberCount,

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
        [hashtable]$Header,
        [int]$MaxAttempts = 5
    )

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            $splat = @{ Method = $Method; Uri = $Uri; OutputType = 'Hashtable'; ErrorAction = 'Stop' }
            if ($Header) { $splat.Headers = $Header }
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

function Invoke-GraphBatch {
    <# Many small GETs through /$batch, 20 at a time. One owners call per group
       is unbearable once you have a few hundred Teams. #>
    param(
        [Parameter(Mandatory)][object[]]$Request,
        [string]$Activity = 'Graph batch'
    )

    $out = [System.Collections.Generic.List[object]]::new()
    $size = 20
    $done = 0

    for ($i = 0; $i -lt $Request.Count; $i += $size) {
        $chunk = $Request[$i..([math]::Min($i + $size - 1, $Request.Count - 1))]

        $body = @{
            requests = @(
                for ($n = 0; $n -lt $chunk.Count; $n++) {
                    $entry = @{ id = "$n"; method = 'GET'; url = $chunk[$n].Url }
                    if ($chunk[$n].ContainsKey('Headers')) { $entry.headers = $chunk[$n].Headers }
                    $entry
                }
            )
        }

        $resp = Invoke-GraphCall -Uri 'https://graph.microsoft.com/v1.0/$batch' -Method POST -Body $body

        foreach ($r in $resp['responses']) {
            $idx = [int]$r['id']
            $status = [int]$r['status']
            $rbody = if ($r.ContainsKey('body')) { $r['body'] } else { $null }

            if ($status -ge 200 -and $status -lt 300) {
                $out.Add([pscustomobject]@{ Key = $chunk[$idx].Key; Body = $rbody; Error = $null })
            }
            else {
                $out.Add([pscustomobject]@{ Key = $chunk[$idx].Key; Body = $null; Error = "HTTP $status" })
            }
        }

        $done += $chunk.Count
        Write-Progress -Activity $Activity -Status "$done / $($Request.Count)" `
            -PercentComplete ([int](100 * $done / $Request.Count))
    }

    Write-Progress -Activity $Activity -Completed
    return $out
}

function Get-GraphValue {
    param($Item, [Parameter(Mandatory)][string]$Key, $Default = $null)

    if ($Item -is [hashtable] -and $Item.ContainsKey($Key) -and $null -ne $Item[$Key]) {
        return $Item[$Key]
    }
    return $Default
}

# ================================================================= sign in ==

$context = Initialize-GraphSession -Scope @('Group.Read.All', 'User.Read.All')
Write-Host "Signed in as : $($context.Account)"
Write-Host "Tenant       : $($context.TenantId)"

# ================================================================= groups ===

$select = 'id,displayName,mail,description,visibility,createdDateTime,renewedDateTime,' +
    'expirationDateTime,resourceProvisioningOptions,membershipRule'

Write-Host 'Fetching Microsoft 365 groups...' -ForegroundColor Cyan
$groups = Invoke-GraphPaged -Activity 'Fetching groups' -Uri ('https://graph.microsoft.com/v1.0/groups' +
    "?`$filter=groupTypes/any(c:c eq 'Unified')&`$select=$select&`$top=999")

if ($TeamsOnly) {
    $groups = @($groups | Where-Object {
        @(Get-GraphValue -Item $_ -Key 'resourceProvisioningOptions' -Default @()) -contains 'Team'
    })
}

Write-Host "  $($groups.Count) group(s)."
if ($groups.Count -eq 0) { return @() }

# ================================================================= owners ===

Write-Host 'Fetching owners...' -ForegroundColor Cyan

$ownerRequests = $groups | ForEach-Object {
    $id = [string](Get-GraphValue -Item $_ -Key 'id')
    @{ Key = $id; Url = "/groups/$id/owners?`$select=id,displayName,userPrincipalName,accountEnabled" }
}

$ownersByGroup = @{}
foreach ($r in (Invoke-GraphBatch -Request $ownerRequests -Activity 'Fetching owners')) {
    $ownersByGroup[$r.Key] = if ($r.Body -and $r.Body.ContainsKey('value')) { @($r.Body['value']) } else { @() }
}

# ================================================================ members ===

$memberCountByGroup = @{}

if ($IncludeMemberCount) {
    Write-Host 'Counting members...' -ForegroundColor Cyan

    # /members/$count needs ConsistencyLevel: eventual. Without the header it
    # comes back as a 400 that says nothing useful.
    $countRequests = $groups | ForEach-Object {
        $id = [string](Get-GraphValue -Item $_ -Key 'id')
        @{ Key = $id; Url = "/groups/$id/members/`$count"; Headers = @{ ConsistencyLevel = 'eventual' } }
    }

    foreach ($r in (Invoke-GraphBatch -Request $countRequests -Activity 'Counting members')) {
        # The body of a $count response is a bare number, but it arrives as a
        # string often enough that parsing it is worth the three lines.
        $count = $null
        $parsed = 0
        if ($null -ne $r.Body -and [int]::TryParse("$($r.Body)", [ref]$parsed)) { $count = $parsed }
        $memberCountByGroup[$r.Key] = $count
    }
}

# ================================================================== build ===

$rows = [System.Collections.Generic.List[object]]::new()

foreach ($group in $groups) {

    $id = [string](Get-GraphValue -Item $group -Key 'id')
    $owners = if ($ownersByGroup.ContainsKey($id)) { $ownersByGroup[$id] } else { @() }

    $activeOwners = @($owners | Where-Object {
        # accountEnabled is absent on a service principal owner, which is rare
        # but real. Treat "no answer" as enabled rather than dropping it.
        $enabled = Get-GraphValue -Item $_ -Key 'accountEnabled'
        $null -eq $enabled -or $enabled -eq $true
    })

    $status = if ($owners.Count -eq 0) { 'NoOwner' }
              elseif ($activeOwners.Count -eq 0) { 'OwnersBlocked' }
              elseif ($activeOwners.Count -eq 1) { 'SingleOwner' }
              else { 'Ok' }

    if ($Status -notcontains $status) { continue }

    $ownerNames = @($owners | ForEach-Object {
        $upn = [string](Get-GraphValue -Item $_ -Key 'userPrincipalName')
        if ($upn) { $upn } else { [string](Get-GraphValue -Item $_ -Key 'displayName') }
    })

    $isTeam = @(Get-GraphValue -Item $group -Key 'resourceProvisioningOptions' -Default @()) -contains 'Team'
    $isDynamic = -not [string]::IsNullOrWhiteSpace([string](Get-GraphValue -Item $group -Key 'membershipRule'))

    $rows.Add([pscustomobject]@{
        DisplayName  = [string](Get-GraphValue -Item $group -Key 'displayName')
        Mail         = [string](Get-GraphValue -Item $group -Key 'mail')
        Status       = $status
        OwnerCount   = $owners.Count
        ActiveOwners = $activeOwners.Count
        Owners       = ($ownerNames -join '; ')
        IsTeam       = $isTeam
        Visibility   = [string](Get-GraphValue -Item $group -Key 'visibility')
        DynamicRule  = $isDynamic
        MemberCount  = if ($memberCountByGroup.ContainsKey($id)) { $memberCountByGroup[$id] } else { $null }
        Created      = Get-GraphValue -Item $group -Key 'createdDateTime'
        LastRenewed  = Get-GraphValue -Item $group -Key 'renewedDateTime'
        Expires      = Get-GraphValue -Item $group -Key 'expirationDateTime'
        GroupId      = $id
    })
}

$sorted = @($rows | Sort-Object OwnerCount, DisplayName)

# ================================================================ summary ===

$noOwner = @($sorted | Where-Object Status -eq 'NoOwner')
$blocked = @($sorted | Where-Object Status -eq 'OwnersBlocked')
$single = @($sorted | Where-Object Status -eq 'SingleOwner')

Write-Host ''
Write-Host "Groups checked : $($groups.Count)"
Write-Host "No owner       : $($noOwner.Count)" -ForegroundColor $(if ($noOwner.Count -gt 0) { 'Red' } else { 'Green' })
Write-Host "Owners blocked : $($blocked.Count)" -ForegroundColor $(if ($blocked.Count -gt 0) { 'Red' } else { 'Green' })
Write-Host "Single owner   : $($single.Count)" -ForegroundColor $(if ($single.Count -gt 0) { 'Yellow' } else { 'Green' })

if ($CsvPath) {
    $sorted | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $CsvPath
    Write-Host "CSV            : $CsvPath" -ForegroundColor Green
}

$publicNoOwner = @($noOwner | Where-Object Visibility -eq 'Public')
if ($publicNoOwner.Count -gt 0) {
    Write-Host ''
    Write-Warning "$($publicNoOwner.Count) ownerless group(s) are public, so anyone in the tenant can join and read the content. Those go first."
}

return $sorted
