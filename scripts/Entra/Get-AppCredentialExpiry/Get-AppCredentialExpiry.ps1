#Requires -Version 7.2

<#
.SYNOPSIS
    Lists every client secret and certificate on your app registrations with the
    date it expires and who owns it.

.DESCRIPTION
    Walks the app registrations in the tenant, and optionally the enterprise
    applications, and returns one row per credential: what it is, when it dies,
    how many days that is from now, and the owners you can chase.

    Expired credentials are included by default. A secret that expired two months
    ago and nobody noticed is worth knowing about: either something has been
    broken since then, or the app is dead and can go.

    Nothing is changed.

.PARAMETER DaysAhead
    Only return credentials expiring within this many days. Use 0 for all of
    them regardless of date.

.PARAMETER IncludeServicePrincipals
    Also check enterprise applications. Credentials there usually belong to SAML
    signing certificates, which expire just as quietly.

.PARAMETER IncludeMicrosoftApps
    Include service principals owned by Microsoft. Off by default: those are
    Microsoft's problem, and they drown out yours.

.PARAMETER SkipExpired
    Leave out credentials that have already expired.

.PARAMETER SkipOwners
    Do not look up owners. One extra Graph call per object, so this is the switch
    to reach for in a tenant with a few thousand registrations.

.PARAMETER CsvPath
    Also write the result to this CSV.

.EXAMPLE
    ./Get-AppCredentialExpiry.ps1

.EXAMPLE
    # Everything expiring in the next quarter, including SAML certificates
    ./Get-AppCredentialExpiry.ps1 -DaysAhead 90 -IncludeServicePrincipals

.EXAMPLE
    # Full inventory for the documentation
    ./Get-AppCredentialExpiry.ps1 -DaysAhead 0 -CsvPath ./app-credentials.csv

.NOTES
    Graph scopes: Application.Read.All, and User.Read.All to resolve owner names.
    Application Administrator or Global Reader is enough on the role side.

    Reading a secret's value is not possible and this does not try. You get the
    metadata, which is what expiry monitoring needs.
#>

