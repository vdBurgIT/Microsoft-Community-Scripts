# 🚀 Register-AutopilotDevice

Registers the device it runs on into Windows Autopilot through the Graph API. No
CSV, no USB stick, no technician.

## What it does

Reads the serial number and the Autopilot hardware hash from the local machine,
gets an app-only token, and posts an `importedWindowsAutopilotDeviceIdentity` to
Graph.

Ideal when a machine is already managed by an RMM but was never imported into
Autopilot: push the script, walk away.

## Why not the CSV route

Collecting hashes into a CSV means someone has to collect the CSV. This skips
the file entirely. If you would rather batch the import (or you do not want an
app registration on every device), use
[Export-AutopilotHash](../Export-AutopilotHash/) instead, which drops the CSV in
a blob container.

## How to run

Credentials come from parameters or environment variables, which is how an RMM
would supply them:

```powershell
$env:AUTOPILOT_TENANT_ID     = '<tenant id>'
$env:AUTOPILOT_CLIENT_ID     = '<app id>'
$env:AUTOPILOT_CLIENT_SECRET = '<secret>'

.\Register-AutopilotDevice.ps1
```

Or explicitly, with a group tag:

```powershell
.\Register-AutopilotDevice.ps1 -TenantId $tid -ClientId $cid `
    -ClientSecret (Read-Host -AsSecureString) -GroupTag 'Kiosk'
```

## Setup

App registration with the **application** permission
`DeviceManagementServiceConfig.ReadWrite.All`, admin consent granted.

## Where it bites

**Import is asynchronous.** A successful post means Intune accepted the device
for import, not that it finished. The device shows up under **Devices →
Enrolment → Devices** a few minutes later. If you script around this, poll the
import status; do not assume HTTP 200 means done.

**Needs elevation and real hardware.** The hardware hash comes from the
`MDM_DevDetail_Ext01` WMI class. Standard users cannot read it, and most virtual
machines do not expose it at all. The script fails with that message rather than
posting a device with an empty hash.

**A client secret on an endpoint is a client secret on an endpoint.** Anything
running as SYSTEM on that machine can read it. Scope the app registration to the
one permission it needs, set a short expiry, and rotate it. If your RMM supports
per-run secrets, use that instead of writing it into a variable.

**Already-imported devices return HTTP 409.** The script treats that as success
and says so, so re-running across a fleet does not produce a wall of red.

**The old version of this script used `productKey` for the hardware ID.** That
field is for the OA3 product key, not the hash, and Autopilot quietly ignored it.
This version posts `hardwareIdentifier` with `importedDeviceIdentityType` set,
which is what the API actually wants.
