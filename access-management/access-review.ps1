<#
.SYNOPSIS
    Quarterly access review report — lists all users per security group with last logon data.

.DESCRIPTION
    Generates a structured access review report for all security groups (or a specified subset).
    For each group, lists members with last logon date, account status, and department.
    Exports to CSV and HTML for distribution to managers and compliance teams.
    Designed to support SOX, ISO 27001, and internal quarterly review cycles.

.PARAMETER GroupFilter
    Optional wildcard filter to scope report (e.g. "GRP-*"). Defaults to all security groups.

.PARAMETER OutputPath
    Directory for report files. Defaults to C:\Reports\AccessReview\

.PARAMETER StaleThresholdDays
    Flag accounts not logged in for this many days. Default: 90.

.PARAMETER SendReport
    If specified, emails the HTML report to the ReviewEmailTo address.

.PARAMETER ReviewEmailTo
    Recipient for the emailed report (requires -SendReport).

.EXAMPLE
    .\access-review.ps1 -GroupFilter "GRP-*" -OutputPath "C:\Reports\Q1-2026" -SendReport -ReviewEmailTo "security@example.com"

.NOTES
    Author:  Marcus Paula
    Version: 1.0
    Date:    2026-01-15
    Requires: ActiveDirectory module.
#>

#Requires -Modules ActiveDirectory

