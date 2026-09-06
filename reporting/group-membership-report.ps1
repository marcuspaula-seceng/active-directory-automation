<#
.SYNOPSIS
    Group membership snapshot — who is in which group, exported for audit.

.DESCRIPTION
    Generates a point-in-time snapshot of all AD group memberships.
    Useful for change comparison (diff against previous snapshot), compliance
    audits, and access reviews. Exports flat CSV and hierarchical HTML.

.PARAMETER GroupFilter
    Wildcard to filter groups. Default: all groups.

.PARAMETER OutputPath
    Directory for output files.

.PARAMETER CompareWithPrevious
    If specified, compares with the most recent CSV in OutputPath and reports changes.

.EXAMPLE
    .\group-membership-report.ps1 -GroupFilter "GRP-*" -OutputPath "C:\Reports\GroupSnapshots" -CompareWithPrevious

.NOTES
    Author:  Marcus Paula
    Version: 1.0
    Date:    2026-01-15
    Requires: ActiveDirectory module.
#>

#Requires -Modules ActiveDirectory
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

[CmdletBinding()]
param(
    [Parameter()][string]$GroupFilter = '*',
    [Parameter()][string]$OutputPath = 'C:\Reports\GroupSnapshots',
    [Parameter()][switch]$CompareWithPrevious,
    [Parameter()][string]$LogPath = 'C:\Logs\AD-GroupReport.log'
)

function Write-Log {
    param([string]$Message, [ValidateSet('INFO','WARN','ERROR','SUCCESS')]$Level = 'INFO')
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $entry = "[$timestamp][$Level] $Message"
    Add-Content -Path $LogPath -Value $entry
    switch ($Level) {
        'INFO'    { Write-Host $entry -ForegroundColor Cyan }
        'WARN'    { Write-Host $entry -ForegroundColor Yellow }
        'ERROR'   { Write-Host $entry -ForegroundColor Red }
        'SUCCESS' { Write-Host $entry -ForegroundColor Green }
    }
}

$null = New-Item -ItemType Directory -Force -Path $OutputPath
$null = New-Item -ItemType Directory -Force -Path (Split-Path $LogPath)

$reportDate = Get-Date -Format 'yyyy-MM-dd'
$csvPath    = Join-Path $OutputPath "GroupSnapshot-$reportDate.csv"
$htmlPath   = Join-Path $OutputPath "GroupSnapshot-$reportDate.html"
$diffPath   = Join-Path $OutputPath "GroupDiff-$reportDate.csv"

Write-Log "=== GROUP MEMBERSHIP SNAPSHOT START | $reportDate ===" -Level INFO

