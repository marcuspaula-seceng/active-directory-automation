<#
.SYNOPSIS
    Identify AD accounts not used for 90+ days — stale account detection and reporting.

.DESCRIPTION
    Scans all enabled AD user accounts and reports those with no logon activity
    for the specified threshold. Includes department breakdown, manager info,
    and recommended action. Exports CSV and HTML. Optionally disables accounts
    after confirmation.

.PARAMETER InactiveDays
    Days since last logon to flag as stale. Default: 90.

.PARAMETER OutputPath
    Directory for report files.

.PARAMETER DisableStale
    If specified, disables flagged accounts (requires -Confirm:$false or interactive confirmation).

.PARAMETER OUScope
    Limit scan to a specific OU Distinguished Name (optional).

.EXAMPLE
    .\stale-accounts-report.ps1 -InactiveDays 90 -OutputPath "C:\Reports\StaleAccounts"

.NOTES
    Author:  Marcus Paula
    Version: 1.0
    Date:    2026-01-15
    Requires: ActiveDirectory module.
#>

#Requires -Modules ActiveDirectory
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()][ValidateRange(1,365)][int]$InactiveDays = 90,
    [Parameter()][string]$OutputPath = 'C:\Reports\StaleAccounts',
    [Parameter()][switch]$DisableStale,
    [Parameter()][string]$OUScope,
    [Parameter()][string]$LogPath = 'C:\Logs\AD-StaleAccounts.log'
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

$reportDate  = Get-Date -Format 'yyyy-MM-dd'
$cutoffDate  = (Get-Date).AddDays(-$InactiveDays)
$csvPath     = Join-Path $OutputPath "StaleAccounts-$reportDate.csv"
$htmlPath    = Join-Path $OutputPath "StaleAccounts-$reportDate.html"

Write-Log "=== STALE ACCOUNTS REPORT START | Threshold: $InactiveDays days | Cutoff: $($cutoffDate.ToString('yyyy-MM-dd')) ===" -Level INFO