[CmdletBinding()]
param(
    [Parameter()][string]$GroupFilter = '*',
    [Parameter()][string]$OutputPath = 'C:\Reports\AccessReview',
    [Parameter()][int]$StaleThresholdDays = 90,
    [Parameter()][switch]$SendReport,
    [Parameter()][string]$ReviewEmailTo = 'security@example.com',
    [Parameter()][string]$LogPath = 'C:\Logs\AD-AccessReview.log'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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

$config = @{
    SmtpServer = 'smtp.example.com'
    NotifyFrom = 'it-automation@example.com'
}

$null = New-Item -ItemType Directory -Force -Path $OutputPath
$null = New-Item -ItemType Directory -Force -Path (Split-Path $LogPath)

$reportDate   = Get-Date -Format 'yyyy-MM-dd'
$staleDate    = (Get-Date).AddDays(-$StaleThresholdDays)
$csvPath      = Join-Path $OutputPath "AccessReview-$reportDate.csv"
$htmlPath     = Join-Path $OutputPath "AccessReview-$reportDate.html"

Write-Log "=== QUARTERLY ACCESS REVIEW START | Date: $reportDate ===" -Level INFO

try {
    $groups = Get-ADGroup -Filter { GroupCategory -eq 'Security' } -Properties Description |
        Where-Object { $_.Name -like $GroupFilter } |
        Sort-Object Name
    Write-Log "Groups in scope: $($groups.Count)" -Level INFO

    $results = [System.Collections.Generic.List[PSCustomObject]]::new()
    $staleCount = 0
    $disabledCount = 0

    foreach ($group in $groups) {
        Write-Log "Processing group: $($group.Name)" -Level INFO
        $members = Get-ADGroupMember -Identity $group -Recursive |
            Where-Object { $_.objectClass -eq 'user' }

        foreach ($member in $members) {
            try {
                $adUser = Get-ADUser -Identity $member.SamAccountName -Properties `
                    LastLogonDate, Department, Title, Enabled, PasswordLastSet, EmailAddress
                $isStale = $adUser.LastLogonDate -lt $staleDate
                if ($isStale)           { $staleCount++ }
                if (-not $adUser.Enabled) { $disabledCount++ }

                $results.Add([PSCustomObject]@{
                    Group           = $group.Name
                    GroupDescription = $group.Description
                    User            = $adUser.DisplayName
                    SAMAccount      = $adUser.SamAccountName
                    Email           = $adUser.EmailAddress
                    Department      = $adUser.Department
                    Title           = $adUser.Title
                    AccountEnabled  = $adUser.Enabled
                    LastLogon       = if ($adUser.LastLogonDate) { $adUser.LastLogonDate.ToString('yyyy-MM-dd') } else { 'Never' }
                    StaleFlag       = $isStale
                    PasswordLastSet = if ($adUser.PasswordLastSet) { $adUser.PasswordLastSet.ToString('yyyy-MM-dd') } else { 'Never' }
                    ReviewDate      = $reportDate
                })
            } catch {
                Write-Log "Could not retrieve user: $($member.SamAccountName) — $($_.Exception.Message)" -Level WARN
            }
        }
    }

    # Export CSV
    $results | Export-Csv -Path $csvPath -NoTypeInformation
    Write-Log "CSV exported: $csvPath ($($results.Count) records)" -Level SUCCESS

    # Build HTML report
    $html = @"
<!DOCTYPE html>
<html>
<head>
<meta charset="UTF-8">
<title>Access Review — $reportDate</title>
<style>
  body { font-family: Segoe UI, Arial, sans-serif; font-size: 13px; background: #f5f5f5; margin: 20px; }
  h1 { color: #2c3e50; } h2 { color: #34495e; margin-top: 30px; }
  .summary { background: #2c3e50; color: white; padding: 15px 20px; border-radius: 5px; margin-bottom: 20px; }
  .summary span { margin-right: 30px; font-size: 14px; }
  table { border-collapse: collapse; width: 100%; background: white; box-shadow: 0 1px 3px rgba(0,0,0,0.1); margin-bottom: 30px; }
  th { background: #34495e; color: white; padding: 8px 12px; text-align: left; font-size: 12px; }
  td { padding: 7px 12px; border-bottom: 1px solid #eee; }
  tr:hover { background: #f9f9f9; }
  .stale { background: #fff3cd !important; }
  .disabled { background: #f8d7da !important; }
  .ok { color: #27ae60; font-weight: bold; }
  .flag { color: #e74c3c; font-weight: bold; }
</style>
</head>
<body>
<h1>Quarterly Access Review — $reportDate</h1>
<div class="summary">
  <span>Total Entries: <strong>$($results.Count)</strong></span>
  <span>Groups Reviewed: <strong>$($groups.Count)</strong></span>
  <span>Stale Accounts (90d+): <strong>$staleCount</strong></span>
  <span>Disabled Accounts in Groups: <strong>$disabledCount</strong></span>
  <span>Threshold: <strong>$StaleThresholdDays days</strong></span>
</div>
<table>
<tr><th>Group</th><th>User</th><th>SAM</th><th>Department</th><th>Title</th><th>Enabled</th><th>Last Logon</th><th>Password Last Set</th><th>Stale Flag</th></tr>
"@
    foreach ($row in $results | Sort-Object Group, User) {
        $rowClass = if (-not $row.AccountEnabled) { 'disabled' } elseif ($row.StaleFlag) { 'stale' } else { '' }
        $enabledDisplay = if ($row.AccountEnabled) { '<span class="ok">Yes</span>' } else { '<span class="flag">No</span>' }
        $staleDisplay   = if ($row.StaleFlag) { '<span class="flag">Yes</span>' } else { '<span class="ok">No</span>' }
        $html += "<tr class='$rowClass'><td>$($row.Group)</td><td>$($row.User)</td><td>$($row.SAMAccount)</td><td>$($row.Department)</td><td>$($row.Title)</td><td>$enabledDisplay</td><td>$($row.LastLogon)</td><td>$($row.PasswordLastSet)</td><td>$staleDisplay</td></tr>`n"
    }
    $html += "</table></body></html>"
    $html | Out-File -FilePath $htmlPath -Encoding UTF8
    Write-Log "HTML report exported: $htmlPath" -Level SUCCESS

    if ($SendReport) {
        Send-MailMessage -From $config.NotifyFrom -To $ReviewEmailTo `
            -Subject "Quarterly Access Review — $reportDate | $($results.Count) entries, $staleCount stale, $disabledCount disabled" `
            -Body "Access review report attached. Please review and action flagged accounts." `
            -Attachments $csvPath, $htmlPath -SmtpServer $config.SmtpServer
        Write-Log "Report emailed to: $ReviewEmailTo" -Level SUCCESS
    }

    Write-Log "=== ACCESS REVIEW COMPLETE ===" -Level SUCCESS
    Write-Host "`nAccess Review Summary:" -ForegroundColor Cyan
    [PSCustomObject]@{
        Date            = $reportDate
        GroupsReviewed  = $groups.Count
        TotalEntries    = $results.Count
        StaleAccounts   = $staleCount
        DisabledInGroups = $disabledCount
        CSVReport       = $csvPath
        HTMLReport      = $htmlPath
    } | Format-List

} catch {
    Write-Log "FATAL ERROR: $($_.Exception.Message)" -Level ERROR
    throw
}
