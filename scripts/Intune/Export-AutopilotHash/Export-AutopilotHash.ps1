#Requires -Version 5.1

<#
.SYNOPSIS
    Collects the Windows Autopilot hardware hash and uploads the CSV to an Azure
    Blob Storage container.

.DESCRIPTION
    For fleets where you want the hashes centrally, without giving every device
    an app registration. The device writes its own CSV to a blob container using
    a SAS URL, and you import the collected files into Intune whenever it suits
    you.

    Pairs well with an RMM: put the SAS URL in an environment variable, run this
    once per machine, then bulk import.

    If you would rather register devices directly and skip the CSV shuffle
    entirely, use Register-AutopilotDevice instead.

.PARAMETER SasUrl
    Full SAS URL of the target container, with write permission. Falls back to
    the SasURL environment variable, which is how an RMM would supply it.

.PARAMETER FileNamePrefix
    Prefix for the CSV filename. The computer name is appended.

.PARAMETER WorkingDirectory
    Where the CSV and the AzCopy download land. Cleaned up afterwards.

.EXAMPLE
    # SAS URL from the RMM environment
    .\Export-AutopilotHash.ps1

.EXAMPLE
    .\Export-AutopilotHash.ps1 -SasUrl 'https://acct.blob.core.windows.net/hashes?sv=...' -FileNamePrefix 'HQ_'

.NOTES
    A SAS URL is a bearer credential. Anyone holding it can write to that
    container. Scope it to write-only, set a short expiry, and rotate it.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$SasUrl = $env:SasURL,

    [string]$FileNamePrefix = 'AID_',

    [string]$WorkingDirectory = $env:TEMP
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ([string]::IsNullOrWhiteSpace($SasUrl)) {
    throw 'No SAS URL. Pass -SasUrl or set the SasURL environment variable in your RMM.'
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$azCopyZip = Join-Path $WorkingDirectory 'AzCopy.zip'
$azCopyDir = Join-Path $WorkingDirectory 'AzCopy'
$csvPath = Join-Path $WorkingDirectory "$FileNamePrefix$env:COMPUTERNAME.csv"

try {
    # ------------------------------------------------------------ azcopy ---

    Write-Host 'Downloading AzCopy...'
    Invoke-WebRequest -Uri 'https://aka.ms/downloadazcopy-v10-windows' -OutFile $azCopyZip -UseBasicParsing
    Expand-Archive -Path $azCopyZip -DestinationPath $azCopyDir -Force

    $azCopy = (Get-ChildItem -Path $azCopyDir -Recurse -File -Filter 'azcopy.exe' |
        Select-Object -First 1).FullName

    if (-not $azCopy) { throw 'AzCopy was downloaded but azcopy.exe was not found in the archive.' }

    # -------------------------------------------------------------- hash ---

    if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force | Out-Null
    }

    if (-not (Get-InstalledScript -Name Get-WindowsAutopilotInfo -ErrorAction SilentlyContinue)) {
        Write-Host 'Installing Get-WindowsAutopilotInfo...'
        Install-Script -Name Get-WindowsAutopilotInfo -Force
    }

    $autopilotScript = Join-Path (Get-InstalledScript -Name Get-WindowsAutopilotInfo).InstalledLocation 'Get-WindowsAutoPilotInfo.ps1'

    Write-Host 'Collecting hardware hash...'
    & $autopilotScript -OutputFile $csvPath

    if (-not (Test-Path -LiteralPath $csvPath)) {
        throw 'Get-WindowsAutopilotInfo produced no CSV. Run this elevated, on physical hardware.'
    }

    # ------------------------------------------------------------ upload ---

    if ($PSCmdlet.ShouldProcess($csvPath, 'Upload to Azure Blob Storage')) {
        Write-Host 'Uploading...'
        & $azCopy cp $csvPath $SasUrl --overwrite=true

        if ($LASTEXITCODE -ne 0) {
            throw "AzCopy exited with code $LASTEXITCODE. Check that the SAS URL is valid, unexpired, and has write permission."
        }

        Write-Host "Uploaded $(Split-Path $csvPath -Leaf)."
    }

    return [pscustomobject]@{
        ComputerName = $env:COMPUTERNAME
        FileName     = Split-Path $csvPath -Leaf
        Uploaded     = $true
    }
}
finally {
    # The CSV holds a hardware hash. Do not leave it on the device.
    foreach ($path in $azCopyZip, $azCopyDir, $csvPath) {
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