try {
    $adParams = @{
        Filter     = { Enabled -eq $true }
        Properties = @('LastLogonDate','Department','Title','Manager','DistinguishedName',
                       'EmailAddress','PasswordLastSet','WhenCreated','PasswordNeverExpires')
    }
    if ($OUScope) { $adParams.SearchBase = $OUScope }

    $allUsers   = Get-ADUser @adParams
    $staleUsers = $allUsers | Where-Object {
        (-not $_.LastLogonDate) -or ($_.LastLogonDate -lt $cutoffDate)
    } | Sort-Object LastLogonDate

    Write-Log "Total enabled accounts scanned: $($allUsers.Count)" -Level INFO
    Write-Log "Stale accounts found: $($staleUsers.Count)" -Level WARN

    $results = foreach ($u in $staleUsers) {
        $managerName = 'N/A'
        if ($u.Manager) {
            try { $managerName = (Get-ADUser -Identity $u.Manager).DisplayName } catch {}
        }
        $daysSinceLogon = if ($u.LastLogonDate) {
            [int]((Get-Date) - $u.LastLogonDate).TotalDays
        } else { 9999 }

        [PSCustomObject]@{
            DisplayName     = $u.DisplayName
            SAMAccount      = $u.SamAccountName
            Email           = $u.EmailAddress
            Department      = $u.Department
            Title           = $u.Title
            Manager         = $managerName
            LastLogon       = if ($u.LastLogonDate) { $u.LastLogonDate.ToString('yyyy-MM-dd') } else { 'Never' }
            DaysSinceLogon  = $daysSinceLogon
            AccountCreated  = $u.WhenCreated.ToString('yyyy-MM-dd')
            PwdNeverExpires = $u.PasswordNeverExpires
            OU              = ($u.DistinguishedName -replace '^CN=.*?,','')
            RecommendedAction = if ($daysSinceLogon -gt 180) { 'DISABLE' } elseif ($daysSinceLogon -gt 90) { 'REVIEW' } else { 'MONITOR' }
            ReportDate      = $reportDate
        }
    }

    $results | Export-Csv -Path $csvPath -NoTypeInformation
    Write-Log "CSV exported: $csvPath" -Level SUCCESS

    # Optionally disable stale accounts
    if ($DisableStale) {
        $toDisable = $results | Where-Object { $_.RecommendedAction -eq 'DISABLE' }
        Write-Log "Accounts recommended for disable: $($toDisable.Count)" -Level WARN
        foreach ($account in $toDisable) {
            if ($PSCmdlet.ShouldProcess($account.SAMAccount, "Disable stale account ($($account.DaysSinceLogon) days inactive)")) {
                try {
                    Disable-ADAccount -Identity $account.SAMAccount
                    Set-ADUser -Identity $account.SAMAccount -Description "Auto-disabled: stale account ($($account.DaysSinceLogon) days) | $reportDate"
                    Write-Log "Disabled: $($account.SAMAccount)" -Level SUCCESS
                } catch {
                    Write-Log "Could not disable $($account.SAMAccount): $($_.Exception.Message)" -Level ERROR
                }
            }
        }
    }

    # HTML report
    $html = @"
<!DOCTYPE html><html><head><meta charset="UTF-8">
<title>Stale Accounts Report — $reportDate</title>
<style>
body { font-family: Segoe UI, Arial, sans-serif; font-size: 13px; background: #f5f5f5; margin: 20px; }
h1 { color: #8e44ad; } .summary { background: #2c3e50; color: white; padding: 15px 20px; border-radius: 5px; margin-bottom: 20px; }
.summary span { margin-right: 25px; font-size: 14px; }
table { border-collapse: collapse; width: 100%; background: white; box-shadow: 0 1px 3px rgba(0,0,0,0.1); }
th { background: #8e44ad; color: white; padding: 8px 12px; text-align: left; font-size: 12px; }
td { padding: 7px 12px; border-bottom: 1px solid #eee; }
tr:hover { background: #f9f9f9; }
.disable { background: #f8d7da !important; } .review { background: #fff3cd !important; }
.monitor { background: #d4edda !important; }
.action-disable { color: #e74c3c; font-weight: bold; }
.action-review  { color: #e67e22; font-weight: bold; }
.action-monitor { color: #27ae60; font-weight: bold; }
</style></head><body>
<h1>Stale Accounts Report — $reportDate</h1>
<div class="summary">
  <span>Total Scanned: <strong>$($allUsers.Count)</strong></span>
  <span>Stale ($InactiveDays+ days): <strong>$($results.Count)</strong></span>
  <span>Recommend DISABLE (180+d): <strong>$(($results | Where-Object {$_.RecommendedAction -eq 'DISABLE'}).Count)</strong></span>
  <span>Recommend REVIEW (90-180d): <strong>$(($results | Where-Object {$_.RecommendedAction -eq 'REVIEW'}).Count)</strong></span>
</div>
<table>
<tr><th>User</th><th>SAM</th><th>Department</th><th>Manager</th><th>Last Logon</th><th>Days Inactive</th><th>Created</th><th>Action</th></tr>
"@
    foreach ($row in $results | Sort-Object DaysSinceLogon -Descending) {
        $rc  = $row.RecommendedAction.ToLower()
        $act = "<span class='action-$($rc.ToLower())'>$($row.RecommendedAction)</span>"
        $html += "<tr class='$rc'><td>$($row.DisplayName)</td><td>$($row.SAMAccount)</td><td>$($row.Department)</td><td>$($row.Manager)</td><td>$($row.LastLogon)</td><td>$($row.DaysSinceLogon)</td><td>$($row.AccountCreated)</td><td>$act</td></tr>`n"
    }
    $html += "</table></body></html>"
    $html | Out-File -FilePath $htmlPath -Encoding UTF8
    Write-Log "HTML report exported: $htmlPath" -Level SUCCESS

    Write-Log "=== STALE ACCOUNTS REPORT COMPLETE ===" -Level SUCCESS
    Write-Host "`nStale Accounts Summary:" -ForegroundColor Cyan
    [PSCustomObject]@{
        TotalScanned  = $allUsers.Count
        StaleFound    = $results.Count
        RecommendDisable = ($results | Where-Object { $_.RecommendedAction -eq 'DISABLE' }).Count
        RecommendReview  = ($results | Where-Object { $_.RecommendedAction -eq 'REVIEW' }).Count
        CSVReport     = $csvPath
        HTMLReport    = $htmlPath
    } | Format-List

} catch {
    Write-Log "FATAL ERROR: $($_.Exception.Message)" -Level ERROR
    throw
}