[CmdletBinding()]
param(
    # Only credentials expiring within this many days. 0 means no date filter.
    [ValidateRange(0, 3650)]
    [int]$DaysAhead = 60,

    # Also check enterprise applications (service principals)
    [switch]$IncludeServicePrincipals,

    # Include Microsoft-owned service principals in that sweep
    [switch]$IncludeMicrosoftApps,

    # Leave out credentials that already expired
    [switch]$SkipExpired,

    # Skip the owner lookup (one extra call per object)
    [switch]$SkipOwners,

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

function Invoke-GraphBatch {
    <# Runs many small GETs through /$batch, 20 at a time. Returns one object per
       request with Key, Body and Error. #>
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
                    @{ id = "$n"; method = 'GET'; url = $chunk[$n].Url }
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

$scopes = @('Application.Read.All')
if (-not $SkipOwners) { $scopes += 'User.Read.All' }

$context = Initialize-GraphSession -Scope $scopes
Write-Host "Signed in as : $($context.Account)"
Write-Host "Tenant       : $($context.TenantId)"

# ================================================================== fetch ===

$objects = [System.Collections.Generic.List[object]]::new()

Write-Host 'Fetching app registrations...' -ForegroundColor Cyan
$apps = Invoke-GraphPaged -Activity 'App registrations' -Uri ('https://graph.microsoft.com/v1.0/applications' +
    "?`$select=id,appId,displayName,createdDateTime,passwordCredentials,keyCredentials&`$top=999")

foreach ($a in $apps) {
    $objects.Add([pscustomobject]@{ Kind = 'Application'; Path = 'applications'; Raw = $a })
}
Write-Host "  $($apps.Count) registration(s)."

if ($IncludeServicePrincipals) {
    Write-Host 'Fetching enterprise applications...' -ForegroundColor Cyan
    $sps = Invoke-GraphPaged -Activity 'Enterprise applications' -Uri ('https://graph.microsoft.com/v1.0/servicePrincipals' +
        "?`$select=id,appId,displayName,accountEnabled,servicePrincipalType,appOwnerOrganizationId," +
        "passwordCredentials,keyCredentials&`$top=999")

    # Microsoft's own first-party service principals carry this tenant id. There
    # are hundreds of them and none of them are yours to renew.
    $microsoftTenant = 'f8cdef31-a31e-4b4a-93e4-5f571e91255a'

    $kept = 0
    foreach ($s in $sps) {
        $owner = [string](Get-GraphValue -Item $s -Key 'appOwnerOrganizationId')
        if (-not $IncludeMicrosoftApps -and $owner -eq $microsoftTenant) { continue }
        $objects.Add([pscustomobject]@{ Kind = 'ServicePrincipal'; Path = 'servicePrincipals'; Raw = $s })
        $kept++
    }
    Write-Host "  $kept of $($sps.Count) kept (the rest are Microsoft's own)."
}

if ($objects.Count -eq 0) { throw 'Nothing to report on. Check that Application.Read.All was granted.' }

# ================================================================= owners ===

$ownersById = @{}

if (-not $SkipOwners) {
    Write-Host 'Resolving owners...' -ForegroundColor Cyan

    $requests = $objects | ForEach-Object {
        $id = [string](Get-GraphValue -Item $_.Raw -Key 'id')
        @{ Key = "$($_.Path)/$id"; Url = "/$($_.Path)/$id/owners?`$select=id,displayName,userPrincipalName" }
    }

    foreach ($r in (Invoke-GraphBatch -Request $requests -Activity 'Resolving owners')) {
        $names = @()
        if ($r.Body -and $r.Body.ContainsKey('value')) {
            $names = @($r.Body['value'] | ForEach-Object {
                $upn = [string](Get-GraphValue -Item $_ -Key 'userPrincipalName')
                if ($upn) { $upn } else { [string](Get-GraphValue -Item $_ -Key 'displayName') }
            })
        }
        $ownersById[$r.Key] = ($names -join '; ')
    }
}

# ================================================================ analyse ===

$now = [datetime]::UtcNow
$rows = [System.Collections.Generic.List[object]]::new()

function Add-CredentialRow {
    param(
        [Parameter(Mandatory)]$Entry,
        [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)]$Secret
    )

    $end = Get-GraphValue -Item $Secret -Key 'endDateTime'
    if ($null -eq $end) { return }

    $daysLeft = [int]([datetime]$end - $now).TotalDays
    $id = [string](Get-GraphValue -Item $Entry.Raw -Key 'id')
    $appId = [string](Get-GraphValue -Item $Entry.Raw -Key 'appId')
    $ownerKey = "$($Entry.Path)/$id"

    $status = if ($daysLeft -lt 0) { 'Expired' }
              elseif ($daysLeft -le 30) { 'ExpiringSoon' }
              else { 'Valid' }

    $script:rows.Add([pscustomobject]@{
        ObjectType     = $Entry.Kind
        DisplayName    = [string](Get-GraphValue -Item $Entry.Raw -Key 'displayName')
        AppId          = $appId
        ObjectId       = $id
        CredentialType = $Kind
        CredentialName = [string](Get-GraphValue -Item $Secret -Key 'displayName' -Default '(unnamed)')
        KeyId          = [string](Get-GraphValue -Item $Secret -Key 'keyId')
        Starts         = Get-GraphValue -Item $Secret -Key 'startDateTime'
        Expires        = $end
        DaysLeft       = $daysLeft
        Status         = $status
        Owners         = if ($ownersById.ContainsKey($ownerKey)) { $ownersById[$ownerKey] } else { '' }
        PortalUrl      = "https://entra.microsoft.com/#view/Microsoft_AAD_RegisteredApps/ApplicationMenuBlade/~/Credentials/appId/$appId"
    })
}

foreach ($entry in $objects) {
    foreach ($secret in @(Get-GraphValue -Item $entry.Raw -Key 'passwordCredentials' -Default @())) {
        Add-CredentialRow -Entry $entry -Kind 'Secret' -Secret $secret
    }
    foreach ($cert in @(Get-GraphValue -Item $entry.Raw -Key 'keyCredentials' -Default @())) {
        Add-CredentialRow -Entry $entry -Kind 'Certificate' -Secret $cert
    }
}

$filtered = $rows
if ($SkipExpired) { $filtered = @($filtered | Where-Object Status -ne 'Expired') }
if ($DaysAhead -gt 0) { $filtered = @($filtered | Where-Object { $_.DaysLeft -le $DaysAhead }) }

$sorted = @($filtered | Sort-Object DaysLeft, DisplayName)

# ================================================================ summary ===

$expired = @($sorted | Where-Object Status -eq 'Expired').Count
$soon = @($sorted | Where-Object Status -eq 'ExpiringSoon').Count
$noOwner = @($sorted | Where-Object { -not $_.Owners }).Count

Write-Host ''
Write-Host "Credentials  : $($rows.Count) found, $($sorted.Count) in scope"
Write-Host "Expired      : $expired" -ForegroundColor $(if ($expired -gt 0) { 'Red' } else { 'Green' })
Write-Host "Next 30 days : $soon" -ForegroundColor $(if ($soon -gt 0) { 'Yellow' } else { 'Green' })

if (-not $SkipOwners -and $noOwner -gt 0) {
    Write-Host "No owner     : $noOwner (nobody to email when these expire)" -ForegroundColor Yellow
}

if ($CsvPath) {
    $sorted | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $CsvPath
    Write-Host "CSV          : $CsvPath" -ForegroundColor Green
}

return $sorted
