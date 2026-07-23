#Requires -Version 7.2

<#
.SYNOPSIS
    Exports SharePoint library IDs for the Intune/Group Policy setting
    "Configure team site libraries to sync automatically".

    Only requirement: sign in with a Global Admin account. No app registration,
    no certificate, no PnP.

.DESCRIPTION
    Uses the Microsoft Graph PowerShell SDK, which ships with its own first-party
    Microsoft app ("Microsoft Graph Command Line Tools"), so you just sign in
    interactively and consent once. Only one small module is installed:
    Microsoft.Graph.Authentication.

    Output per library:
        tenantId=<guid>&siteId={<guid>}&webId={<guid>}&listId={<guid>}&webUrl=<url>&version=1

.EXAMPLE
    # Default: all Teams/M365 group sites + communication sites, one main library per site
    ./Get-SpoLibraryIds.ps1

.EXAMPLE
    # Preview which sites are discovered, without fetching any libraries
    ./Get-SpoLibraryIds.ps1 -ListSitesOnly

.EXAMPLE
    # Only sites whose name or URL matches, and every library inside them
    ./Get-SpoLibraryIds.ps1 -Filter '*Finance*' -IncludeAllDocumentLibraries

.EXAMPLE
    # Each GUID in its own column instead of the combined string
    ./Get-SpoLibraryIds.ps1 -Split

.EXAMPLE
    # Specific sites, plus a .reg file to test the policy locally
    ./Get-SpoLibraryIds.ps1 -SiteUrl https://contoso.sharepoint.com/sites/HR -RegPath ./automount.reg
#>


[CmdletBinding()]
param(
    # Limit to specific site URLs (skips discovery entirely)
    [string[]]$SiteUrl,

    # Wildcard filter on site name or URL, e.g. '*Finance*'
    [string]$Filter,

    # Only show which sites were discovered, export nothing
    [switch]$ListSitesOnly,

    # Export every document library instead of one main library per site
    [switch]$IncludeAllDocumentLibraries,

    # Include personal OneDrive sites (not recommended for automount)
    [switch]$IncludeOneDrivePersonalSites,

    # Skip searching for non-group sites (faster, Teams/M365 groups only)
    [switch]$SkipSiteSearch,

    # Library names to prefer when not using -IncludeAllDocumentLibraries.
    # Dutch names are included because list titles are localised per tenant.
    [string[]]$PreferredLibraryTitles = @(
        'Documents', 'Documenten', 'Shared Documents', 'Gedeelde documenten'
    ),

    # Libraries that should never be automounted (English + Dutch titles)
    [string[]]$ExcludeLibraryTitles = @(
        'Site Assets', 'Sitemiddelen', 'Style Library', 'Stijlbibliotheek',
        'Form Templates', 'Formuliersjablonen', 'Preservation Hold Library',
        'Teams Wiki Data', 'Site Pages', 'Sitepagina''s', 'Images', 'Afbeeldingen'
    ),

    # Put each GUID in its own column (SiteId, WebId, ListId) instead of the
    # combined LibraryId string.
    [Alias('Detailed')]
    [switch]$Split,

    # Sign in again even when a valid session already exists
    [switch]$ForceLogin,

    # Disable the Windows account picker (WAM broker) and sign in through the
    # browser only. This removes the double prompt on Windows. The setting is
    # persisted, so running it once is enough.
    [switch]$NoWam,

    [string]$CsvPath = './SPO_LibraryIds.csv',
    [string]$TxtPath = './SPO_LibraryIds.txt',
    # Optional .reg file to test the policy on a single machine
    [string]$RegPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# =============================================================== helpers ====

function Initialize-GraphModule {
    if (-not (Get-Module -ListAvailable -Name 'Microsoft.Graph.Authentication')) {
        Write-Host 'Installing module Microsoft.Graph.Authentication (one time)...' -ForegroundColor Yellow
        Install-Module Microsoft.Graph.Authentication -Scope CurrentUser -Force -AllowClobber
    }
    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
}

function Invoke-Graph {
    <# Single request with retry on throttling (429) and transient server errors. #>
    param(
        [Parameter(Mandatory)][string]$Uri,
        [string]$Method = 'GET',
        $Body,
        [int]$MaxAttempts = 5
    )

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            $splat = @{
                Method      = $Method
                Uri         = $Uri
                OutputType  = 'Hashtable'
                ErrorAction = 'Stop'
            }
            if ($null -ne $Body) {
                $splat.Body        = ($Body | ConvertTo-Json -Depth 10 -Compress)
                $splat.ContentType = 'application/json'
            }
            return Invoke-MgGraphRequest @splat
        }
        catch {
            $status = 0
            if ($_.Exception.PSObject.Properties.Name -contains 'Response' -and $_.Exception.Response) {
                $status = [int]$_.Exception.Response.StatusCode
            }
            $retryable = $status -in @(429, 500, 502, 503, 504)
            if (-not $retryable -or $attempt -eq $MaxAttempts) { throw }

            $wait = [math]::Pow(2, $attempt)
            Write-Verbose "Graph returned $status, retrying in $wait s (attempt $attempt/$MaxAttempts)"
            Start-Sleep -Seconds $wait
        }
    }
}

