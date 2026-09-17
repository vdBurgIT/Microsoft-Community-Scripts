# 💾 Get-SpoStorageReport

Site storage and activity, with the full ones and the dead ones marked.

## What it does

Pulls the SharePoint site usage report out of the Graph reporting API and turns
it into sortable objects: storage used, quota, percentage full, file counts, page
views, last activity and days idle. Sites over `-NearQuotaPercent` and sites with
no activity in `-DormantDays` get flagged.

Nothing is changed.

## Why it exists

Two questions that arrive together, usually the week storage runs out:

- Which sites are about to hit their quota, before somebody cannot save a file
- Which sites have had no activity at all, so the storage they hold is going
  nowhere

The admin centre shows storage per site. It does not show storage next to last
activity, which is the combination that tells you what to clean up first.

## How to run

```powershell
./Get-SpoStorageReport.ps1
./Get-SpoStorageReport.ps1 -Period D90 -DormantOnly -MinStorageMb 1024 -CsvPath ./dormant-sites.csv
./Get-SpoStorageReport.ps1 | Sort-Object PercentUsed -Descending | Select-Object -First 20
```

Graph scope: `Reports.Read.All`. Reports Reader or Global Reader is enough.

## Where it bites

**Concealed names turn the report into nonsense.** If "Display concealed user,
group, and site names" is on in the Microsoft 365 admin centre, under
Settings > Org settings > Reports, the site URLs and owner names come back as
meaningless identifiers. The script counts those and warns. Turning the setting
off is a tenant-wide privacy decision, so have that conversation before you
promise anyone a report.

**The numbers lag by about a day.** Same lag as the admin centre. Do not use this
to confirm a cleanup you ran an hour ago and then conclude it did not work.

**The endpoint answers with a redirect to a CSV, not JSON.** The script writes
that file to the temp directory, reads it and deletes it. If you are running this
somewhere with an unusual temp directory or no write access, that is the line
that fails.

**`-Period` only affects the activity columns.** Storage is the current figure
whatever period you pass. A site can show zero page views over D7 and still be
perfectly active, which is why `-DormantDays` is judged on the last activity date
rather than on the counts.

**Quota is usually not set per site.** Most tenants leave sites on the pooled
tenant quota, in which case `Storage Allocated` is a very large number and
`PercentUsed` is close to zero for everything. That is not a bug in the report,
it means quota is not the constraint. Sort on `StorageUsedMb` instead.

**Deleted sites are excluded by default.** They still hold storage until the
retention window runs out, which is worth knowing when the tenant total does not
add up. `-IncludeDeleted` brings them back.
