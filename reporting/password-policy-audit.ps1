<#
.SYNOPSIS
    Audit AD password policies against security best practices.

.DESCRIPTION
    Reviews the Default Domain Password Policy and any Fine-Grained Password Policies (PSOs).
    Compares each policy against configurable best-practice thresholds and flags deviations.
    Also reports accounts with: password never expires, password expired, empty passwords.
    Exports HTML + CSV.

.PARAMETER OutputPath
    Directory for report output.

.PARAMETER MinPasswordLength
    Minimum acceptable password length. Default: 12.

.PARAMETER MaxPasswordAgeDays
    Maximum acceptable password max age in days. Default: 90.

.PARAMETER MinPasswordHistory
    Minimum password history count. Default: 24.

.EXAMPLE
    .\password-policy-audit.ps1 -OutputPath "C:\Reports\PwdPolicy" -MinPasswordLength 14

.NOTES
    Author:  Marcus Paula
    Version: 1.0
    Date:    2026-01-15
    Requires: ActiveDirectory module, Domain Admin or read access.
#>

#Requires -Modules ActiveDirectory
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

[CmdletBinding()]
param(
    [Parameter()][string]$OutputPath = 'C:\Reports\PwdPolicyAudit',
    [Parameter()][int]$MinPasswordLength = 12,
    [Parameter()][int]$MaxPasswordAgeDays = 90,
    [Parameter()][int]$MinPasswordHistory = 24,
    [Parameter()][int]$MinLockoutThreshold = 5,
    [Parameter()][string]$LogPath = 'C:\Logs\AD-PwdPolicy.log'
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

function Test-PolicyCompliance {
    param($Policy, $PolicyName)
    $findings = [System.Collections.Generic.List[PSCustomObject]]::new()

    $checks = @(
        @{ Setting='MinPasswordLength';    Current=$Policy.MinPasswordLength;    Threshold=$MinPasswordLength;    Op='ge'; Desc='Minimum password length' }
        @{ Setting='MaxPasswordAge';        Current=[int]$Policy.MaxPasswordAge.TotalDays; Threshold=$MaxPasswordAgeDays; Op='le'; Desc='Max password age (days)' }
        @{ Setting='PasswordHistoryCount'; Current=$Policy.PasswordHistoryCount; Threshold=$MinPasswordHistory;  Op='ge'; Desc='Password history count' }
        @{ Setting='LockoutThreshold';     Current=$Policy.LockoutThreshold;     Threshold=$MinLockoutThreshold;  Op='le'; Desc='Account lockout threshold (attempts)' }
    )

    foreach ($c in $checks) {
        $pass = switch ($c.Op) {
            'ge' { $c.Current -ge $c.Threshold }
            'le' { $c.Current -gt 0 -and $c.Current -le $c.Threshold }
        }
        $findings.Add([PSCustomObject]@{
            PolicyName   = $PolicyName
            Setting      = $c.Desc
            CurrentValue = $c.Current
            RequiredValue = if ($c.Op -eq 'ge') { ">= $($c.Threshold)" } else { "<= $($c.Threshold)" }
            Compliant    = $pass
            Severity     = if (-not $pass) { if ($c.Setting -in 'MinPasswordLength','LockoutThreshold') { 'HIGH' } else { 'MEDIUM' } } else { 'OK' }
        })
    }

    # Complexity
    $findings.Add([PSCustomObject]@{
        PolicyName    = $PolicyName
        Setting       = 'Password Complexity Enabled'
        CurrentValue  = $Policy.ComplexityEnabled
        RequiredValue = 'True'
        Compliant     = $Policy.ComplexityEnabled
        Severity      = if (-not $Policy.ComplexityEnabled) { 'HIGH' } else { 'OK' }
    })

    # Reversible encryption
    $findings.Add([PSCustomObject]@{
        PolicyName    = $PolicyName
        Setting       = 'Reversible Encryption Disabled'
        CurrentValue  = -not $Policy.ReversibleEncryptionEnabled
        RequiredValue = 'True (disabled)'
        Compliant     = -not $Policy.ReversibleEncryptionEnabled
        Severity      = if ($Policy.ReversibleEncryptionEnabled) { 'CRITICAL' } else { 'OK' }
    })

    return $findings
}

$null = New-Item -ItemType Directory -Force -Path $OutputPath
$null = New-Item -ItemType Directory -Force -Path (Split-Path $LogPath)

$reportDate = Get-Date -Format 'yyyy-MM-dd'
$csvPath    = Join-Path $OutputPath "PwdPolicyAudit-$reportDate.csv"
$htmlPath   = Join-Path $OutputPath "PwdPolicyAudit-$reportDate.html"

Write-Log "=== PASSWORD POLICY AUDIT START | $reportDate ===" -Level INFO

try {
    $allFindings = [System.Collections.Generic.List[PSCustomObject]]::new()

    # Default Domain Policy
    $ddp = Get-ADDefaultDomainPasswordPolicy
    Write-Log "Default Domain Policy retrieved" -Level INFO
    Test-PolicyCompliance -Policy $ddp -PolicyName 'Default Domain Policy' | ForEach-Object { $allFindings.Add($_) }

    # Fine-Grained Password Policies
    $psos = Get-ADFineGrainedPasswordPolicy -Filter * -ErrorAction SilentlyContinue
    if ($psos) {
        foreach ($pso in $psos) {
            Write-Log "PSO found: $($pso.Name) | Precedence: $($pso.Precedence)" -Level INFO
            Test-PolicyCompliance -Policy $pso -PolicyName "PSO: $($pso.Name)" | ForEach-Object { $allFindings.Add($_) }
        }
    } else {
        Write-Log "No Fine-Grained Password Policies found" -Level INFO
    }

    # Account-level checks
    Write-Log "Scanning user accounts for password anomalies..." -Level INFO
    $users = Get-ADUser -Filter { Enabled -eq $true } -Properties PasswordNeverExpires, PasswordExpired,
        PasswordLastSet, PasswordNotRequired, Department

    $pwdNeverExpires = $users | Where-Object { $_.PasswordNeverExpires }
    $pwdExpired      = $users | Where-Object { $_.PasswordExpired }
    $pwdNotRequired  = $users | Where-Object { $_.PasswordNotRequired }
    $noPwdSet        = $users | Where-Object { -not $_.PasswordLastSet }

    Write-Log "PwdNeverExpires: $($pwdNeverExpires.Count) | PwdExpired: $($pwdExpired.Count) | PwdNotRequired: $($pwdNotRequired.Count) | NoPwdSet: $($noPwdSet.Count)" -Level WARN

    $allFindings | Export-Csv -Path $csvPath -NoTypeInformation
    Write-Log "CSV exported: $csvPath" -Level SUCCESS

    $failCount = ($allFindings | Where-Object { -not $_.Compliant }).Count
    $passCount = ($allFindings | Where-Object { $_.Compliant }).Count

    # HTML
    $html = @"
<!DOCTYPE html><html><head><meta charset="UTF-8"><title>Password Policy Audit — $reportDate</title>
<style>
body { font-family: Segoe UI, Arial, sans-serif; font-size: 13px; background: #f5f5f5; margin: 20px; }
h1 { color: #2c3e50; } h2 { color: #34495e; margin-top: 25px; }
.summary { background: #2c3e50; color: white; padding: 15px 20px; border-radius: 5px; margin-bottom: 20px; }
.summary span { margin-right: 30px; font-size: 14px; }
table { border-collapse: collapse; width: 100%; background: white; box-shadow: 0 1px 3px rgba(0,0,0,0.1); margin-bottom: 20px; }
th { background: #34495e; color: white; padding: 8px 12px; text-align: left; }
td { padding: 7px 12px; border-bottom: 1px solid #eee; }
tr:hover { background: #f9f9f9; }
.CRITICAL { background: #f8d7da !important; } .HIGH { background: #fce4d6 !important; }
.MEDIUM { background: #fff3cd !important; } .OK { background: #d4edda !important; }
.sev-CRITICAL { color: #721c24; font-weight: bold; } .sev-HIGH { color: #c0392b; font-weight: bold; }
.sev-MEDIUM { color: #856404; font-weight: bold; } .sev-OK { color: #27ae60; font-weight: bold; }
</style></head><body>
<h1>Password Policy Audit — $reportDate</h1>
<div class="summary">
  <span>Policies Checked: <strong>$($allFindings | Select-Object PolicyName -Unique | Measure-Object | Select-Object -ExpandProperty Count)</strong></span>
  <span>Total Checks: <strong>$($allFindings.Count)</strong></span>
  <span>Pass: <strong style="color:#2ecc71">$passCount</strong></span>
  <span>Fail: <strong style="color:#e74c3c">$failCount</strong></span>
</div>
<h2>Policy Compliance Checks</h2>
<table><tr><th>Policy</th><th>Setting</th><th>Current Value</th><th>Required</th><th>Compliant</th><th>Severity</th></tr>
"@
    foreach ($row in $allFindings | Sort-Object PolicyName, Severity) {
        $html += "<tr class='$($row.Severity)'><td>$($row.PolicyName)</td><td>$($row.Setting)</td><td>$($row.CurrentValue)</td><td>$($row.RequiredValue)</td><td>$($row.Compliant)</td><td><span class='sev-$($row.Severity)'>$($row.Severity)</span></td></tr>`n"
    }
    $html += "</table>"
    $html += "<h2>Account-Level Password Anomalies</h2>"
    $html += "<table><tr><th>Category</th><th>Count</th><th>Action</th></tr>"
    $html += "<tr><td>Password Never Expires</td><td>$($pwdNeverExpires.Count)</td><td>Review — justify or enforce policy</td></tr>"
    $html += "<tr><td>Password Currently Expired</td><td>$($pwdExpired.Count)</td><td>Force reset or disable if stale</td></tr>"
    $html += "<tr><td>Password Not Required</td><td>$($pwdNotRequired.Count)</td><td>Remediate immediately</td></tr>"
    $html += "<tr><td>Password Never Set</td><td>$($noPwdSet.Count)</td><td>Investigate — possible stale accounts</td></tr>"
    $html += "</table></body></html>"
    $html | Out-File -FilePath $htmlPath -Encoding UTF8
    Write-Log "HTML report exported: $htmlPath" -Level SUCCESS

    Write-Log "=== PASSWORD POLICY AUDIT COMPLETE | Pass: $passCount | Fail: $failCount ===" -Level SUCCESS

    Write-Host "`nPassword Policy Audit Summary:" -ForegroundColor Cyan
    [PSCustomObject]@{
        PoliciesAudited    = ($allFindings | Select-Object PolicyName -Unique | Measure-Object).Count
        TotalChecks        = $allFindings.Count
        Passed             = $passCount
        Failed             = $failCount
        PwdNeverExpires    = $pwdNeverExpires.Count
        PwdExpired         = $pwdExpired.Count
        PwdNotRequired     = $pwdNotRequired.Count
        CSVReport          = $csvPath
        HTMLReport         = $htmlPath
    } | Format-List

} catch {
    Write-Log "FATAL ERROR: $($_.Exception.Message)" -Level ERROR
    throw
}