function Invoke-GraphPaged {
    <# GET that follows every page and returns the collected value items. #>
    param([Parameter(Mandatory)][string]$Uri)

    $items = [System.Collections.Generic.List[object]]::new()
    $next  = $Uri

    while ($next) {
        $resp = Invoke-Graph -Uri $next
        if ($resp.ContainsKey('value') -and $resp['value']) {
            foreach ($v in $resp['value']) { $items.Add($v) }
        }
        $next = if ($resp.ContainsKey('@odata.nextLink')) { $resp['@odata.nextLink'] } else { $null }
    }

    return $items
}

function Invoke-GraphBatch {
    <#
      Runs many individual GETs through /$batch (20 at a time).
      Returns one object per input item with .Key, .Body (or $null) and .Error.
      Saves minutes of waiting once you have a few hundred sites.
    #>
    param(
        [Parameter(Mandatory)][object[]]$Requests,   # @{ Key = 'x'; Url = '/sites/...' }
        [string]$Activity = 'Graph batch'
    )

    $out  = [System.Collections.Generic.List[object]]::new()
    $size = 20
    $done = 0

    for ($i = 0; $i -lt $Requests.Count; $i += $size) {
        $chunk = $Requests[$i..([math]::Min($i + $size - 1, $Requests.Count - 1))]

        $body = @{
            requests = @(
                for ($n = 0; $n -lt $chunk.Count; $n++) {
                    @{ id = "$n"; method = 'GET'; url = $chunk[$n].Url }
                }
            )
        }

        $resp = Invoke-Graph -Uri 'https://graph.microsoft.com/v1.0/$batch' -Method POST -Body $body

        foreach ($r in $resp['responses']) {
            $idx    = [int]$r['id']
            $status = [int]$r['status']
            $rbody  = if ($r.ContainsKey('body')) { $r['body'] } else { $null }

            if ($status -ge 200 -and $status -lt 300) {
                $out.Add([pscustomobject]@{ Key = $chunk[$idx].Key; Body = $rbody; Error = $null })
            }
            else {
                $msg = "HTTP $status"
                if ($rbody -and $rbody.ContainsKey('error') -and $rbody['error'].ContainsKey('message')) {
                    $msg = "$msg - $($rbody['error']['message'])"
                }
                $out.Add([pscustomobject]@{ Key = $chunk[$idx].Key; Body = $null; Error = $msg })
            }
        }

        $done += $chunk.Count
        Write-Progress -Activity $Activity -Status "$done / $($Requests.Count)" `
            -PercentComplete ([int](100 * $done / $Requests.Count))
    }

    Write-Progress -Activity $Activity -Completed
    return $out
}

function ConvertTo-SafeValueName {
    # Policy value names must not contain '=' or line breaks, and stay reasonably short.
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Name)

    $clean = (($Name -replace '[\r\n\t=]', ' ') -replace '\s{2,}', ' ').Trim()
    if ($clean.Length -gt 100) { $clean = $clean.Substring(0, 100).Trim() }
    if ([string]::IsNullOrWhiteSpace($clean)) { $clean = 'Library' }
    return $clean
}

function Test-LibraryIdValue {
    param([Parameter(Mandatory)][string]$Value)

    return $Value -match ('^tenantId=[0-9a-fA-F-]{36}' +
        '&siteId=\{[0-9a-fA-F-]{36}\}' +
        '&webId=\{[0-9a-fA-F-]{36}\}' +
        '&listId=\{[0-9a-fA-F-]{36}\}' +
        '&webUrl=https://[^&\s]+' +
        '&version=1$')
}

function Split-GraphSiteId {
    <#
      Graph returns a composite site id: "contoso.sharepoint.com,<siteGuid>,<webGuid>".
      Those are exactly the two GUIDs the policy needs.
    #>
    param([Parameter(Mandatory)][string]$Id)

    $parts = $Id -split ','
    if ($parts.Count -ne 3) { return $null }
    return [pscustomobject]@{ SiteId = $parts[1].Trim(); WebId = $parts[2].Trim() }
}

# ================================================================= sign in ==

Initialize-GraphModule

$scopes = @('Sites.Read.All', 'Group.Read.All')

# Already signed in with sufficient permissions? Then do not open a browser again.
$existing = Get-MgContext
$reuse    = -not $ForceLogin -and $existing -and
            -not @($scopes | Where-Object { @($existing.Scopes) -notcontains $_ })

if ($reuse) {
    Write-Host "Reusing existing Graph session ($($existing.Account))." -ForegroundColor Cyan
}
else {
    if ($NoWam) {
        $setOption = Get-Command Set-MgGraphOption -ErrorAction SilentlyContinue
        if ($setOption) {
            Set-MgGraphOption -DisableLoginByWAM $true
            Write-Host 'WAM broker disabled: signing in through the browser only.' -ForegroundColor Cyan
        }
        else {
            Write-Warning 'Set-MgGraphOption is not available; update Microsoft.Graph.Authentication to 2.36.1 or newer.'
        }
    }

    Write-Host 'Signing in to Microsoft Graph...' -ForegroundColor Cyan

    # CurrentUser is the default context scope, but set it explicitly: this is what
    # persists the token to disk so a later run does not have to sign in again.
    $connectSplat = @{ Scopes = $scopes; ContextScope = 'CurrentUser'; ErrorAction = 'Stop' }
    if ((Get-Command Connect-MgGraph).Parameters.ContainsKey('NoWelcome')) {
        $connectSplat.NoWelcome = $true
    }
    Connect-MgGraph @connectSplat
}

$context = Get-MgContext
if (-not $context) { throw 'Sign-in failed: no Graph context.' }

$tenantId = $context.TenantId
if ($tenantId -notmatch '^[0-9a-fA-F-]{36}$') {
    throw "Unexpected TenantId in the Graph context: '$tenantId'"
}

Write-Host "Signed in as : $($context.Account)"
Write-Host "TenantId     : $tenantId"
Write-Host ''

$grantedScopes = @($context.Scopes)
if ($grantedScopes -notcontains 'Sites.Read.All') {
    throw @'
The scope Sites.Read.All was not granted. Sign in as a Global Admin and accept
the consent prompt, or have an admin grant consent for the application
"Microsoft Graph Command Line Tools".
'@
}
$canReadGroups = $grantedScopes -contains 'Group.Read.All'

# ========================================================= discover sites ===

$sites   = [System.Collections.Generic.Dictionary[string, object]]::new()
$skipped = [System.Collections.Generic.List[object]]::new()

function Add-Site {
    param([Parameter(Mandatory)]$Site)

    if (-not $Site -or -not $Site.ContainsKey('id') -or -not $Site.ContainsKey('webUrl')) { return }

    $url = [string]$Site['webUrl']
    if (-not $IncludeOneDrivePersonalSites -and $url -match '-my\.sharepoint\.com/personal/') { return }

    $title = if ($Site.ContainsKey('displayName') -and $Site['displayName']) { [string]$Site['displayName'] }
             elseif ($Site.ContainsKey('name') -and $Site['name'])           { [string]$Site['name'] }
             else                                                            { $url }

    if (-not $sites.ContainsKey($Site['id'])) {
        $sites[$Site['id']] = [pscustomobject]@{
            Id     = [string]$Site['id']
            Title  = $title
            WebUrl = $url.TrimEnd('/')
        }
    }
}

if ($SiteUrl) {
    foreach ($u in $SiteUrl) {
        $clean = $u.TrimEnd('/')
        try {
            $uri  = [uri]$clean
            $path = $uri.AbsolutePath.TrimEnd('/')
            $rel  = if ($path -and $path -ne '/') { ":$path`:" } else { '' }
            Add-Site (Invoke-Graph -Uri "https://graph.microsoft.com/v1.0/sites/$($uri.Host)$rel`?`$select=id,name,displayName,webUrl")
        }
        catch {
            $skipped.Add([pscustomobject]@{ Item = $clean; Error = $_.Exception.Message })
            Write-Warning "Site not found: $clean ($($_.Exception.Message))"
        }
    }
}
else {
    # 1. All Teams / M365 group sites. This is the reliable route: complete, and
    #    not dependent on the search index.
    if ($canReadGroups) {
        Write-Host 'Fetching Microsoft 365 groups...' -ForegroundColor Cyan
        $groups = Invoke-GraphPaged -Uri ("https://graph.microsoft.com/v1.0/groups" +
            "?`$filter=groupTypes/any(c:c eq 'Unified')&`$select=id,displayName&`$top=999")
        Write-Host "  $($groups.Count) group(s) found."

        if ($groups.Count -gt 0) {
            $reqs = $groups | ForEach-Object {
                @{ Key = $_['displayName']; Url = "/groups/$($_['id'])/sites/root?`$select=id,name,displayName,webUrl" }
            }
            foreach ($r in (Invoke-GraphBatch -Requests $reqs -Activity 'Fetching group sites')) {
                if ($r.Body) { Add-Site $r.Body }
                # Groups without a site return 404; that is normal, not worth reporting.
                elseif ($r.Error -notlike 'HTTP 404*') {
                    $skipped.Add([pscustomobject]@{ Item = "group: $($r.Key)"; Error = $r.Error })
                }
            }
        }
    }
    else {
        Write-Warning 'Group.Read.All was not granted: skipping group sites.'
    }

    # 2. Remaining sites (communication sites, classic sites) through search.
    if (-not $SkipSiteSearch) {
        Write-Host 'Searching for other sites...' -ForegroundColor Cyan
        try {
            $found = Invoke-GraphPaged -Uri ('https://graph.microsoft.com/v1.0/sites' +
                "?search=*&`$select=id,name,displayName,webUrl&`$top=200")
            foreach ($s in $found) { Add-Site $s }
        }
        catch {
            Write-Warning "Site search failed: $($_.Exception.Message)"
        }
    }
}

