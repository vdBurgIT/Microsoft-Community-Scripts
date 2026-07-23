#Requires -Version 5.1

<#
.SYNOPSIS
    Creates inbound firewall rules so Microsoft Teams calls stop dropping to
    audio-only on Windows devices.

.DESCRIPTION
    Windows Firewall prompts a standard user for permission the first time Teams
    wants to listen for incoming media. Users cannot approve that prompt without
    admin rights, so it gets dismissed, and every call after that degrades.

    This creates the rules up front, as SYSTEM, before anyone sees a prompt.

    Deploy through Intune as a device-scoped platform script, or run it in your
    RMM. Existing rules with the same display name are left alone, so running it
    twice is harmless.

.PARAMETER RuleNamePrefix
    Display name prefix for every rule this creates. Also what the script looks
    for when deciding whether a rule already exists.

.PARAMETER ProgramPath
    Path to the Teams executable. Defaults to the classic per-machine install.
    New Teams lives under WindowsApps, see the README for that case.

.PARAMETER Port
    UDP/TCP ports to open. Defaults to the 3478-3481 media range.

.EXAMPLE
    .\Add-TeamsFirewallRule.ps1

.EXAMPLE
    # New Teams, resolved per machine
    $p = (Get-AppxPackage MSTeams).InstallLocation + '\ms-teams.exe'
    .\Add-TeamsFirewallRule.ps1 -ProgramPath $p

.EXAMPLE
    .\Add-TeamsFirewallRule.ps1 -WhatIf
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$RuleNamePrefix = 'Allow Microsoft Teams Video Calling',

    [string]$ProgramPath = "$env:ProgramFiles (x86)\Microsoft\Teams\current\Teams.exe",

    [int[]]$Port = @(3478, 3479, 3480, 3481)
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not (Test-Path -LiteralPath $ProgramPath)) {
    Write-Warning "Teams was not found at '$ProgramPath'. Rules are still created; they simply do nothing until the executable exists at that path."
}

$results = [System.Collections.Generic.List[object]]::new()

function Add-RuleIfMissing {
    param(
        [Parameter(Mandatory)][string]$DisplayName,
        [Parameter(Mandatory)][hashtable]$RuleParams
    )

    if (Get-NetFirewallRule -DisplayName $DisplayName -ErrorAction SilentlyContinue) {
        $results.Add([pscustomobject]@{ Rule = $DisplayName; Action = 'AlreadyExists' })
        return
    }

    if ($PSCmdlet.ShouldProcess($DisplayName, 'Create inbound firewall rule')) {
        New-NetFirewallRule @RuleParams -DisplayName $DisplayName | Out-Null
        $results.Add([pscustomobject]@{ Rule = $DisplayName; Action = 'Created' })
    }
}

foreach ($protocol in 'TCP', 'UDP') {
    foreach ($p in $Port) {
        Add-RuleIfMissing -DisplayName "$RuleNamePrefix - $protocol Port $p" -RuleParams @{
            Direction = 'Inbound'
            Protocol  = $protocol
            LocalPort = $p
            Program   = $ProgramPath
            Action    = 'Allow'
        }
    }
}

Add-RuleIfMissing -DisplayName "$RuleNamePrefix - Program" -RuleParams @{
    Direction = 'Inbound'
    Program   = $ProgramPath
    Action    = 'Allow'
}

$created = @($results | Where-Object Action -eq 'Created').Count
Write-Host "Firewall rules created: $created, already present: $($results.Count - $created)"

return $results
