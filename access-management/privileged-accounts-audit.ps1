<#
.SYNOPSIS
    Audit privileged AD accounts — Domain Admins, Enterprise Admins, Schema Admins, and custom privileged groups.

.DESCRIPTION
    Enumerates all members of high-privilege groups and reports on account health:
    last logon, password age, MFA status indicator, account enabled state.
    Flags accounts that violate best practices (no MFA, stale logon, old password, disabled).
    Exports HTML + CSV for security/audit review.

.PARAMETER AdditionalPrivGroups
    Additional group names to audit beyond the default privileged groups.

.PARAMETER OutputPath
    Directory for report files.

.PARAMETER PasswordAgeDays
    Flag accounts whose password is older than this many days. Default: 90.

.PARAMETER LogonStaleDays
    Flag accounts not logged in for this many days. Default: 60.

.EXAMPLE
    .\privileged-accounts-audit.ps1 -OutputPath "C:\Reports\PrivAudit" -PasswordAgeDays 60

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
    [Parameter()][string[]]$AdditionalPrivGroups = @(),
    [Parameter()][string]$OutputPath = 'C:\Reports\PrivilegedAudit',
    [Parameter()][int]$PasswordAgeDays = 90,
    [Parameter()][int]$LogonStaleDays = 60,
    [Parameter()][string]$LogPath = 'C:\Logs\AD-PrivAudit.log'
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

$reportDate      = Get-Date -Format 'yyyy-MM-dd'
$passwordCutoff  = (Get-Date).AddDays(-$PasswordAgeDays)
$logonCutoff     = (Get-Date).AddDays(-$LogonStaleDays)
$csvPath         = Join-Path $OutputPath "PrivAudit-$reportDate.csv"
$htmlPath        = Join-Path $OutputPath "PrivAudit-$reportDate.html"

$defaultPrivGroups = @('Domain Admins', 'Enterprise Admins', 'Schema Admins',
    'Administrators', 'Account Operators', 'Backup Operators', 'Server Operators')
$allPrivGroups = ($defaultPrivGroups + $AdditionalPrivGroups) | Sort-Object -Unique

Write-Log "=== PRIVILEGED ACCOUNTS AUDIT START | $reportDate ===" -Level INFO
Write-Log "Groups in scope: $($allPrivGroups -join ', ')" -Level INFO

