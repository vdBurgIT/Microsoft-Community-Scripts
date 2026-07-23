# 📚 Get-SpoLibraryIds

Pulls the library ID of every SharePoint site in your tenant, in the exact
format the OneDrive automount policy wants.

## What it does

The Intune setting **Configure team site libraries to sync automatically** takes
a value per library that looks like this:

```
tenantId=<guid>&siteId={<guid>}&webId={<guid>}&listId={<guid>}&webUrl=<url>&version=1
```

Microsoft's documented way to get that string: browse to a library, click
**Sync**, click **Copy library ID**, then decode the percent-encoding by hand.
Per library. For every site you want to automount. If you have thirty team
sites, that's your afternoon gone 🫠.

This script signs you in once and hands you the whole list.

```powershell
./Get-SpoLibraryIds.ps1
```

You get `SPO_LibraryIds.csv` with two columns, `Name` and `LibraryId`, which map
straight onto the policy's **Value name** and **Value** fields. The values come
out already decoded, with literal `{ } : / .` instead of `%7B %7D %3A %2F %2E`,
because that's the form the policy expects.

## Why you don't need an app registration

The script runs on the Microsoft Graph PowerShell SDK, which ships with its own
first-party Microsoft app. You sign in as Global Admin, consent once, done. No
app registration, no certificate, no client secret to rotate.

One small module gets installed on first run: `Microsoft.Graph.Authentication`.
Not the full Graph SDK, just the auth piece. Everything else goes through
`Invoke-MgGraphRequest`.

## How it finds sites

Two passes, because neither one alone is complete.

First every Microsoft 365 group, then the site behind each one. That covers all
your Teams and group sites, and it's exhaustive because it walks a hard list of
groups instead of trusting an index.

Then a site search for whatever is left: communication sites, classic sites,
anything without a group attached. This pass leans on the SharePoint search
index, so a site that was created five minutes ago might not show up yet.

Sites found by both passes get de-duplicated on their site ID, not their URL.

## Common runs

```powershell
# See what it finds before committing to anything
./Get-SpoLibraryIds.ps1 -ListSitesOnly

# Only the sites you care about
./Get-SpoLibraryIds.ps1 -Filter '*Finance*'

# Every document library per site, not just the main one
./Get-SpoLibraryIds.ps1 -IncludeAllDocumentLibraries

# A site the search index hasn't caught up with yet
./Get-SpoLibraryIds.ps1 -SiteUrl https://contoso.sharepoint.com/sites/HR

# Test it on one machine before you push the policy to everyone
./Get-SpoLibraryIds.ps1 -RegPath ./automount.reg
```

The script also returns objects, so you can skip the files entirely:

```powershell
./Get-SpoLibraryIds.ps1 | Set-Clipboard
./Get-SpoLibraryIds.ps1 | Out-GridView
```

Full parameter list: `Get-Help ./Get-SpoLibraryIds.ps1 -Full`.

## Output

| Parameter | Default | Contents |
| --- | --- | --- |
| `-CsvPath` | `./SPO_LibraryIds.csv` | Comma separated, for Intune |
| `-TxtPath` | `./SPO_LibraryIds.txt` | Tab separated with a header row, pastes into Excel |
| `-RegPath` | not written | `.reg` file for `HKCU\Software\Policies\Microsoft\OneDrive\TenantAutoMount` |

Add `-Split` and you get `SiteId`, `WebId` and `ListId` as separate columns
instead of the combined string. Handy if you're feeding another system.

Careful with that one though: the Intune policy only accepts the complete
string. Paste a bare site ID into the value field and you get a policy that
deploys cleanly, reports success, and syncs absolutely nothing.

## Getting into Intune

**Devices → Configuration → Settings catalog → OneDrive → Configure team site
libraries to sync automatically**

Per row: **Value name** is the `Name` column, **Value** is the `LibraryId`
column. Names have to be unique inside the policy, so if two sites are both
called "Sales" the script appends the site path to one of them.

## Caveats

Sites where you're not a member come back as HTTP 403. The script logs them and
carries on instead of dying halfway through your tenant. If you need those too,
you're into app-only territory with a certificate, which means the app
registration you were trying to avoid.

Personal OneDrive sites are excluded. You can force them in with
`-IncludeOneDrivePersonalSites`, but automounting someone's personal OneDrive
into their own OneDrive is a fun way to spend a Friday explaining sync loops.

Hidden libraries, system libraries and anything that isn't a document library
get filtered out. Site Assets and Form Templates share the same base template as
your real libraries, and neither is something you want landing in Explorer.

## Signing in twice

The token gets cached on disk under the `CurrentUser` context scope, so a second
run reuses it silently. If you're getting two prompts on Windows, that's usually
the WAM broker putting a Windows account picker in front of the browser login.
Run it once with `-NoWam` and it switches to browser-only sign-in. The setting
sticks, so once is enough.

Still two prompts after that? Then your token cache is confused. Run
`Disconnect-MgGraph`, delete `%LOCALAPPDATA%\.IdentityService\mg.msal.cache*`
and sign in again.

## Requirements

- PowerShell 7.2 or newer
- Global Admin, or an account that already has `Sites.Read.All` and
  `Group.Read.All` consented