try {
    $groups  = Get-ADGroup -Filter * -Properties Description, GroupCategory, GroupScope |
        Where-Object { $_.Name -like $GroupFilter } | Sort-Object Name
    Write-Log "Groups in scope: $($groups.Count)" -Level INFO

    $snapshot = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($group in $groups) {
        $members = Get-ADGroupMember -Identity $group -Recursive |
            Where-Object { $_.objectClass -eq 'user' } | Sort-Object Name
        if ($members.Count -eq 0) {
            $snapshot.Add([PSCustomObject]@{
                GroupName     = $group.Name
                GroupCategory = $group.GroupCategory
                GroupScope    = $group.GroupScope
                Description   = $group.Description
                MemberCount   = 0
                UserDisplay   = '(empty)'
                SAMAccount    = ''
                Department    = ''
                SnapshotDate  = $reportDate
            })
            continue
        }
        foreach ($m in $members) {
            try {
                $u = Get-ADUser -Identity $m.SamAccountName -Properties Department, DisplayName
                $snapshot.Add([PSCustomObject]@{
                    GroupName     = $group.Name
                    GroupCategory = $group.GroupCategory
                    GroupScope    = $group.GroupScope
                    Description   = $group.Description
                    MemberCount   = $members.Count
                    UserDisplay   = $u.DisplayName
                    SAMAccount    = $u.SamAccountName
                    Department    = $u.Department
                    SnapshotDate  = $reportDate
                })
            } catch {
                Write-Log "User lookup failed: $($m.SamAccountName)" -Level WARN
            }
        }
    }

    $snapshot | Export-Csv -Path $csvPath -NoTypeInformation
    Write-Log "Snapshot CSV exported: $csvPath ($($snapshot.Count) records)" -Level SUCCESS

    # Compare with previous snapshot if requested
    if ($CompareWithPrevious) {
        $prevCsv = Get-ChildItem -Path $OutputPath -Filter 'GroupSnapshot-*.csv' |
            Where-Object { $_.Name -ne (Split-Path $csvPath -Leaf) } |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($prevCsv) {
            Write-Log "Comparing with: $($prevCsv.Name)" -Level INFO
            $prev    = Import-Csv -Path $prevCsv.FullName
            $prevSet = $prev | ForEach-Object { "$($_.GroupName)|$($_.SAMAccount)" }
            $currSet = $snapshot | ForEach-Object { "$($_.GroupName)|$($_.SAMAccount)" }
            $added   = $currSet | Where-Object { $_ -notin $prevSet }
            $removed = $prevSet | Where-Object { $_ -notin $currSet }
            $diffData = @()
            $diffData += $added   | ForEach-Object { $p=$_.Split('|'); [PSCustomObject]@{Change='ADDED';Group=$p[0];SAM=$p[1];Date=$reportDate} }
            $diffData += $removed | ForEach-Object { $p=$_.Split('|'); [PSCustomObject]@{Change='REMOVED';Group=$p[0];SAM=$p[1];Date=$reportDate} }
            if ($diffData) {
                $diffData | Export-Csv -Path $diffPath -NoTypeInformation
                Write-Log "Diff: $($added.Count) added, $($removed.Count) removed — exported to $diffPath" -Level WARN
            } else {
                Write-Log "No membership changes detected since $($prevCsv.Name)" -Level SUCCESS
            }
        } else {
            Write-Log "No previous snapshot found for comparison" -Level INFO
        }
    }

    # HTML
    $groupedHTML = $snapshot | Group-Object GroupName
    $html = @"
<!DOCTYPE html><html><head><meta charset="UTF-8"><title>Group Membership Snapshot — $reportDate</title>
<style>
body { font-family: Segoe UI, Arial, sans-serif; font-size: 13px; background: #f5f5f5; margin: 20px; }
h1 { color: #2c3e50; } h2 { color: #34495e; margin-top: 20px; font-size: 14px; background: #ecf0f1; padding: 6px 10px; }
.meta { color: #7f8c8d; font-size: 12px; margin-bottom: 20px; }
table { border-collapse: collapse; width: 100%; background: white; box-shadow: 0 1px 3px rgba(0,0,0,0.1); margin-bottom: 10px; }
th { background: #2c3e50; color: white; padding: 6px 10px; text-align: left; font-size: 12px; }
td { padding: 5px 10px; border-bottom: 1px solid #eee; }
tr:hover { background: #f9f9f9; }
.empty { color: #bdc3c7; font-style: italic; }
</style></head><body>
<h1>Group Membership Snapshot — $reportDate</h1>
<p class="meta">Groups: $($groups.Count) | Total entries: $($snapshot.Count) | Filter: $GroupFilter</p>
"@
    foreach ($grp in $groupedHTML | Sort-Object Name) {
        $html += "<h2>$($grp.Name) ($($grp.Count) members)</h2>"
        $html += '<table><tr><th>User</th><th>SAM Account</th><th>Department</th></tr>'
        foreach ($row in $grp.Group) {
            if ($row.SAMAccount -eq '') { $html += "<tr><td colspan='3' class='empty'>(empty group)</td></tr>" }
            else { $html += "<tr><td>$($row.UserDisplay)</td><td>$($row.SAMAccount)</td><td>$($row.Department)</td></tr>" }
        }
        $html += '</table>'
    }
    $html += '</body></html>'
    $html | Out-File -FilePath $htmlPath -Encoding UTF8
    Write-Log "HTML snapshot exported: $htmlPath" -Level SUCCESS

    Write-Log "=== GROUP MEMBERSHIP REPORT COMPLETE ===" -Level SUCCESS
    Write-Host "`nSnapshot Summary:" -ForegroundColor Cyan
    [PSCustomObject]@{
        SnapshotDate  = $reportDate
        GroupsSnapped = $groups.Count
        TotalEntries  = $snapshot.Count
        CSVSnapshot   = $csvPath
        HTMLSnapshot  = $htmlPath
    } | Format-List

} catch {
    Write-Log "FATAL ERROR: $($_.Exception.Message)" -Level ERROR
    throw
}
