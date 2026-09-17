#Requires -Version 7.2

<#
.SYNOPSIS
    Exports every Intune policy, script and app with the groups it is assigned
    to, in one table.

.DESCRIPTION
    The Intune portal shows assignments one policy at a time. Answering "which
    policies hit this group" means opening every profile and reading the
    Assignments tab, which is where the afternoon goes.

    This walks the lot and returns one row per assignment:

    - Configuration profiles (the older templates)
    - Settings catalog policies
    - Compliance policies
    - Platform scripts and remediations
    - Apps, with their install intent

    Group IDs are resolved to names, include and exclude assignments are marked
    as such, and policies with no assignment at all get a row too. Those are the
    interesting ones: someone built them, nobody deployed them.

    Nothing is changed.

.PARAMETER PolicyType
    Limit to one or more kinds. Leave empty for everything except apps, which you
    turn on with -IncludeApps.

.PARAMETER IncludeApps
    Also walk deviceAppManagement/mobileApps. Adds time in a tenant with a large
    app catalogue.

.PARAMETER GroupName
    Only return assignments targeting a group whose name matches, for example
    '*Pilot*'. The answer to "what does this group actually get".

.PARAMETER HideUnassigned
    Leave out the rows for policies that are not assigned to anything.

.PARAMETER CsvPath
    Also write the result to this CSV.

.EXAMPLE
    ./Get-PolicyAssignmentReport.ps1

.EXAMPLE
    # Everything, apps included, into a CSV
    ./Get-PolicyAssignmentReport.ps1 -IncludeApps -CsvPath ./intune-assignments.csv

.EXAMPLE
    # What does the pilot group get?
    ./Get-PolicyAssignmentReport.ps1 -IncludeApps -GroupName '*Pilot*'

.EXAMPLE
    # Which compliance policies were never deployed?
    ./Get-PolicyAssignmentReport.ps1 -PolicyType Compliance |
        Where-Object AssignmentMode -eq 'None'

.NOTES
    Graph scopes: DeviceManagementConfiguration.Read.All, Group.Read.All, and
    DeviceManagementApps.Read.All when you use -IncludeApps. Global Reader or
    an Intune read-only role is enough.

    This runs against the Graph beta endpoint. Settings catalog policies,
    platform scripts and remediations have no v1.0 equivalent, so beta is the
    only way to see them. Microsoft may change beta without notice.
#>

