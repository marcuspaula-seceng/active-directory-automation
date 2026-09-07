<#
.SYNOPSIS
    Weekly AD health report — locked, disabled, expired, and no-logon accounts in one view.

.DESCRIPTION
    Generates a comprehensive weekly Active Directory health dashboard.
    Covers: locked accounts, recently disabled accounts, expired accounts,
    accounts with no logon in 60+ days, password expiry warnings (14-day window).
    Exports HTML dashboard and CSV. Designed for weekly IT ops review.

.PARAMETER OutputPath
    Directory for report files.

.PARAMETER SmtpRecipients
    Email recipients for the weekly report (comma-separated or array).

.PARAMETER SendReport
    If specified, emails the HTML report.

.EXAMPLE
    .\ad-health-report.ps1 -OutputPath "C:\Reports\WeeklyHealth" -SendReport -SmtpRecipients "it-team@example.com"

.NOTES
    Author:  Marcus Paula
    Version: 1.0
    Date:    2026-01-15
    Requires: ActiveDirectory module.
#>

#Requires -Modules ActiveDirectory

[CmdletBinding()]
param(
    [Parameter()][string]$OutputPath = 'C:\Reports\ADHealth',
    [Parameter()][string[]]$SmtpRecipients = @('it-helpdesk@example.com'),
    [Parameter()][switch]$SendReport,
    [Parameter()][string]$LogPath = 'C:\Logs\AD-HealthReport.log'
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

$config = @{ SmtpServer = 'smtp.example.com'; NotifyFrom = 'it-automation@example.com' }
$null = New-Item -ItemType Directory -Force -Path $OutputPath
$null = New-Item -ItemType Directory -Force -Path (Split-Path $LogPath)

$reportDate   = Get-Date -Format 'yyyy-MM-dd'
$staleLogon   = (Get-Date).AddDays(-60)
$pwdWarnDate  = (Get-Date).AddDays(14)
$htmlPath     = Join-Path $OutputPath "ADHealth-$reportDate.html"
$csvPath      = Join-Path $OutputPath "ADHealth-$reportDate.csv"

Write-Log "=== AD HEALTH REPORT START | $reportDate ===" -Level INFO

try {
    $allUsers = Get-ADUser -Filter * -Properties LastLogonDate, LockedOut, Enabled,
        AccountExpirationDate, PasswordExpired, PasswordLastSet, PasswordNeverExpires,
        Department, Title, EmailAddress, WhenChanged, BadLogonCount |
        Where-Object { $_.DistinguishedName -notlike '*CN=Users*' -or $_.SamAccountName -notlike 'krbtgt*' }

    Write-Log "Total accounts in scope: $($allUsers.Count)" -Level INFO

    $locked   = $allUsers | Where-Object { $_.LockedOut }
    $disabled = $allUsers | Where-Object { -not $_.Enabled }
    $expired  = $allUsers | Where-Object { $_.AccountExpirationDate -and $_.AccountExpirationDate -lt (Get-Date) }
    $noLogon  = $allUsers | Where-Object { $_.Enabled -and ((-not $_.LastLogonDate) -or $_.LastLogonDate -lt $staleLogon) }
    $pwdExpireSoon = $allUsers | Where-Object {
        $_.Enabled -and $_.PasswordLastSet -and -not $_.PasswordNeverExpires -and
        ($_.PasswordLastSet.AddDays(90) -lt $pwdWarnDate)
    }

    Write-Log "Locked: $($locked.Count) | Disabled: $($disabled.Count) | Expired: $($expired.Count) | No Logon 60d: $($noLogon.Count) | Pwd Expiring: $($pwdExpireSoon.Count)" -Level WARN

    # Export combined CSV
    $csvData = @()
    $csvData += $locked   | Select-Object @{N='Category';E={'Locked'}}, DisplayName, SamAccountName, Department, @{N='LastLogon';E={$_.LastLogonDate}}
    $csvData += $disabled | Select-Object @{N='Category';E={'Disabled'}}, DisplayName, SamAccountName, Department, @{N='LastLogon';E={$_.LastLogonDate}}
    $csvData += $expired  | Select-Object @{N='Category';E={'Expired'}}, DisplayName, SamAccountName, Department, @{N='LastLogon';E={$_.LastLogonDate}}
    $csvData += $noLogon  | Select-Object @{N='Category';E={'NoLogon60d'}}, DisplayName, SamAccountName, Department, @{N='LastLogon';E={$_.LastLogonDate}}
    $csvData | Export-Csv -Path $csvPath -NoTypeInformation
    Write-Log "CSV exported: $csvPath" -Level SUCCESS

    # Build HTML
    function ConvertTo-HtmlTable {
        param([object[]]$Data, [string[]]$Columns)
        if (-not $Data -or $Data.Count -eq 0) { return '<p style="color:#27ae60"><strong>None — all clear.</strong></p>' }
        $tbl = '<table><tr>' + ($Columns | ForEach-Object { "<th>$_</th>" }) -join '' + '</tr>'
        foreach ($row in $Data) {
            $tbl += '<tr>' + ($Columns | ForEach-Object { "<td>$($row.$_)</td>" }) -join '' + '</tr>'
        }
        $tbl += '</table>'
        return $tbl
    }

    $style = @"
<style>
body { font-family: Segoe UI, Arial, sans-serif; font-size: 13px; background: #f5f5f5; margin: 20px; }
h1 { color: #2c3e50; } h2 { color: #34495e; margin-top: 25px; border-bottom: 2px solid #bdc3c7; padding-bottom: 5px; }
.summary { display: flex; gap: 20px; flex-wrap: wrap; margin-bottom: 25px; }
.stat { background: #2c3e50; color: white; padding: 15px 20px; border-radius: 5px; min-width: 120px; text-align: center; }
.stat .num { font-size: 28px; font-weight: bold; }
.stat .lbl { font-size: 11px; opacity: 0.8; }
.red .num { color: #e74c3c; } .orange .num { color: #f39c12; } .green .num { color: #2ecc71; }
table { border-collapse: collapse; width: 100%; background: white; box-shadow: 0 1px 3px rgba(0,0,0,0.1); margin-bottom: 15px; }
th { background: #34495e; color: white; padding: 8px 12px; text-align: left; font-size: 12px; }
td { padding: 7px 12px; border-bottom: 1px solid #eee; } tr:hover { background: #f9f9f9; }
</style>
"@

    $html = @"
<!DOCTYPE html><html><head><meta charset="UTF-8"><title>AD Health Report — $reportDate</title>$style</head><body>
<h1>Active Directory Health Report — $reportDate</h1>
<div class="summary">
  <div class="stat red"><div class="num">$($locked.Count)</div><div class="lbl">Locked</div></div>
  <div class="stat orange"><div class="num">$($disabled.Count)</div><div class="lbl">Disabled</div></div>
  <div class="stat orange"><div class="num">$($expired.Count)</div><div class="lbl">Expired</div></div>
  <div class="stat orange"><div class="num">$($noLogon.Count)</div><div class="lbl">No Logon 60d</div></div>
  <div class="stat red"><div class="num">$($pwdExpireSoon.Count)</div><div class="lbl">Pwd Expiring 14d</div></div>
  <div class="stat green"><div class="num">$($allUsers.Count)</div><div class="lbl">Total Accounts</div></div>
</div>
<h2>Locked Accounts ($($locked.Count))</h2>
$(ConvertTo-HtmlTable -Data ($locked | Select-Object DisplayName, SamAccountName, Department, BadLogonCount, @{N='LastLogon';E={$_.LastLogonDate}}) -Columns @('DisplayName','SamAccountName','Department','BadLogonCount','LastLogon'))
<h2>Disabled Accounts ($($disabled.Count))</h2>
$(ConvertTo-HtmlTable -Data ($disabled | Select-Object DisplayName, SamAccountName, Department, @{N='LastLogon';E={$_.LastLogonDate}}) -Columns @('DisplayName','SamAccountName','Department','LastLogon'))
<h2>Expired Accounts ($($expired.Count))</h2>
$(ConvertTo-HtmlTable -Data ($expired | Select-Object DisplayName, SamAccountName, Department, @{N='ExpiredDate';E={$_.AccountExpirationDate}}) -Columns @('DisplayName','SamAccountName','Department','ExpiredDate'))
<h2>No Logon in 60+ Days ($($noLogon.Count))</h2>
$(ConvertTo-HtmlTable -Data ($noLogon | Select-Object DisplayName, SamAccountName, Department, @{N='LastLogon';E={$_.LastLogonDate}} | Sort-Object LastLogon) -Columns @('DisplayName','SamAccountName','Department','LastLogon'))
<h2>Password Expiring Within 14 Days ($($pwdExpireSoon.Count))</h2>
$(ConvertTo-HtmlTable -Data ($pwdExpireSoon | Select-Object DisplayName, SamAccountName, Department, @{N='PwdLastSet';E={$_.PasswordLastSet}}, EmailAddress) -Columns @('DisplayName','SamAccountName','Department','PwdLastSet','EmailAddress'))
</body></html>
"@
    $html | Out-File -FilePath $htmlPath -Encoding UTF8
    Write-Log "HTML health report exported: $htmlPath" -Level SUCCESS

    if ($SendReport) {
        Send-MailMessage -From $config.NotifyFrom -To $SmtpRecipients `
            -Subject "AD Health Report — $reportDate | Locked:$($locked.Count) Disabled:$($disabled.Count) NoLogon60d:$($noLogon.Count)" `
            -Body "Weekly AD health report attached." -Attachments $htmlPath, $csvPath -SmtpServer $config.SmtpServer
        Write-Log "Report emailed to: $($SmtpRecipients -join ', ')" -Level SUCCESS
    }

    Write-Log "=== AD HEALTH REPORT COMPLETE ===" -Level SUCCESS

} catch {
    Write-Log "FATAL ERROR: $($_.Exception.Message)" -Level ERROR
    throw
}
