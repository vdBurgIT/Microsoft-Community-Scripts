# 🌍 Get-SpoSharingReport

The external sharing setting of every site, and the ones that sit above your
baseline.

## What it does

Reads every site collection through PnP, compares each `SharingCapability`
against the baseline you name, and returns the sites that are more open than it.
The tenant-level setting is printed first, plus a count per sharing level.

Nothing is changed.

## Why it exists

The tenant setting is a ceiling, not a rule. Each site carries its own sharing
capability, and a site created from a template, migrated from another tenant or
opened up for one project keeps whatever it was given. Nobody goes back and
closes it afterwards.

The SharePoint admin centre has a column for this, but it does not tell you which
sites are above the level you decided on, and it does not export.

## How to run

```powershell
Install-Module PnP.PowerShell -Scope CurrentUser

.\Get-SpoSharingReport.ps1 -TenantAdminUrl https://contoso-admin.sharepoint.com -ClientId $appId
.\Get-SpoSharingReport.ps1 -TenantAdminUrl https://contoso-admin.sharepoint.com -Baseline ExternalUserSharingOnly -CsvPath .\sharing.csv
.\Get-SpoSharingReport.ps1 -TenantAdminUrl https://contoso-admin.sharepoint.com -AllSites -IncludeOneDriveSites
```

Tighten a site afterwards with:

```powershell
Set-PnPTenantSite -Identity https://contoso.sharepoint.com/sites/Finance -SharingCapability ExternalUserSharingOnly
```

## Where it bites

**PnP.PowerShell needs your own app registration.** Since 9 September 2024 the
shared multi-tenant app is gone, so `-ClientId` is not optional. Register one
once with `Register-PnPEntraIDAppForInteractiveLogin`, then either pass
`-ClientId` or set the `ENTRAID_CLIENT_ID` environment variable and stop thinking
about it.

**`-Detailed` is not optional either.** Without it `Get-PnPTenantSite` returns
default values for several properties, including `SharingCapability`. The report
would be confidently wrong, so the script always passes it. That is also why the
run takes a while on a tenant with a lot of sites.

**The four levels in order, closed to open:** `Disabled`,
`ExistingExternalUserSharingOnly`, `ExternalUserSharingOnly`,
`ExternalUserAndGuestSharing`. Only the last one allows anonymous links. If
"anyone" links are your concern, set `-Baseline ExternalUserSharingOnly` and look
at what comes back.

**Tightening a site does not kill existing links.** Links that were already
created keep working. The setting governs what can be created from now on. Use
`Get-PnPFileSharingLink` or the sharing report in the admin centre if you need to
clean up what is already out there.

**OneDrive sites are off by default.** They have their own sharing capability and
are usually the ones nobody has ever looked at. `-IncludeOneDriveSites` adds
them, and adds a row per user, so expect the list to get long.

**Site-level settings cannot exceed the tenant setting.** If the tenant is set to
`ExternalUserSharingOnly`, a site set to `ExternalUserAndGuestSharing` does not
actually allow anonymous links. It still shows up here, and it still matters: the
day someone loosens the tenant setting, that site opens up with it.