[CmdletBinding()]
param(
    # Kinds of policy to include
    [ValidateSet('ConfigurationProfile', 'SettingsCatalog', 'Compliance', 'PlatformScript', 'Remediation')]
    [string[]]$PolicyType,

    # Also report app assignments
    [switch]$IncludeApps,

    # Only assignments targeting a group whose name matches (wildcards allowed)
    [string]$GroupName,

    # Leave out policies with no assignment
    [switch]$HideUnassigned,

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
    <# Many small GETs through /$batch, 20 at a time. One assignment call per
       policy is fine on a handful; it is not fine on four hundred. #>
    param(
        [Parameter(Mandatory)][object[]]$Request,
        [string]$Endpoint = 'beta',
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

        $resp = Invoke-GraphCall -Uri "https://graph.microsoft.com/$Endpoint/`$batch" -Method POST -Body $body

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

$scopes = @('DeviceManagementConfiguration.Read.All', 'Group.Read.All')
if ($IncludeApps) { $scopes += 'DeviceManagementApps.Read.All' }

$context = Initialize-GraphSession -Scope $scopes
Write-Host "Signed in as : $($context.Account)"
Write-Host "Tenant       : $($context.TenantId)"

# ========================================================== policy sources ==

# Settings catalog policies carry their name in 'name'; everything else uses
# 'displayName'. Getting that wrong gives you a report full of blank names.
$sources = @(
    @{ Kind = 'ConfigurationProfile'; Path = 'deviceManagement/deviceConfigurations';   NameKey = 'displayName' }
    @{ Kind = 'SettingsCatalog';      Path = 'deviceManagement/configurationPolicies';  NameKey = 'name' }
    @{ Kind = 'Compliance';           Path = 'deviceManagement/deviceCompliancePolicies'; NameKey = 'displayName' }
    @{ Kind = 'PlatformScript';       Path = 'deviceManagement/deviceManagementScripts'; NameKey = 'displayName' }
    @{ Kind = 'Remediation';          Path = 'deviceManagement/deviceHealthScripts';    NameKey = 'displayName' }
)

if ($PolicyType) {
    $sources = @($sources | Where-Object { $PolicyType -contains $_.Kind })
}

if ($IncludeApps) {
    $sources += @{ Kind = 'App'; Path = 'deviceAppManagement/mobileApps'; NameKey = 'displayName' }
}

if ($sources.Count -eq 0) { throw 'Nothing selected. Check -PolicyType, or drop it to get everything.' }

$items = [System.Collections.Generic.List[object]]::new()

foreach ($source in $sources) {
    Write-Host "Fetching $($source.Kind)..." -ForegroundColor Cyan
    try {
        $found = Invoke-GraphPaged -Activity "Fetching $($source.Kind)" `
            -Uri "https://graph.microsoft.com/beta/$($source.Path)?`$top=200"
    }
    catch {
        # One endpoint being unavailable should not cost you the whole report.
        Write-Warning "$($source.Kind) could not be read: $($_.Exception.Message)"
        continue
    }

    foreach ($f in $found) {
        $items.Add([pscustomobject]@{
            Kind    = $source.Kind
            Path    = $source.Path
            Id      = [string](Get-GraphValue -Item $f -Key 'id')
            Name    = [string](Get-GraphValue -Item $f -Key $source.NameKey -Default '(no name)')
            Raw     = $f
        })
    }

    Write-Host "  $($found.Count) found."
}

if ($items.Count -eq 0) { throw 'No policies found. Check the scopes and the warnings above.' }

# ============================================================ assignments ===

Write-Host 'Fetching assignments...' -ForegroundColor Cyan

$requests = $items | ForEach-Object {
    @{ Key = "$($_.Kind)|$($_.Id)"; Url = "/$($_.Path)/$($_.Id)/assignments" }
}

$assignmentsByKey = @{}
foreach ($r in (Invoke-GraphBatch -Request $requests -Activity 'Fetching assignments')) {
    $assignmentsByKey[$r.Key] = if ($r.Body -and $r.Body.ContainsKey('value')) { @($r.Body['value']) } else { @() }
    if ($r.Error) { Write-Verbose "Assignments for $($r.Key): $($r.Error)" }
}

# ============================================================= group names ==

$groupIds = [System.Collections.Generic.HashSet[string]]::new()

foreach ($key in $assignmentsByKey.Keys) {
    foreach ($assignment in $assignmentsByKey[$key]) {
        $target = Get-GraphValue -Item $assignment -Key 'target'
        $groupId = [string](Get-GraphValue -Item $target -Key 'groupId')
        if ($groupId) { $null = $groupIds.Add($groupId) }
    }
}

$groupNames = @{}

if ($groupIds.Count -gt 0) {
    Write-Host "Resolving $($groupIds.Count) group name(s)..." -ForegroundColor Cyan

    $groupRequests = @($groupIds) | ForEach-Object {
        @{ Key = $_; Url = "/groups/$_`?`$select=id,displayName" }
    }

    foreach ($r in (Invoke-GraphBatch -Request $groupRequests -Endpoint 'v1.0' -Activity 'Resolving groups')) {
        # A deleted group leaves the assignment behind. Say so instead of
        # printing a bare GUID nobody can look up any more.
        $groupNames[$r.Key] = if ($r.Body) { [string](Get-GraphValue -Item $r.Body -Key 'displayName') } else { '(group not found)' }
    }
}

function Resolve-AssignmentTarget {
    <# Turns the target complex type into something a human can read. #>
    param($Target)

    $type = [string](Get-GraphValue -Item $Target -Key '@odata.type')
    $groupId = [string](Get-GraphValue -Item $Target -Key 'groupId')

    switch -Wildcard ($type) {
        '*exclusionGroupAssignmentTarget' {
            $name = if ($script:groupNames.ContainsKey($groupId)) { $script:groupNames[$groupId] } else { $groupId }
            return [pscustomobject]@{ Mode = 'Exclude'; Target = $name; GroupId = $groupId }
        }
        '*groupAssignmentTarget' {
            $name = if ($script:groupNames.ContainsKey($groupId)) { $script:groupNames[$groupId] } else { $groupId }
            return [pscustomobject]@{ Mode = 'Include'; Target = $name; GroupId = $groupId }
        }
        '*allLicensedUsersAssignmentTarget' {
            return [pscustomobject]@{ Mode = 'Include'; Target = 'All users'; GroupId = '' }
        }
        '*allDevicesAssignmentTarget' {
            return [pscustomobject]@{ Mode = 'Include'; Target = 'All devices'; GroupId = '' }
        }
        default {
            return [pscustomobject]@{ Mode = 'Include'; Target = "($type)"; GroupId = $groupId }
        }
    }
}

# ================================================================== build ===

$rows = [System.Collections.Generic.List[object]]::new()

foreach ($item in $items) {
    $key = "$($item.Kind)|$($item.Id)"
    $assignments = if ($assignmentsByKey.ContainsKey($key)) { $assignmentsByKey[$key] } else { @() }

    $platform = [string](Get-GraphValue -Item $item.Raw -Key 'platforms')
    if (-not $platform) {
        # The older configuration profiles put the platform in their own
        # @odata.type, e.g. #microsoft.graph.windows10GeneralConfiguration.
        $odata = [string](Get-GraphValue -Item $item.Raw -Key '@odata.type')
        $platform = ($odata -replace '^#microsoft\.graph\.', '')
    }

    if ($assignments.Count -eq 0) {
        if ($HideUnassigned -or $GroupName) { continue }

        $rows.Add([pscustomobject]@{
            PolicyType     = $item.Kind
            PolicyName     = $item.Name
            Platform       = $platform
            AssignmentMode = 'None'
            Target         = '(not assigned)'
            TargetGroupId  = ''
            Intent         = ''
            LastModified   = Get-GraphValue -Item $item.Raw -Key 'lastModifiedDateTime'
            PolicyId       = $item.Id
        })
        continue
    }

    foreach ($assignment in $assignments) {
        $resolved = Resolve-AssignmentTarget -Target (Get-GraphValue -Item $assignment -Key 'target')

        if ($GroupName -and $resolved.Target -notlike $GroupName) { continue }

        $rows.Add([pscustomobject]@{
            PolicyType     = $item.Kind
            PolicyName     = $item.Name
            Platform       = $platform
            AssignmentMode = $resolved.Mode
            Target         = $resolved.Target
            TargetGroupId  = $resolved.GroupId
            Intent         = [string](Get-GraphValue -Item $assignment -Key 'intent')
            LastModified   = Get-GraphValue -Item $item.Raw -Key 'lastModifiedDateTime'
            PolicyId       = $item.Id
        })
    }
}

$sorted = @($rows | Sort-Object PolicyType, PolicyName, AssignmentMode, Target)

# ================================================================ summary ===

$unassigned = @($sorted | Where-Object AssignmentMode -eq 'None')
$excludes = @($sorted | Where-Object AssignmentMode -eq 'Exclude')
$broadTargets = @($sorted | Where-Object { $_.Target -in @('All users', 'All devices') })

Write-Host ''
Write-Host "Policies     : $($items.Count)"
Write-Host "Rows         : $($sorted.Count)"
Write-Host "Unassigned   : $($unassigned.Count)" -ForegroundColor $(if ($unassigned.Count -gt 0) { 'Yellow' } else { 'Green' })
Write-Host "Excludes     : $($excludes.Count)"
Write-Host "All users or all devices: $($broadTargets.Count)"

if ($CsvPath) {
    $sorted | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $CsvPath
    Write-Host "CSV          : $CsvPath" -ForegroundColor Green
}

return $sorted
