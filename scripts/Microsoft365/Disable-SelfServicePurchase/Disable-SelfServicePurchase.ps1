#Requires -Version 5.1

<#
.SYNOPSIS
    Turns off self-service purchase for every product in the tenant, so users
    cannot buy their own licences on the company card.

.DESCRIPTION
    Self-service purchase lets any user buy a Power BI or Project licence with a
    personal credit card and attach it to your tenant. You find out when the
    licence shows up in a report, or when someone asks why their trial expired.

    Microsoft enables it by default and adds new products over time, each one
    enabled again. Running this after every product announcement is less fun than
    it sounds, so schedule it.

.PARAMETER PolicyId
    Commerce policy to switch off. AllowSelfServicePurchase is the one you want.

.PARAMETER ProductId
    Limit to specific product IDs. Leave empty to cover every product.

.EXAMPLE
    Connect-MSCommerce
    .\Disable-SelfServicePurchase.ps1

.EXAMPLE
    # See what would change first
    .\Disable-SelfServicePurchase.ps1 -WhatIf

.NOTES
    Needs the MSCommerce module and a Billing Administrator or Global
    Administrator. Connect with Connect-MSCommerce before running, or let the
    script prompt you.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$PolicyId = 'AllowSelfServicePurchase',

    [string[]]$ProductId
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not (Get-Module -ListAvailable -Name MSCommerce)) {
    Write-Host 'Installing the MSCommerce module...' -ForegroundColor Yellow
    Install-Module -Name MSCommerce -Scope CurrentUser -Force -AllowClobber
}
Import-Module MSCommerce -ErrorAction Stop

try {
    $policies = @(Get-MSCommerceProductPolicies -PolicyId $PolicyId -ErrorAction Stop)
}
catch {
    throw "Could not read commerce policies. Run Connect-MSCommerce first and sign in as a Billing or Global Administrator. Original error: $($_.Exception.Message)"
}

if ($ProductId) {
    $policies = @($policies | Where-Object { $ProductId -contains $_.ProductId })
}

$results = [System.Collections.Generic.List[object]]::new()

foreach ($policy in $policies) {

    if (-not $policy.PolicyValue) {
        $results.Add([pscustomobject]@{
                ProductId   = $policy.ProductId
                ProductName = $policy.ProductName
                Action      = 'AlreadyDisabled'
            })
        continue
    }

    if ($PSCmdlet.ShouldProcess("$($policy.ProductName) ($($policy.ProductId))", 'Disable self-service purchase')) {
        try {
            Update-MSCommerceProductPolicy -PolicyId $PolicyId -ProductId $policy.ProductId -Enabled $false | Out-Null
            $results.Add([pscustomobject]@{
                    ProductId   = $policy.ProductId
                    ProductName = $policy.ProductName
                    Action      = 'Disabled'
                })
        }
        catch {
            $results.Add([pscustomobject]@{
                    ProductId   = $policy.ProductId
                    ProductName = $policy.ProductName
                    Action      = "Failed: $($_.Exception.Message)"
                })
            Write-Warning "$($policy.ProductName): $($_.Exception.Message)"
        }
    }
}

$disabled = @($results | Where-Object Action -eq 'Disabled').Count
Write-Host "Products checked: $($results.Count). Newly disabled: $disabled."

return $results
