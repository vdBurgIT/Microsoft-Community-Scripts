# 📤 Export-AutopilotHash

Collects the Autopilot hardware hash on a device and uploads the CSV to an Azure
Blob Storage container.

## What it does

Downloads AzCopy, installs `Get-WindowsAutopilotInfo` from the PowerShell
Gallery, generates the CSV, uploads it with a SAS URL, then deletes everything it
created.

You end up with one CSV per machine in a container, ready for a bulk import into
Intune whenever it suits you.

## Why this instead of direct registration

No app registration on the endpoint. The device only holds a SAS URL scoped to
one container, not credentials that can talk to Graph.

The trade-off is that nothing is registered until you do the import. If you want
devices to land in Autopilot on their own, use
[Register-AutopilotDevice](../Register-AutopilotDevice/).

## How to run

```powershell
$env:SasURL = 'https://account.blob.core.windows.net/hashes?sv=...'
.\Export-AutopilotHash.ps1
```

Or pass it directly:

```powershell
.\Export-AutopilotHash.ps1 -SasUrl $url -FileNamePrefix 'HQ_'
```

The `SasURL` environment variable name is what Tactical RMM and most other RMMs
use for run-scoped variables.

## Where it bites

**The SAS URL is a bearer credential.** Anyone who has it can write to that
container. Scope it to write-only (no list, no read), give it a short expiry, and
rotate it. A write-only SAS also means a compromised endpoint cannot read other
machines' hashes back out.

**The CSV is deleted afterwards, on purpose.** A hardware hash left on disk is
an Autopilot registration waiting to be hijacked by whoever finds it. The cleanup
runs in a `finally` block, so it also happens when the upload fails.

**Needs elevation and physical hardware.** `Get-WindowsAutopilotInfo` cannot read
the hash as a standard user, and virtual machines generally do not have one.

**It downloads AzCopy on every run.** Fine for a one-off during provisioning,
wasteful if you schedule it daily. There is no caching by design: a stale AzCopy
in `%TEMP%` is a worse problem than a download.

**AzCopy exit codes are checked.** Earlier versions of this script ignored them
and reported success on a failed upload. If the SAS expired, you now get a
useful error instead of a silent gap in your container.
