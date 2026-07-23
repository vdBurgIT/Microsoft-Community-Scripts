#Requires -Version 5.1

<#
.SYNOPSIS
    Turns off self-service purchase for every Microsoft product and third-party
    offer type in the tenant, so users cannot buy their own licences on a
    personal credit card.

.DESCRIPTION
    Self-service purchase is on by default, and every product Microsoft adds
    later arrives enabled again. There is no single tenant-wide switch: the
    policy is per product, which is exactly why this is a script and not a
    checkbox you tick once during onboarding.

    Covers both halves of the policy:

    - Microsoft products (Power BI Pro, Project, Visio, Copilot, Teams Premium,
      Windows 365 and friends)
    - Third-party offer types (SaaS, Power BI Visuals, Dynamics 365 Dataverse
      Apps, Dynamics 365 Business Central)

    Skipping the second half is easy to do and leaves the largest category,
    third-party SaaS, wide open.

.PARAMETER Value
    Target state. Disabled blocks purchases and trials. OnlyTrialsWithoutPayment
    Method blocks purchases but still allows the free trials that need no card,
    which is a reasonable middle ground for Teams Exploratory and Viva Goals.
    Enabled turns it back on.

.PARAMETER PolicyId
    Commerce policy to act on. AllowSelfServicePurchase is the one you want.

.PARAMETER ProductId
    Limit to specific product IDs. Leave empty to cover every product.

.PARAMETER SkipOfferType
    Only touch Microsoft products, leave third-party offer types alone.

.PARAMETER SkipPublisherCheck
    Bypass PowerShellGet's publisher signature check when installing MSCommerce.
    Only reach for this if the install fails with an authenticode error.

.EXAMPLE
    Connect-MSCommerce
    .\Disable-SelfServicePurchase.ps1

.EXAMPLE
    # See what would change before changing it
    .\Disable-SelfServicePurchase.ps1 -WhatIf

.EXAMPLE
    # Block purchases but keep the no-payment-method trials available
    .\Disable-SelfServicePurchase.ps1 -Value OnlyTrialsWithoutPaymentMethod

.NOTES
    Needs the MSCommerce module and a Billing Administrator or Global
    Administrator. Global Reader is enough to read the policies but not to
    change them.

    Existing purchases and trials are not affected. This only governs what
    happens from now on.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('Disabled', 'OnlyTrialsWithoutPaymentMethod', 'Enabled')]
    [string]$Value = 'Disabled',

    [string]$PolicyId = 'AllowSelfServicePurchase',

    [string[]]$ProductId,

    [switch]$SkipOfferType,

    # Bypass PowerShellGet's publisher signature check when installing the
    # module. Only needed if the install fails on an authenticode error.
    [switch]$SkipPublisherCheck
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ------------------------------------------------------------------ setup ---

if (-not (Get-Module -ListAvailable -Name MSCommerce)) {
    Write-Host 'Installing the MSCommerce module...' -ForegroundColor Yellow

    $installSplat = @{
        Name        = 'MSCommerce'
        Scope       = 'CurrentUser'
        Force       = $true
        AllowClobber = $true
        ErrorAction = 'Stop'
    }
    if ($SkipPublisherCheck) { $installSplat.SkipPublisherCheck = $true }

    try {
        Install-Module @installSplat
    }
    catch {
        # PowerShellGet refuses the install when the catalog signature does not
        # validate against an already-present copy of the module. Skipping that
        # check is a real security decision, so surface it instead of doing it
        # quietly.
        if ($_.Exception.Message -match 'authenticode|publisher') {
            throw @'
The MSCommerce module failed its signature check.

This usually means another copy is already installed, signed by a different
publisher. Check for it first:

    Get-Module MSCommerce -ListAvailable | Select-Object Name, Version, ModuleBase

If an old copy sits under Program Files, remove that and try again. To install
anyway and skip the publisher check, re-run this script with -SkipPublisherCheck.
'@
        }
        throw
    }
}
Import-Module MSCommerce -ErrorAction Stop

# The module changed its update parameter between major versions. v2 documents
# -Value with three states; older builds only understood a boolean -Enabled.
# Detect it rather than guess, because guessing wrong fails silently per product.
$updateParams = (Get-Command Update-MSCommerceProductPolicy).Parameters
$useValueParam = $updateParams.ContainsKey('Value')

if (-not $useValueParam) {
    if ($Value -eq 'OnlyTrialsWithoutPaymentMethod') {
        throw 'The installed MSCommerce module is too old for OnlyTrialsWithoutPaymentMethod. Run Update-Module MSCommerce and try again.'
    }
    Write-Warning 'Installed MSCommerce module has no -Value parameter, falling back to the legacy -Enabled switch. Update-Module MSCommerce is recommended.'
}

$enabledEquivalent = $Value -eq 'Enabled'

