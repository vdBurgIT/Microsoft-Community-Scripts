#Requires -Version 7.2

<#
.SYNOPSIS
    Lists who holds which Entra ID admin role, including the accounts that got
    there through a group and the PIM-eligible ones.

.DESCRIPTION
    Three things end up in the same table:

    - Active assignments, read from the activated directory roles
    - Members of role-assignable groups, resolved to the people inside them
    - PIM-eligible assignments, if you ask for them and have Entra ID P2

    Group-based assignments are the ones that go missing in a hand-built
    overview. Somebody looks at the role blade, sees one group, writes down one
    line, and the nine people in that group never make it into the document.

    Nothing is changed.

.PARAMETER IncludeEligible
    Also report PIM-eligible assignments. Needs Entra ID P2 and the
    RoleManagement.Read.Directory scope.

.PARAMETER SkipGroupMembers
    Report role-assignable groups as a single row instead of resolving the
    people inside them.

.PARAMETER RoleName
    Limit to roles whose name matches, for example 'Global Administrator' or
    '*Administrator*'.

.PARAMETER CsvPath
    Also write the result to this CSV.

.EXAMPLE
    ./Get-AdminRoleReport.ps1

.EXAMPLE
    # Everything, PIM included, into a CSV for the yearly access review
    ./Get-AdminRoleReport.ps1 -IncludeEligible -CsvPath ./admin-roles.csv

.EXAMPLE
    # Just the top of the tree
    ./Get-AdminRoleReport.ps1 -RoleName 'Global Administrator'

.NOTES
    Graph scopes: Directory.Read.All, plus RoleManagement.Read.Directory when
    you use -IncludeEligible. Global Reader is enough on the role side.

    Only activated roles appear under directoryRoles. A built-in role that has
    never had a member in this tenant is not activated and will not show up,
    which is correct: an empty role is not an assignment.
#>

[CmdletBinding()]
param(
    # Also report PIM-eligible assignments (needs Entra ID P2)
    [switch]$IncludeEligible,

    # Report role-assignable groups as one row instead of expanding them
    [switch]$SkipGroupMembers,

    # Wildcard filter on the role display name
    [string]$RoleName,

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

function Get-PrincipalKind {
    <# Graph tags every directoryObject with its real type. Without it a user and
       a service principal look identical in the output. #>
    param($Item)

    $type = [string](Get-GraphValue -Item $Item -Key '@odata.type')
    switch -Wildcard ($type) {
        '*servicePrincipal' { return 'ServicePrincipal' }
        '*group'            { return 'Group' }
        '*user'             { return 'User' }
        default             { return 'Unknown' }
    }
}

# ================================================================= sign in ==

$scopes = @('Directory.Read.All')
if ($IncludeEligible) { $scopes += 'RoleManagement.Read.Directory' }

$context = Initialize-GraphSession -Scope $scopes
Write-Host "Signed in as : $($context.Account)"
Write-Host "Tenant       : $($context.TenantId)"

# ================================================================== roles ===

Write-Host 'Fetching activated directory roles...' -ForegroundColor Cyan
$roles = Invoke-GraphPaged -Uri 'https://graph.microsoft.com/v1.0/directoryRoles?$select=id,displayName,roleTemplateId'

if ($RoleName) {
    $roles = @($roles | Where-Object { [string](Get-GraphValue -Item $_ -Key 'displayName') -like $RoleName })
    if ($roles.Count -eq 0) { throw "No activated role matches '$RoleName'. Run without -RoleName to see what exists." }
}

Write-Host "  $($roles.Count) role(s) with at least one assignment."

$rows = [System.Collections.Generic.List[object]]::new()
$groupCache = @{}

function Get-GroupMemberList {
    <# Members of a role-assignable group, cached because the same group tends to
       sit on several roles. #>
    param([Parameter(Mandatory)][string]$GroupId)

    if ($script:groupCache.ContainsKey($GroupId)) { return $script:groupCache[$GroupId] }

    $members = @()
    try {
        $members = @(Invoke-GraphPaged -Uri ("https://graph.microsoft.com/v1.0/groups/$GroupId/members" +
            "?`$select=id,displayName,userPrincipalName,accountEnabled,userType,onPremisesSyncEnabled&`$top=999"))
    }
    catch {
        Write-Warning "Could not read members of group ${GroupId}: $($_.Exception.Message)"
    }

    $script:groupCache[$GroupId] = $members
    return $members
}

function Add-AssignmentRow {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Role,
        [Parameter(Mandatory)][AllowEmptyString()][string]$TemplateId,
        [Parameter(Mandatory)][string]$AssignmentType,
        [Parameter(Mandatory)]$Principal,
        [string]$Via = 'Direct'
    )

    $kind = Get-PrincipalKind -Item $Principal
    $upn = [string](Get-GraphValue -Item $Principal -Key 'userPrincipalName')

    $script:rows.Add([pscustomobject]@{
        RoleName          = $Role
        RoleTemplateId    = $TemplateId
        AssignmentType    = $AssignmentType
        Via               = $Via
        PrincipalType     = $kind
        DisplayName       = [string](Get-GraphValue -Item $Principal -Key 'displayName')
        UserPrincipalName = $upn
        AccountEnabled    = Get-GraphValue -Item $Principal -Key 'accountEnabled'
        IsGuest           = ([string](Get-GraphValue -Item $Principal -Key 'userType') -eq 'Guest')
        SyncedFromOnPrem  = [bool](Get-GraphValue -Item $Principal -Key 'onPremisesSyncEnabled' -Default $false)
        PrincipalId       = [string](Get-GraphValue -Item $Principal -Key 'id')
    })
}

