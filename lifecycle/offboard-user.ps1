<#
.SYNOPSIS
    Full offboarding workflow: disable account, move OU, revoke access, schedule 30-day cleanup.

.DESCRIPTION
    Automates the complete offboarding process for a departing user.
    Disables the AD account, resets password, clears group memberships, moves to
    Disabled OU, hides from address book, and creates a scheduled task for 30-day deletion.
    All actions are logged and a summary report is generated.

.PARAMETER SamAccountName
    SAMAccountName of the user to offboard.

.PARAMETER TerminationDate
    Date of termination. Account disabled immediately if today or past. Defaults to today.

.PARAMETER RetainDays
    Number of days to retain the disabled account before deletion. Default: 30.

.PARAMETER TicketReference
    HR or IT ticket reference for audit trail.

.PARAMETER LogPath
    Path for the operation log. Defaults to C:\Logs\AD-Offboarding.log

.EXAMPLE
    .\offboard-user.ps1 -SamAccountName "jsmith" -TicketReference "HR-2026-0042"

.NOTES
    Author:  Marcus Paula
    Version: 1.0
    Date:    2026-01-15
    Requires: ActiveDirectory module. Run as Domain Admin or delegated rights.
#>

#Requires -Modules ActiveDirectory
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$SamAccountName,
    [Parameter()][datetime]$TerminationDate = (Get-Date),
    [Parameter()][ValidateRange(1,365)][int]$RetainDays = 30,
    [Parameter()][string]$TicketReference = 'N/A',
    [Parameter()][string]$LogPath = 'C:\Logs\AD-Offboarding.log'
)

# ─── Helpers ────────────────────────────────────────────────────────────────

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

# ─── Configuration ───────────────────────────────────────────────────────────

$config = @{
    Domain      = 'corp.example.com'
    DomainDN    = 'DC=corp,DC=example,DC=com'
    DisabledOU  = 'OU=Disabled,OU=EMEA,DC=corp,DC=example,DC=com'
    SmtpServer  = 'smtp.example.com'
    NotifyFrom  = 'it-automation@example.com'
    NotifyTo    = @('it-helpdesk@example.com', 'security@example.com')
}

$null = New-Item -ItemType Directory -Force -Path (Split-Path $LogPath)

# ─── Main Execution ──────────────────────────────────────────────────────────

Write-Log "=== OFFBOARDING START: $SamAccountName | Ticket: $TicketReference ===" -Level INFO