try {
    $results = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($groupName in $allPrivGroups) {
        $group = Get-ADGroup -Filter { Name -eq $groupName } -ErrorAction SilentlyContinue
        if (-not $group) { Write-Log "Group not found: $groupName — skipping" -Level WARN; continue }

        $members = Get-ADGroupMember -Identity $group -Recursive |
            Where-Object { $_.objectClass -eq 'user' } | Sort-Object Name

        Write-Log "Group: $groupName | Members: $($members.Count)" -Level INFO

        foreach ($m in $members) {
            $u = Get-ADUser -Identity $m.SamAccountName -Properties LastLogonDate,
                PasswordLastSet, Enabled, Department, Title, EmailAddress,
                PasswordNeverExpires, LockedOut, SmartcardLogonRequired

            $pwdStale   = $u.PasswordLastSet -lt $passwordCutoff -or -not $u.PasswordLastSet
            $logonStale = $u.LastLogonDate -lt $logonCutoff -or -not $u.LastLogonDate
            $flags      = @()
            if ($pwdStale)              { $flags += 'OLD_PASSWORD' }
            if ($logonStale)            { $flags += 'STALE_LOGON' }
            if (-not $u.Enabled)        { $flags += 'DISABLED' }
            if ($u.PasswordNeverExpires){ $flags += 'PWD_NEVER_EXPIRES' }
            if ($u.LockedOut)           { $flags += 'LOCKED' }
            if (-not $u.SmartcardLogonRequired) { $flags += 'NO_SMARTCARD_REQUIRED' }

            $results.Add([PSCustomObject]@{
                PrivilegedGroup     = $groupName
                DisplayName         = $u.DisplayName
                SAMAccount          = $u.SamAccountName
                Email               = $u.EmailAddress
                Department          = $u.Department
                Title               = $u.Title
                AccountEnabled      = $u.Enabled
                LockedOut           = $u.LockedOut
                LastLogon           = if ($u.LastLogonDate) { $u.LastLogonDate.ToString('yyyy-MM-dd') } else { 'Never' }
                PasswordLastSet     = if ($u.PasswordLastSet) { $u.PasswordLastSet.ToString('yyyy-MM-dd') } else { 'Never' }
                PwdNeverExpires     = $u.PasswordNeverExpires
                SmartcardRequired   = $u.SmartcardLogonRequired
                RiskFlags           = if ($flags) { $flags -join ' | ' } else { 'CLEAN' }
                RiskCount           = $flags.Count
                AuditDate           = $reportDate
            })
        }
    }

    $results | Export-Csv -Path $csvPath -NoTypeInformation
    Write-Log "CSV exported: $csvPath ($($results.Count) records)" -Level SUCCESS

    $flaggedCount = ($results | Where-Object { $_.RiskCount -gt 0 }).Count
    $cleanCount   = ($results | Where-Object { $_.RiskCount -eq 0 }).Count

    # HTML report
    $html = @"
<!DOCTYPE html><html><head><meta charset="UTF-8">
<title>Privileged Accounts Audit — $reportDate</title>
<style>
body { font-family: Segoe UI, Arial, sans-serif; font-size: 13px; background: #f5f5f5; margin: 20px; }
h1 { color: #c0392b; } .summary { background: #2c3e50; color: white; padding: 15px 20px; border-radius: 5px; margin-bottom: 20px; }
.summary span { margin-right: 30px; font-size: 14px; }
table { border-collapse: collapse; width: 100%; background: white; box-shadow: 0 1px 3px rgba(0,0,0,0.1); margin-bottom: 30px; }
th { background: #c0392b; color: white; padding: 8px 12px; text-align: left; font-size: 12px; }
td { padding: 7px 12px; border-bottom: 1px solid #eee; }
tr:hover { background: #f9f9f9; }
.risk-high { background: #f8d7da !important; }
.risk-med  { background: #fff3cd !important; }
.clean { color: #27ae60; font-weight: bold; }
.flag  { color: #e74c3c; font-weight: bold; }
</style></head><body>
<h1>Privileged Accounts Audit — $reportDate</h1>
<div class="summary">
  <span>Total Privileged Accounts: <strong>$($results.Count)</strong></span>
  <span>Groups Audited: <strong>$($allPrivGroups.Count)</strong></span>
  <span>Flagged: <strong>$flaggedCount</strong></span>
  <span>Clean: <strong>$cleanCount</strong></span>
</div>
<table>
<tr><th>Privileged Group</th><th>User</th><th>SAM</th><th>Dept</th><th>Enabled</th><th>Last Logon</th><th>Password Last Set</th><th>Risk Flags</th></tr>
"@
    foreach ($row in $results | Sort-Object RiskCount -Descending) {
        $rc = if ($row.RiskCount -gt 2) { 'risk-high' } elseif ($row.RiskCount -gt 0) { 'risk-med' } else { '' }
        $flags = if ($row.RiskFlags -eq 'CLEAN') { '<span class="clean">CLEAN</span>' } else { "<span class='flag'>$($row.RiskFlags)</span>" }
        $html += "<tr class='$rc'><td>$($row.PrivilegedGroup)</td><td>$($row.DisplayName)</td><td>$($row.SAMAccount)</td><td>$($row.Department)</td><td>$($row.AccountEnabled)</td><td>$($row.LastLogon)</td><td>$($row.PasswordLastSet)</td><td>$flags</td></tr>`n"
    }
    $html += "</table></body></html>"
    $html | Out-File -FilePath $htmlPath -Encoding UTF8
    Write-Log "HTML report exported: $htmlPath" -Level SUCCESS

    Write-Log "=== PRIVILEGED AUDIT COMPLETE | Flagged: $flaggedCount / $($results.Count) ===" -Level SUCCESS

    Write-Host "`nPrivileged Audit Summary:" -ForegroundColor Cyan
    [PSCustomObject]@{
        TotalPrivAccounts = $results.Count
        GroupsAudited     = $allPrivGroups.Count
        Flagged           = $flaggedCount
        Clean             = $cleanCount
        CSVReport         = $csvPath
        HTMLReport        = $htmlPath
    } | Format-List

} catch {
    Write-Log "FATAL ERROR: $($_.Exception.Message)" -Level ERROR
    throw
}
