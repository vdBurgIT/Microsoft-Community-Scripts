#Requires -Version 5.1

<#
.SYNOPSIS
    Removes preinstalled Windows inbox apps and OEM bloatware, for the current
    user and for every future user of the device.

.DESCRIPTION
    Candy Crush on a company laptop is a support ticket waiting to happen. This
    removes a curated list of consumer apps in two places: the installed packages
    on the device, and the provisioned packages that would otherwise reinstall
    for the next user who signs in.

    Removing only the installed package is the classic mistake. The app comes
    back for user number two and you get to explain why.

    Deploy through Intune as a device-scoped platform script, or run it during
    imaging.

.PARAMETER AppName
    Package names to remove. Wildcards are matched against PackageName, so
    'king.com.*' catches the whole Candy Crush family.

.PARAMETER AdditionalApp
    Extra packages to remove on top of the default list, so you do not have to
    restate the entire thing to add one OEM app.

.PARAMETER SkipProvisioned
    Only remove installed packages, leave the provisioned ones. New users on the
    device will get the apps back.

.EXAMPLE
    .\Remove-InboxApp.ps1

.EXAMPLE
    .\Remove-InboxApp.ps1 -WhatIf

.EXAMPLE
    .\Remove-InboxApp.ps1 -AdditionalApp 'Dell.Optimizer', 'RealtekSemiconductorCorp.RealtekAudioControl'

.NOTES
    Microsoft.DesktopAppInstaller is deliberately NOT in the default list. That
    package is winget. Removing it is a popular way to break your own app
    deployment tooling.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string[]]$AppName = @(
        # Microsoft consumer apps
        '*3dbuilder*', '*windowsalarms*', '*windowscommunicationsapps*', '*officehub*'
        '*skypeapp*', '*getstarted*', '*zunemusic*', '*windowsmaps*'
        '*solitairecollection*', '*bingfinance*', '*zunevideo*', '*bingnews*'
        '*onenote*', '*bingsports*', '*soundrecorder*', '*bingweather*'
        'Microsoft.BingFoodAndDrink', 'Microsoft.BingTravel', 'Microsoft.BingHealthAndFitness'
        'Microsoft.WindowsReadingList', 'Microsoft.Microsoft3DViewer', 'Microsoft.MicrosoftStickyNotes'
        'Microsoft.Wallet', 'Microsoft.FreshPaint', 'Microsoft.Office.Sway'
        'Microsoft.Advertising.Xaml', 'Microsoft.Getstarted'

        # Xbox, minus the gaming services the OS actually needs
        '*xboxapp*', 'Microsoft.XboxGameOverlay', 'Microsoft.XboxIdentityProvider'
        'Microsoft.XboxSpeechToTextOverlay'

        # Third party and OEM
        'king.com.*', 'ClearChannelRadioDigital.iHeartRadio', '4DF9E0F8.Netflix'
        '6Wunderkinder.Wunderlist', 'Drawboard.DrawboardPDF', '2FE3CB00.PicsArt-PhotoStudio'
        'D52A8D61.FarmVille2CountryEscape', 'TuneIn.TuneInRadio', 'GAMELOFTSA.Asphalt8Airborne'
        'TheNewYorkTimes.NYTCrossword', 'DB6EA5DB.CyberLinkMediaSuiteEssentials'
        'Facebook.Facebook', 'flaregamesGmbH.RoyalRevolt2', 'Playtika.CaesarsSlotsFreeCasino'
        'A278AB0D.MarchofEmpires', 'KeeperSecurityInc.Keeper', 'ThumbmunkeysLtd.PhototasticCollage'
        'XINGAG.XING', '89006A2E.AutodeskSketchBook', 'D5EA27B7.Duolingo-LearnLanguagesforFree'
        '46928bounde.EclipseManager', 'ActiproSoftwareLLC.562882FEEB491', 'HP.ePrint.HPePrint'
        'AD2F1837.HPJumpStart', 'AdobeSystemsIncorporated.AdobePhotoshopExpress'
    ),

    [string[]]$AdditionalApp = @(),

    [switch]$SkipProvisioned
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$targets = @($AppName) + @($AdditionalApp)
$results = [System.Collections.Generic.List[object]]::new()

foreach ($target in $targets) {

    foreach ($pkg in @(Get-AppxPackage -Name $target -AllUsers -ErrorAction SilentlyContinue)) {
        if ($PSCmdlet.ShouldProcess($pkg.PackageFullName, 'Remove installed package')) {
            try {
                Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction Stop
                $results.Add([pscustomobject]@{ Package = $pkg.Name; Scope = 'Installed'; Result = 'Removed'; Error = $null })
            }
            catch {
                $results.Add([pscustomobject]@{ Package = $pkg.Name; Scope = 'Installed'; Result = 'Failed'; Error = $_.Exception.Message })
            }
        }
    }

    if ($SkipProvisioned) { continue }

    # Provisioned packages are what gets installed for the NEXT user.
    foreach ($prov in @(Get-AppxProvisionedPackage -Online | Where-Object DisplayName -like $target)) {
        if ($PSCmdlet.ShouldProcess($prov.DisplayName, 'Remove provisioned package')) {
            try {
                Remove-AppxProvisionedPackage -Online -PackageName $prov.PackageName -ErrorAction Stop | Out-Null
                $results.Add([pscustomobject]@{ Package = $prov.DisplayName; Scope = 'Provisioned'; Result = 'Removed'; Error = $null })
            }
            catch {
                $results.Add([pscustomobject]@{ Package = $prov.DisplayName; Scope = 'Provisioned'; Result = 'Failed'; Error = $_.Exception.Message })
            }
        }
    }
}

$removed = @($results | Where-Object Result -eq 'Removed').Count
$failed = @($results | Where-Object Result -eq 'Failed').Count
Write-Host "Packages removed: $removed. Failed: $failed."

if ($failed -gt 0) {
    Write-Warning 'Some packages could not be removed. System-critical packages refuse removal by design; that is expected noise, not a broken run.'
}

return $results
