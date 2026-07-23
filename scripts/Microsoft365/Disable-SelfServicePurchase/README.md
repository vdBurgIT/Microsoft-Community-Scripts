# 💳 Disable-SelfServicePurchase

Stops users buying their own Microsoft licences and attaching them to your
tenant.

## What it does

Walks every product under the `AllowSelfServicePurchase` commerce policy and
switches it off. Products already disabled are reported and skipped, so it is
safe to run repeatedly.

## Why it exists

Self-service purchase is on by default. Any user can put a Power BI Pro or
Project licence on a personal credit card and have it land in your tenant. You
find out from a licensing report, or when the trial expires and someone asks why
their dashboard stopped working.

Microsoft also adds new products over time, each one enabled by default. Turning
it off once is not enough, which is the actual reason this is a script and not a
checkbox you tick during onboarding.

## How to run

```powershell
Install-Module MSCommerce -Scope CurrentUser
Connect-MSCommerce

.\Disable-SelfServicePurchase.ps1
.\Disable-SelfServicePurchase.ps1 -WhatIf
```

Worth scheduling monthly. New product, new default, new surprise.

## Where it bites

**Connect first.** The script installs the MSCommerce module if it is missing,
but it cannot sign in for you. Without a session you get a clear error pointing
at `Connect-MSCommerce` instead of a confusing null reference.

**Billing Administrator is enough.** You do not need Global Administrator for
this, and you should not use it if you do not have to.

**This does not refund or remove existing purchases.** It stops new ones. Anything
already bought stays until it expires or you remove it in the admin centre.

**Users still see the option in some surfaces.** Turning the policy off blocks
the purchase, it does not always hide the button. Expect the occasional "why
can't I buy this" ticket, which is the point.
