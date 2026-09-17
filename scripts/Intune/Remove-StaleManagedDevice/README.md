# 📱 Remove-StaleManagedDevice

Clears out the Intune records for devices that stopped checking in months ago.

## What it does

Selects managed devices on `lastSyncDateTime` and either deletes the Intune
record or retires the device. Supports `-WhatIf`, has a `-ReportOnly` mode, and
stops at `-MaxToRemove`.

`-CsvPath` is worth using. After a delete the record is gone, and the CSV is your
only copy of the serial numbers.

## Why it exists

Reimaged laptops, traded-in phones and deleted test VMs all leave a record
behind. They inflate the device count, sit there as non-compliant, and make the
compliance percentage on the dashboard mean nothing. The portal filters on
"last check-in" but deletes one device at a time.

## How to run

```powershell
./Remove-StaleManagedDevice.ps1 -ReportOnly
./Remove-StaleManagedDevice.ps1 -DaysInactive 180 -WhatIf
./Remove-StaleManagedDevice.ps1 -DaysInactive 180 -OperatingSystem Windows -CsvPath ./removed-devices.csv
./Remove-StaleManagedDevice.ps1 -Action Retire -DaysInactive 120
```

Graph scopes: `DeviceManagementManagedDevices.ReadWrite.All` for Delete, and
`DeviceManagementManagedDevices.PrivilegedOperations.All` for Retire.

## Where it bites

**Three objects, one device.** Intune, Entra ID and Windows Autopilot each hold
their own record. This script only touches the Intune one. The Entra device
object stays, and so does the Autopilot registration, which is usually what you
want: delete the Autopilot record and the hardware can no longer be reimaged into
your tenant.

**Delete and Retire are not the same thing.** Delete removes the record and sends
nothing to the device. Retire unenrols it and pulls company data if it ever comes
back online. For hardware that no longer exists, Delete. For a device you are not
sure about, Retire.

**A deleted record comes straight back if the device is alive.** Delete the
record for a laptop that was just switched off for a month, and it re-enrols on
the next check-in with a new enrolment date. No harm done, but your device count
does not drop the way you expected.

**Devices with no sync date are skipped.** Those never finished enrolment. There
is no date to judge them by, so the script leaves them alone rather than guessing.

**Retire needs the privileged scope.** `DeviceManagementManagedDevices.PrivilegedOperations.All`
is a separate consent from the read-write one. The script asks for it only when
you actually use `-Action Retire`.

**Autopilot devices are the awkward case.** Retiring one leaves the Autopilot
registration in place, so it re-enrols at the next OOBE. That is correct for a
device going to a new employee and wrong for one going to a recycler.