$siteList = @($sites.Values)

if ($Filter) {
    $siteList = @($siteList | Where-Object { $_.Title -like $Filter -or $_.WebUrl -like $Filter })
}

$siteList = @($siteList | Sort-Object WebUrl)

Write-Host ''
Write-Host "Sites in scope: $($siteList.Count)" -ForegroundColor Green

if ($siteList.Count -eq 0) { throw 'No sites found.' }

if ($ListSitesOnly) {
    $siteList | Format-Table Title, WebUrl -AutoSize
    return
}

# ======================================================= fetch libraries ====

Write-Host 'Fetching libraries...' -ForegroundColor Cyan

$listReqs = $siteList | ForEach-Object {
    @{ Key = $_.Id; Url = "/sites/$($_.Id)/lists?`$select=id,name,displayName,list&`$top=200" }
}
$listResults = Invoke-GraphBatch -Requests $listReqs -Activity 'Fetching libraries'

$siteById = @{}
foreach ($s in $siteList) { $siteById[$s.Id] = $s }

$results = [System.Collections.Generic.List[object]]::new()

foreach ($res in $listResults) {
    $site = $siteById[$res.Key]

    if (-not $res.Body) {
        $skipped.Add([pscustomobject]@{ Item = $site.WebUrl; Error = $res.Error })
        continue
    }

    $ids = Split-GraphSiteId -Id $site.Id
    if (-not $ids) {
        $skipped.Add([pscustomobject]@{ Item = $site.WebUrl; Error = "Unexpected site id: $($site.Id)" })
        continue
    }

    $libs = @(
        foreach ($l in $res.Body['value']) {
            if (-not $l.ContainsKey('list')) { continue }
            $facet = $l['list']

            $isLibrary = $facet.ContainsKey('template') -and $facet['template'] -eq 'documentLibrary'
            $isHidden  = $facet.ContainsKey('hidden')   -and $facet['hidden']
            if (-not $isLibrary -or $isHidden) { continue }

            $title = if ($l.ContainsKey('displayName') -and $l['displayName']) { [string]$l['displayName'] } else { [string]$l['name'] }
            if ($ExcludeLibraryTitles -contains $title) { continue }

            [pscustomobject]@{ Id = [string]$l['id']; Title = $title }
        }
    )

    if ($libs.Count -eq 0) { continue }

    if (-not $IncludeAllDocumentLibraries) {
        $preferred = $libs | Where-Object { $PreferredLibraryTitles -contains $_.Title } | Select-Object -First 1
        $libs = if ($preferred) { @($preferred) } else { @($libs[0]) }
    }

    foreach ($lib in $libs) {
        $value = 'tenantId={0}&siteId={{{1}}}&webId={{{2}}}&listId={{{3}}}&webUrl={4}&version=1' -f `
            $tenantId, $ids.SiteId, $ids.WebId, $lib.Id, $site.WebUrl

        if (-not (Test-LibraryIdValue -Value $value)) {
            $skipped.Add([pscustomobject]@{ Item = $site.WebUrl; Error = "Invalid library ID: $value" })
            continue
        }

        # One library per site: the site name on its own is shorter and clearer.
        $label = if ($IncludeAllDocumentLibraries) { "$($site.Title) - $($lib.Title)" } else { $site.Title }

        $results.Add([pscustomobject]@{
            Name         = ConvertTo-SafeValueName -Name $label
            LibraryId    = $value
            SiteUrl      = $site.WebUrl
            LibraryTitle = $lib.Title
            # Bare GUIDs without braces: braces belong in the combined string only.
            SiteId       = $ids.SiteId
            WebId        = $ids.WebId
            ListId       = $lib.Id
        })
    }
}

if ($results.Count -eq 0) {
    throw 'No libraries found. Check the warnings above.'
}

# Value names must be unique within the policy.
$results | Group-Object Name | Where-Object Count -gt 1 | ForEach-Object {
    foreach ($dup in $_.Group) {
        $slug = ($dup.SiteUrl -split '/')[-1]
        $dup.Name = ConvertTo-SafeValueName -Name "$($dup.Name) ($slug)"
    }
}

$sorted = $results | Sort-Object Name

# ================================================================= export ==

# Default is two columns: exactly what the Intune policy asks for (name + value).
# -Split gives each GUID its own column instead.
# TenantId is identical for every row, so it goes in the summary, not the table.
$columns = if ($Split) {
    @('Name', 'SiteUrl', 'SiteId', 'WebId', 'ListId')
} else {
    @('Name', 'LibraryId')
}

$table = $sorted | Select-Object -Property $columns

$table | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $CsvPath

# The TXT is tab separated with a header row: pastes straight into Excel or any
# other system.
$tsv = [System.Collections.Generic.List[string]]::new()
$tsv.Add(($columns -join "`t"))
foreach ($row in $table) {
    $tsv.Add((($columns | ForEach-Object { [string]$row.$_ }) -join "`t"))
}
$tsv | Set-Content -Encoding UTF8 -Path $TxtPath

if ($RegPath) {
    $reg = [System.Collections.Generic.List[string]]::new()
    $reg.Add('Windows Registry Editor Version 5.00')
    $reg.Add('')
    $reg.Add('[HKEY_CURRENT_USER\Software\Policies\Microsoft\OneDrive\TenantAutoMount]')
    foreach ($r in $sorted) {
        $name = $r.Name      -replace '\\', '\\\\' -replace '"', '\"'
        $val  = $r.LibraryId -replace '\\', '\\\\' -replace '"', '\"'
        $reg.Add("`"$name`"=`"$val`"")
    }
    $reg | Set-Content -Encoding ASCII -Path $RegPath
}

Write-Host ''
Write-Host "TenantId     : $tenantId  (same for every row)" -ForegroundColor Green
Write-Host "Libraries    : $($results.Count)" -ForegroundColor Green
Write-Host "CSV          : $CsvPath  (comma separated)" -ForegroundColor Green
Write-Host "TXT          : $TxtPath  (tab separated, pastes into Excel)" -ForegroundColor Green
if ($RegPath) { Write-Host "REG          : $RegPath" -ForegroundColor Green }

if ($Split) {
    Write-Host ''
    Write-Warning ('Separate GUID columns are handy as a table, but the Intune policy ' +
        'only accepts the complete string. Run without -Split for the LibraryId column.')
}

if ($skipped.Count -gt 0) {
    Write-Host ''
    Write-Warning "$($skipped.Count) item(s) skipped:"
    $skipped | ForEach-Object { Write-Host "  - $($_.Item) :: $($_.Error)" -ForegroundColor DarkYellow }
}

# Return objects so you can pipe the result onwards:
#   ./Get-SpoLibraryIds.ps1 | Set-Clipboard
#   ./Get-SpoLibraryIds.ps1 | ConvertTo-Json
#   ./Get-SpoLibraryIds.ps1 | Out-GridView
return $table

<#
USING THIS IN INTUNE
--------------------
Intune > Devices > Configuration > Settings catalog > OneDrive >
"Configure team site libraries to sync automatically"
Per row: Value name = the Name column, Value = the LibraryId column.

The values are already decoded ({ } : / . as literal characters), exactly the way
the policy expects them. Underlying registry key:
    HKCU\Software\Policies\Microsoft\OneDrive\TenantAutoMount

TESTING
-------
Run with -RegPath ./automount.reg, import that file on a single test machine and
restart the OneDrive client.

SIGN-IN NOTES
-------------
The token is cached on disk under the CurrentUser context scope, so a later run
reuses it without prompting. Getting prompted twice on Windows is usually the WAM
broker: run once with -NoWam to switch to browser-only sign-in.

CLEANUP
-------
    Disconnect-MgGraph
#>