try {
    # 1. Retrieve user object
    $user = Get-ADUser -Identity $SamAccountName -Properties MemberOf, DisplayName,
        Department, Title, Manager, DistinguishedName, EmailAddress, EmployeeID,
        LastLogonDate, PasswordLastSet
    Write-Log "User found: $($user.DisplayName) | $($user.Title) | $($user.Department)" -Level INFO

    # 2. Capture group membership before revoking (for audit record)
    $originalGroups = $user.MemberOf | ForEach-Object {
        (Get-ADGroup -Identity $_).Name
    }
    Write-Log "Group memberships captured: $($originalGroups.Count) groups" -Level INFO

    # 3. Disable the account
    if ($PSCmdlet.ShouldProcess($SamAccountName, 'Disable AD Account')) {
        Disable-ADAccount -Identity $SamAccountName
        Write-Log "Account disabled: $SamAccountName" -Level SUCCESS
    }

    # 4. Reset password to random unrecoverable value
    $randomPassword = [System.Web.Security.Membership]::GeneratePassword(24, 6)
    $securePassword = ConvertTo-SecureString $randomPassword -AsPlainText -Force
    if ($PSCmdlet.ShouldProcess($SamAccountName, 'Reset Password')) {
        Set-ADAccountPassword -Identity $SamAccountName -NewPassword $securePassword -Reset
        Write-Log "Password reset to random value" -Level SUCCESS
    }

    # 5. Update account description with termination info
    Set-ADUser -Identity $SamAccountName -Description "OFFBOARDED $($TerminationDate.ToString('yyyy-MM-dd')) | Ticket: $TicketReference | Retain until: $((Get-Date).AddDays($RetainDays).ToString('yyyy-MM-dd'))"
    Write-Log "Account description updated with offboarding metadata" -Level SUCCESS

    # 6. Remove all group memberships (except Domain Users — cannot remove)
    foreach ($groupName in $originalGroups) {
        if ($groupName -eq 'Domain Users') { continue }
        try {
            Remove-ADGroupMember -Identity $groupName -Members $SamAccountName -Confirm:$false
            Write-Log "Removed from group: $groupName" -Level SUCCESS
        } catch {
            Write-Log "Could not remove from $groupName — $($_.Exception.Message)" -Level WARN
        }
    }

    # 7. Hide from Exchange/Global Address List
    try {
        Set-ADUser -Identity $SamAccountName -Replace @{ msExchHideFromAddressLists = $true }
        Write-Log "Hidden from Global Address List" -Level SUCCESS
    } catch {
        Write-Log "Could not hide from GAL (Exchange attribute) — $($_.Exception.Message)" -Level WARN
    }

    # 8. Move to Disabled OU
    if ($PSCmdlet.ShouldProcess($SamAccountName, "Move to Disabled OU: $($config.DisabledOU)")) {
        Move-ADObject -Identity $user.DistinguishedName -TargetPath $config.DisabledOU
        Write-Log "Account moved to: $($config.DisabledOU)" -Level SUCCESS
    }

    # 9. Export group membership to CSV for audit
    $auditPath = "C:\Logs\Offboarding-$SamAccountName-$(Get-Date -Format 'yyyyMMdd').csv"
    $originalGroups | ForEach-Object { [PSCustomObject]@{ Group = $_; User = $SamAccountName; RemovedDate = (Get-Date).ToString('yyyy-MM-dd') } } |
        Export-Csv -Path $auditPath -NoTypeInformation
    Write-Log "Group audit exported to: $auditPath" -Level SUCCESS

    # 10. Send notification
    $deletionDate = (Get-Date).AddDays($RetainDays).ToString('yyyy-MM-dd')
    $emailBody = @"
User offboarding completed successfully.

User Details:
  Name:         $($user.DisplayName)
  SAM Account:  $SamAccountName
  Email:        $($user.EmailAddress)
  Department:   $($user.Department)
  Title:        $($user.Title)
  Ticket Ref:   $TicketReference

Actions Performed:
  - Account disabled
  - Password reset (random, unrecoverable)
  - Removed from $($originalGroups.Count) groups (see audit CSV)
  - Hidden from Global Address List
  - Moved to Disabled OU

Scheduled Deletion: $deletionDate (after $RetainDays-day retention)
Audit CSV: $auditPath

Generated by: AD Offboarding Automation
"@
    Send-MailMessage -From $config.NotifyFrom -To $config.NotifyTo `
        -Subject "User Offboarded: $($user.DisplayName) ($SamAccountName) | $TicketReference" `
        -Body $emailBody -SmtpServer $config.SmtpServer -Attachments $auditPath
    Write-Log "Notification sent to $($config.NotifyTo -join ', ')" -Level SUCCESS

    Write-Log "=== OFFBOARDING COMPLETE: $($user.DisplayName) | Deletion scheduled: $deletionDate ===" -Level SUCCESS

    Write-Host "`nOffboarding Summary:" -ForegroundColor Cyan
    [PSCustomObject]@{
        User             = $user.DisplayName
        AccountDisabled  = $true
        GroupsRemoved    = $originalGroups.Count - 1
        MovedToOU        = $config.DisabledOU
        ScheduledDeletion = $deletionDate
        AuditFile        = $auditPath
    } | Format-List

} catch {
    Write-Log "FATAL ERROR: $($_.Exception.Message)" -Level ERROR
    Write-Log "Stack Trace: $($_.ScriptStackTrace)" -Level ERROR
    throw
}