function Invoke-PolicyUpdate {
    <# One place that knows which parameter shape the installed module wants. #>
    param([hashtable]$Target)

    if ($useValueParam) {
        Update-MSCommerceProductPolicy @Target -PolicyId $PolicyId -Value $Value | Out-Null
    }
    else {
        Update-MSCommerceProductPolicy @Target -PolicyId $PolicyId -Enabled $enabledEquivalent | Out-Null
    }
}

$results = [System.Collections.Generic.List[object]]::new()

# ------------------------------------------------------- Microsoft products ---

try {
    $products = @(Get-MSCommerceProductPolicies -PolicyId $PolicyId -ErrorAction Stop)
}
catch {
    throw "Could not read commerce policies. Run Connect-MSCommerce first and sign in as a Billing or Global Administrator. Original error: $($_.Exception.Message)"
}

if ($ProductId) {
    $products = @($products | Where-Object { $ProductId -contains $_.ProductId })
}

Write-Host "Microsoft products in scope: $($products.Count)"

foreach ($product in $products) {

    # PolicyValue is a string ('Enabled' / 'Disabled' / ...), not a boolean.
    # Treating it as one is why an earlier version of this script reported every
    # product as needing a change on every run.
    if ("$($product.PolicyValue)" -eq $Value) {
        $results.Add([pscustomobject]@{
                Scope   = 'Product'
                Name    = $product.ProductName
                Id      = $product.ProductId
                Was     = $product.PolicyValue
                Action  = 'NoChange'
            })
        continue
    }

    if ($PSCmdlet.ShouldProcess("$($product.ProductName) ($($product.ProductId))", "Set self-service purchase to $Value")) {
        try {
            Invoke-PolicyUpdate -Target @{ ProductId = $product.ProductId }
            $results.Add([pscustomobject]@{
                    Scope  = 'Product'
                    Name   = $product.ProductName
                    Id     = $product.ProductId
                    Was    = $product.PolicyValue
                    Action = 'Changed'
                })
        }
        catch {
            $results.Add([pscustomobject]@{
                    Scope  = 'Product'
                    Name   = $product.ProductName
                    Id     = $product.ProductId
                    Was    = $product.PolicyValue
                    Action = "Failed: $($_.Exception.Message)"
                })
            Write-Warning "$($product.ProductName): $($_.Exception.Message)"
        }
    }
}

# ---------------------------------------------------- third-party offer types ---

if (-not $SkipOfferType -and -not $ProductId) {

    $offerTypes = @()
    try {
        $offerTypes = @(Get-MSCommerceProductPolicies -PolicyId $PolicyId -Scope OfferType -ErrorAction Stop)
    }
    catch {
        Write-Warning "Could not read third-party offer types: $($_.Exception.Message). Microsoft products were still processed."
    }

    Write-Host "Third-party offer types in scope: $($offerTypes.Count)"

    foreach ($offer in $offerTypes) {

        $offerId = if ($offer.PSObject.Properties.Name -contains 'OfferType') { $offer.OfferType } else { $offer.ProductId }
        $offerName = if ($offer.PSObject.Properties.Name -contains 'ProductName') { $offer.ProductName } else { $offerId }

        if ("$($offer.PolicyValue)" -eq $Value) {
            $results.Add([pscustomobject]@{
                    Scope  = 'OfferType'
                    Name   = $offerName
                    Id     = $offerId
                    Was    = $offer.PolicyValue
                    Action = 'NoChange'
                })
            continue
        }

        if ($PSCmdlet.ShouldProcess("$offerName ($offerId)", "Set self-service purchase to $Value")) {
            try {
                Invoke-PolicyUpdate -Target @{ OfferType = $offerId }
                $results.Add([pscustomobject]@{
                        Scope  = 'OfferType'
                        Name   = $offerName
                        Id     = $offerId
                        Was    = $offer.PolicyValue
                        Action = 'Changed'
                    })
            }
            catch {
                $results.Add([pscustomobject]@{
                        Scope  = 'OfferType'
                        Name   = $offerName
                        Id     = $offerId
                        Was    = $offer.PolicyValue
                        Action = "Failed: $($_.Exception.Message)"
                    })
                Write-Warning "${offerName}: $($_.Exception.Message)"
            }
        }
    }
}

# ----------------------------------------------------------------- summary ---

$changed = @($results | Where-Object Action -eq 'Changed').Count
$failed = @($results | Where-Object { $_.Action -like 'Failed*' }).Count

Write-Host ''
Write-Host "Checked: $($results.Count). Changed: $changed. Already correct: $(@($results | Where-Object Action -eq 'NoChange').Count). Failed: $failed."

if ($failed -gt 0) {
    Write-Warning 'Some policies could not be updated. Confirm you are signed in as Billing or Global Administrator.'
}

return $results