foreach ($role in $roles) {
    $id = [string](Get-GraphValue -Item $role -Key 'id')
    $name = [string](Get-GraphValue -Item $role -Key 'displayName')
    $template = [string](Get-GraphValue -Item $role -Key 'roleTemplateId')

    $members = Invoke-GraphPaged -Uri ("https://graph.microsoft.com/v1.0/directoryRoles/$id/members" +
        "?`$select=id,displayName,userPrincipalName,accountEnabled,userType,onPremisesSyncEnabled&`$top=999")

    foreach ($member in $members) {
        $kind = Get-PrincipalKind -Item $member

        if ($kind -eq 'Group' -and -not $SkipGroupMembers) {
            $groupId = [string](Get-GraphValue -Item $member -Key 'id')
            $groupName = [string](Get-GraphValue -Item $member -Key 'displayName')

            foreach ($inner in (Get-GroupMemberList -GroupId $groupId)) {
                Add-AssignmentRow -Role $name -TemplateId $template -AssignmentType 'Active' `
                    -Principal $inner -Via "Group: $groupName"
            }
            continue
        }

        Add-AssignmentRow -Role $name -TemplateId $template -AssignmentType 'Active' -Principal $member
    }
}

# ============================================================== PIM rows ====

if ($IncludeEligible) {
    Write-Host 'Fetching PIM-eligible assignments...' -ForegroundColor Cyan
    try {
        $eligible = Invoke-GraphPaged -Uri ('https://graph.microsoft.com/v1.0/roleManagement/directory/' +
            'roleEligibilityScheduleInstances?$expand=principal,roleDefinition&$top=999')

        foreach ($e in $eligible) {
            $definition = Get-GraphValue -Item $e -Key 'roleDefinition'
            $principal = Get-GraphValue -Item $e -Key 'principal'
            if ($null -eq $principal) { continue }

            $name = [string](Get-GraphValue -Item $definition -Key 'displayName')
            if ($RoleName -and $name -notlike $RoleName) { continue }

            Add-AssignmentRow -Role $name -TemplateId ([string](Get-GraphValue -Item $definition -Key 'templateId')) `
                -AssignmentType 'Eligible' -Principal $principal
        }

        Write-Host "  $($eligible.Count) eligible assignment(s)."
    }
    catch {
        Write-Warning ("PIM-eligible assignments could not be read: $($_.Exception.Message). " +
            'That endpoint needs Entra ID P2 and the RoleManagement.Read.Directory scope. Active assignments above are unaffected.')
    }
}

# ================================================================ summary ===

$sorted = @($rows | Sort-Object RoleName, AssignmentType, DisplayName)

$globals = @($sorted | Where-Object { $_.RoleName -eq 'Global Administrator' -and $_.AssignmentType -eq 'Active' })
$guests = @($sorted | Where-Object IsGuest)
$synced = @($sorted | Where-Object SyncedFromOnPrem)
$disabled = @($sorted | Where-Object { $_.PrincipalType -eq 'User' -and $_.AccountEnabled -eq $false })

Write-Host ''
Write-Host "Assignments  : $($sorted.Count) across $(@($sorted | Select-Object -ExpandProperty RoleName -Unique).Count) role(s)"
Write-Host "Global admins: $($globals.Count) active"

if ($CsvPath) {
    $sorted | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $CsvPath
    Write-Host "CSV          : $CsvPath" -ForegroundColor Green
}

Write-Host ''

# Microsoft's guidance is two to four permanent Global Administrators. One means
# nobody can help when that account is locked out.
if (-not $RoleName -or 'Global Administrator' -like $RoleName) {
    if ($globals.Count -lt 2) {
        Write-Warning 'Fewer than two active Global Administrators. Add a break-glass account before you need one.'
    }
    elseif ($globals.Count -gt 5) {
        Write-Warning "$($globals.Count) active Global Administrators. Most of them probably need a narrower role."
    }
}

if ($guests.Count -gt 0) { Write-Warning "$($guests.Count) admin assignment(s) sit on guest accounts." }
if ($disabled.Count -gt 0) { Write-Warning "$($disabled.Count) admin assignment(s) sit on disabled accounts. Disabled is not the same as removed." }
if ($synced.Count -gt 0) { Write-Warning "$($synced.Count) admin assignment(s) sit on accounts synced from Active Directory." }

return $sorted
