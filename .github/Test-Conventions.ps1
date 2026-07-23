#Requires -Version 7.2

<#
.SYNOPSIS
    Checks every script in this repo against the conventions in CONTRIBUTING.md.

.DESCRIPTION
    Static checks only. Nothing is executed, no tenant is touched, no modules are
    imported. Runs in a couple of seconds.

    What it verifies per script:

    - Lives in scripts/<Area>/<Name>/ with a matching <Name>.ps1 and a README.md
    - Uses an approved PowerShell verb
    - Parses without syntax errors
    - Has comment-based help with a synopsis and at least one example
    - Is listed in the table in the root README
    - Carries no obvious secret or tenant identifier

.EXAMPLE
    pwsh .github/Test-Conventions.ps1

.EXAMPLE
    # Quieter output for CI
    pwsh .github/Test-Conventions.ps1 -Quiet
#>

[CmdletBinding()]
param(
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path $PSScriptRoot -Parent
$scriptRoot = Join-Path $repoRoot 'scripts'
$problems = [System.Collections.Generic.List[object]]::new()

function Add-Problem {
    param([string]$Where, [string]$What, [string]$Fix)
    $problems.Add([pscustomobject]@{ Where = $Where; What = $What; Fix = $Fix })
}

function Write-Step {
    param([string]$Message)
    if (-not $Quiet) { Write-Host $Message -ForegroundColor Cyan }
}

if (-not (Test-Path $scriptRoot)) { throw "No scripts/ directory found at $scriptRoot" }

$approvedVerbs = (Get-Verb).Verb
$readmeText = Get-Content (Join-Path $repoRoot 'README.md') -Raw

# ------------------------------------------------------------- layout ---

Write-Step 'Checking layout...'

# scripts/<Area>/<Name>/ and nothing else
foreach ($stray in Get-ChildItem $scriptRoot -Filter *.ps1 -File -Recurse) {
    $relative = [IO.Path]::GetRelativePath($repoRoot, $stray.FullName) -replace '\\', '/'
    $depth = ($relative -split '/').Count

    if ($depth -ne 4) {
        Add-Problem $relative 'Script is not at scripts/<Area>/<Name>/<Name>.ps1' `
            'Move it into its own folder one level under an area folder.'
    }
}

$scriptFolders = Get-ChildItem $scriptRoot -Directory |
    ForEach-Object { Get-ChildItem $_.FullName -Directory }

if ($scriptFolders.Count -eq 0) { throw 'No script folders found under scripts/<Area>/.' }

# ------------------------------------------------------- per script ---

foreach ($folder in $scriptFolders) {
    $name = $folder.Name
    $area = Split-Path (Split-Path $folder.FullName -Parent) -Leaf
    $rel = "scripts/$area/$name"
    $scriptPath = Join-Path $folder.FullName "$name.ps1"

    Write-Step "  $rel"

    # --- the two required files ---

    if (-not (Test-Path $scriptPath)) {
        Add-Problem $rel "No $name.ps1 in the folder" `
            'The script file must carry the same name as its folder.'
        continue
    }

    if (-not (Test-Path (Join-Path $folder.FullName 'README.md'))) {
        Add-Problem $rel 'No README.md' `
            'Cover what it does, why it exists, how to run it, and where it bites.'
    }

    # --- approved verb ---

    $verb = ($name -split '-', 2)[0]
    if ($name -notmatch '^[A-Za-z]+-\S+$') {
        Add-Problem $rel "Name '$name' is not Verb-Noun" 'Rename to Verb-Noun.'
    }
    elseif ($approvedVerbs -notcontains $verb) {
        Add-Problem $rel "'$verb' is not an approved verb" `
            "Run Get-Verb and pick the closest match."
    }

    # --- it has to parse ---

    $parseErrors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile(
        $scriptPath, [ref]$null, [ref]$parseErrors)

    if ($parseErrors) {
        foreach ($e in $parseErrors) {
            Add-Problem "$rel/$name.ps1:$($e.Extent.StartLineNumber)" `
                "Syntax error: $($e.Message)" 'Fix the syntax.'
        }
        continue
    }

    # --- comment-based help ---

    $help = Get-Help $scriptPath -ErrorAction SilentlyContinue
    $synopsis = if ($help) { "$($help.Synopsis)".Trim() } else { '' }

    if ([string]::IsNullOrWhiteSpace($synopsis) -or $synopsis.StartsWith("$name.ps1")) {
        Add-Problem "$rel/$name.ps1" 'Get-Help finds no comment-based help' `
            'Most likely cause: #Requires sits directly above the help block. Put a blank line between them.'
    }
    else {
        # No .EXAMPLE at all means Get-Help omits the Examples property entirely,
        # so this cannot be a plain property access under StrictMode.
        $examples = 0
        if ($help.PSObject.Properties.Name -contains 'Examples' -and $help.Examples) {
            $examples = @($help.Examples.Example).Count
        }

        if ($examples -lt 1) {
            Add-Problem "$rel/$name.ps1" 'No .EXAMPLE in the help' `
                'Add at least one worked example.'
        }
    }

    # --- listed in the root README ---

    if ($readmeText -notmatch [regex]::Escape("scripts/$area/$name/")) {
        Add-Problem $rel 'Not listed in the root README table' `
            "Add a row linking to scripts/$area/$name/."
    }
}

# --------------------------------------------------- secrets and tenants ---

Write-Step 'Scanning for secrets and tenant identifiers...'

$secretPatterns = @(
    @{ Name = 'Azure SAS token'; Pattern = 'sig=[A-Za-z0-9%+/=]{20,}' }
    @{ Name = 'Storage account key'; Pattern = 'AccountKey\s*=\s*[A-Za-z0-9+/=]{40,}' }
    @{ Name = 'Hardcoded client secret'; Pattern = '(?i)client_?secret\s*=\s*[''"][A-Za-z0-9~._-]{20,}[''"]' }
    @{ Name = 'Tenant domain'; Pattern = '(?i)\b[a-z0-9-]+\.onmicrosoft\.com\b' }
    @{ Name = 'SharePoint tenant host'; Pattern = '(?i)\bhttps://[a-z0-9-]+\.sharepoint\.com' }
)

$allowedPlaceholders = 'contoso', 'fabrikam', 'example', 'tenant', 'yourtenant'

foreach ($file in Get-ChildItem $repoRoot -Include *.ps1, *.md -Recurse -File |
    Where-Object { $_.FullName -notlike "*$([IO.Path]::DirectorySeparatorChar).git$([IO.Path]::DirectorySeparatorChar)*" }) {

    $relative = [IO.Path]::GetRelativePath($repoRoot, $file.FullName) -replace '\\', '/'
    $lines = Get-Content $file.FullName

    for ($i = 0; $i -lt $lines.Count; $i++) {
        foreach ($rule in $secretPatterns) {
            if ($lines[$i] -match $rule.Pattern) {
                $hit = $Matches[0]

                # contoso.sharepoint.com in an example is the whole point of an example.
                if ($allowedPlaceholders | Where-Object { $hit -match [regex]::Escape($_) }) { continue }

                Add-Problem "${relative}:$($i + 1)" "Possible $($rule.Name): $hit" `
                    'Replace it with a parameter or a contoso.com placeholder.'
            }
        }
    }
}

# ---------------------------------------------------------------- report ---

if (-not $Quiet) { Write-Host '' }

if ($problems.Count -eq 0) {
    Write-Host "All conventions pass. $($scriptFolders.Count) script(s) checked." -ForegroundColor Green
    exit 0
}

Write-Host "$($problems.Count) problem(s):" -ForegroundColor Red
Write-Host ''
foreach ($p in $problems) {
    Write-Host "  $($p.Where)" -ForegroundColor Yellow
    Write-Host "    $($p.What)"
    Write-Host "    fix: $($p.Fix)" -ForegroundColor DarkGray
    Write-Host ''
}

exit 1
