# 💳 Disable-SelfServicePurchase

Stops users buying their own Microsoft licences and attaching them to your
tenant.

## What it does

Walks every product and every third-party offer type under the
`AllowSelfServicePurchase` policy and sets them to `Disabled`. Anything already
correct is reported as `NoChange` and skipped, so it is safe to run on a
schedule.

Two categories, and both matter:

- **Microsoft products.** Power BI Pro, Project Plan 3, Visio, Microsoft 365
  Copilot, Teams Premium, Windows 365, Clipchamp Premium, Python in Excel.
- **Third-party offer types.** SaaS, Power BI Visuals, Dynamics 365 Dataverse
  Apps, Dynamics 365 Business Central.

Plenty of scripts out there only do the first category. That leaves third-party
SaaS, the broadest one, still open.

## Why it exists

Self-service purchase is on by default. Any user can put a Power BI Pro licence
on a personal credit card and have it land in your tenant. You find out from a
licensing report, or when the trial expires and someone asks why their dashboard
stopped working.

There is no tenant-wide off switch. Microsoft's own documentation is blunt about
it:

> Self-service purchases and trials can't be completely turned off at the tenant
> level with a single command. The AllowSelfServicePurchase policy is managed on
> a per-product basis. By default, all new products are set to allow users to
> make a self-service purchase.

That last sentence is the reason to schedule this. Every product Microsoft adds
arrives enabled, so a one-off run during onboarding goes stale.

## How to run

```powershell
Install-Module MSCommerce -Scope CurrentUser
Connect-MSCommerce

.\Disable-SelfServicePurchase.ps1
.\Disable-SelfServicePurchase.ps1 -WhatIf
```

Block purchases but keep the free trials that need no payment method (Teams
Exploratory, Viva Goals, Planner Plan 1, Visio Plan 1, Purview Discovery):

```powershell
.\Disable-SelfServicePurchase.ps1 -Value OnlyTrialsWithoutPaymentMethod
```

Microsoft products only:

```powershell
.\Disable-SelfServicePurchase.ps1 -SkipOfferType
```

## There is a UI now

Since September 2024 you can also manage this in the Microsoft 365 admin center,
under **Settings → Org settings → Self-service trials and purchases**. If you run
one tenant, click it there and skip this script.

The script earns its keep when you run many tenants, want it in a runbook, or
want it scheduled so new products do not quietly arrive enabled.

## Where it bites

**Existing purchases are untouched.** This governs what happens from now on.
Licences already bought keep running until they expire or you remove them in the
admin centre. Turning the policy off does not claw anything back.

**SaaS bought through the Azure portal is not covered.** The
`AllowSelfServicePurchase` policy does not apply to SaaS subscriptions acquired
in the Azure portal. If that is a concern it needs a different control, not this
one.

**Billing Administrator is enough.** You do not need Global Administrator, so do
not use it.

**Connect first.** The script installs the module if it is missing but cannot
sign in for you. Without a session you get a clear error pointing at
`Connect-MSCommerce` rather than a confusing null reference.

**The module is Windows-only.** Microsoft documents Windows 10 or later as a
requirement. It will not help you from a Linux runner.

**Module version matters.** Every MSCommerce release before 17 April 2024 stopped
working entirely. Version 2 changed the update parameter from a boolean
`-Enabled` to `-Value` with three states. The script detects which shape the
installed module expects and adapts, but if you see odd behaviour, run
`Update-Module MSCommerce` first.

**The module install can fail on a signature check.** You may get this:

```
Install-Package: The module 'MSCommerce' cannot be installed or updated
because the authenticode signature of the file 'MSCommerce.psd1' is not valid.
```

PowerShellGet compares the publisher signature against a copy of the module that
is already installed, and refuses when they do not match. It is not specific to
MSCommerce; the same error shows up for MicrosoftTeams, PnP.PowerShell and
others.

Look for the copy that is in the way first:

```powershell
Get-Module MSCommerce -ListAvailable | Select-Object Name, Version, ModuleBase
```

An old copy under `C:\Program Files\WindowsPowerShell\Modules` is almost always
the culprit. Removing it is cleaner than skipping the check. If you cannot, run
the script with `-SkipPublisherCheck`, and know that you are switching off a real
signature validation to do it.

**Users still see the option in some places.** The policy blocks the purchase, it
does not always hide the button. Expect the occasional "why can't I buy this"
ticket. That is the feature working.
