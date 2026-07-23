#Requires -Version 5.1

<#
.SYNOPSIS
    Registers the device it runs on into Windows Autopilot, straight through the
    Graph API.

.DESCRIPTION
    Handy when the machine is already managed by an RMM but was never imported
    into Autopilot. No CSV to collect, no hardware hash to email around, no
    technician plugging in a USB stick.

    The script reads the serial number and hardware hash locally, then posts an
    importedWindowsAutopilotDeviceIdentity to Graph using client credentials.

    Import is asynchronous. A successful post means Intune accepted the device
    for import, not that the import finished. Check
    Devices > Enrolment > Devices in Intune a few minutes later.

.PARAMETER TenantId
    Directory (tenant) ID of the app registration. Falls back to the
    AUTOPILOT_TENANT_ID environment variable.

.PARAMETER ClientId
    Application (client) ID. Falls back to AUTOPILOT_CLIENT_ID.

.PARAMETER ClientSecret
    Client secret, as a SecureString. Falls back to AUTOPILOT_CLIENT_SECRET,
    which is how you would pass it from an RMM environment variable.

.PARAMETER GroupTag
    Optional group tag, written to the orderIdentifier field. Useful if you drive
    Autopilot profile assignment off dynamic groups.

.PARAMETER AssignedUser
    Optional UPN to assign the device to during import.

.EXAMPLE
    # Credentials from RMM environment variables
    .\Register-AutopilotDevice.ps1

.EXAMPLE
    .\Register-AutopilotDevice.ps1 -TenantId $tid -ClientId $cid `
        -ClientSecret (Read-Host -AsSecureString) -GroupTag 'Kiosk'

.NOTES
    App registration needs the application permission
    DeviceManagementServiceConfig.ReadWrite.All with admin consent granted.

    The hardware hash comes from WMI and requires an elevated session.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$TenantId = $env:AUTOPILOT_TENANT_ID,

    [string]$ClientId = $env:AUTOPILOT_CLIENT_ID,

    [securestring]$ClientSecret,

    [string]$GroupTag,

    [string]$AssignedUser
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ----------------------------------------------------------------- input ---

if (-not $ClientSecret -and $env:AUTOPILOT_CLIENT_SECRET) {
    $ClientSecret = ConvertTo-SecureString $env:AUTOPILOT_CLIENT_SECRET -AsPlainText -Force
}

foreach ($required in @{ TenantId = $TenantId; ClientId = $ClientId }.GetEnumerator()) {
    if ([string]::IsNullOrWhiteSpace($required.Value)) {
        throw "$($required.Key) is missing. Pass -$($required.Key) or set the AUTOPILOT_$($required.Key.ToUpper()) environment variable."
    }
}
if (-not $ClientSecret) {
    throw 'ClientSecret is missing. Pass -ClientSecret or set AUTOPILOT_CLIENT_SECRET.'
}

# ------------------------------------------------------------ device info ---

$bios = Get-CimInstance -ClassName Win32_BIOS
$serialNumber = $bios.SerialNumber

$hashDetail = Get-CimInstance -Namespace 'root/cimv2/mdm/dmmap' `
    -ClassName 'MDM_DevDetail_Ext01' -Filter "InstanceID='Ext' AND ParentID='./DevDetail'" `
    -ErrorAction SilentlyContinue

if (-not $hashDetail -or [string]::IsNullOrWhiteSpace($hashDetail.DeviceHardwareData)) {
    throw 'Could not read the Autopilot hardware hash. Run this elevated, on physical Windows hardware. Most virtual machines do not expose it.'
}

$hardwareHash = $hashDetail.DeviceHardwareData

Write-Host "Device       : $env:COMPUTERNAME"
Write-Host "Serial number: $serialNumber"

# ----------------------------------------------------------------- token ---

$plainSecret = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
    [Runtime.InteropServices.Marshal]::SecureStringToBSTR($ClientSecret))

try {
    $token = Invoke-RestMethod -Method Post `
        -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" `
        -ContentType 'application/x-www-form-urlencoded' `
        -Body @{
            grant_type    = 'client_credentials'
            client_id     = $ClientId
            client_secret = $plainSecret
            scope         = 'https://graph.microsoft.com/.default'
        }
}
finally {
    # Do not leave the secret lying around in a variable for the rest of the session.
    $plainSecret = $null
    [GC]::Collect()
}

# ---------------------------------------------------------------- import ---

$payload = @{
    '@odata.type'              = '#microsoft.graph.importedWindowsAutopilotDeviceIdentity'
    serialNumber               = $serialNumber
    hardwareIdentifier         = $hardwareHash
    importedDeviceIdentityType = 'manufacturerModelSerial'
}
if ($GroupTag) { $payload.groupTag = $GroupTag }
if ($AssignedUser) { $payload.assignedUserPrincipalName = $AssignedUser }

if (-not $PSCmdlet.ShouldProcess($serialNumber, 'Import into Windows Autopilot')) { return }

try {
    $response = Invoke-RestMethod -Method Post `
        -Uri 'https://graph.microsoft.com/v1.0/deviceManagement/importedWindowsAutopilotDeviceIdentities' `
        -Headers @{ Authorization = "Bearer $($token.access_token)" } `
        -ContentType 'application/json' `
        -Body ($payload | ConvertTo-Json -Depth 5)
}
catch {
    $status = $null
    if ($_.Exception.PSObject.Properties.Name -contains 'Response' -and $_.Exception.Response) {
        $status = [int]$_.Exception.Response.StatusCode
    }
    if ($status -eq 409) {
        Write-Host 'This device is already present in Autopilot. Nothing to do.'
        return
    }
    throw "Autopilot import failed (HTTP $status): $($_.Exception.Message)"
}

Write-Host 'Device accepted for Autopilot import.'
Write-Host 'Import runs asynchronously. Check Intune > Devices > Enrolment > Devices in a few minutes.'

return [pscustomobject]@{
    SerialNumber = $serialNumber
    ImportId     = $response.id
    State        = $response.state.deviceImportStatus
    GroupTag     = $GroupTag
}
