<#
.SYNOPSIS
    Full offboarding workflow: disable account, move OU, revoke access, record a manual retention review date.

.DESCRIPTION
    Automates the complete offboarding process for a departing user.
    Disables the AD account, resets password, clears group memberships, moves to
    Disabled OU, hides from address book, and records a retention review date. Deletion is a separate manual action.
    All actions are logged and a summary report is generated.

.PARAMETER SamAccountName
    SAMAccountName of the user to offboard.

.PARAMETER TerminationDate
    Date of termination. Today or a past date only; future dates are rejected before changes.

.PARAMETER RetainDays
    Days until manual retention review. No deletion task is created. Default: 30.

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

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$SamAccountName,
    [Parameter()][datetime]$TerminationDate = (Get-Date),
    [Parameter()][ValidateRange(1,365)][int]$RetainDays = 30,
    [Parameter()][string]$TicketReference = 'N/A',
    [Parameter()][string]$LogPath = 'C:\Logs\AD-Offboarding.log'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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
    if ($TerminationDate.Date -gt (Get-Date).Date) {
        throw 'Future termination dates are not scheduled. Run on the authorised termination date.'
    }

    # 1. Retrieve user object
    $user = Get-ADUser -Identity $SamAccountName -Properties MemberOf, DisplayName,
        Department, Title, Manager, DistinguishedName, EmailAddress, EmployeeID,
        LastLogonDate, PasswordLastSet
    Write-Log "User found: $($user.DisplayName) | $($user.Title) | $($user.Department)" -Level INFO

    # 2. Capture group membership before revoking (for audit record)
    $originalGroups = @($user.MemberOf | ForEach-Object {
        (Get-ADGroup -Identity $_).Name
    })
    Write-Log "Group memberships captured: $($originalGroups.Count) groups" -Level INFO

    # Validate the destination before making any directory changes.
    $null = Get-ADOrganizationalUnit -Identity $config.DisabledOU
    if (-not $PSCmdlet.ShouldProcess($SamAccountName, 'Disable account, reset password, remove groups and move to Disabled OU')) {
        Write-Log 'Offboarding not applied; no directory changes or notification performed.' -Level INFO
        return
    }
    $groupResults = @()
    $warnings = @()
    $hiddenFromGAL = $false
    $retentionReviewDate = (Get-Date).AddDays($RetainDays).ToString('yyyy-MM-dd')

    # 3. Disable the account
    Disable-ADAccount -Identity $SamAccountName
    Write-Log "Account disabled: $SamAccountName" -Level SUCCESS

    # 4. Reset password to random unrecoverable value
    $randomPassword = [System.Web.Security.Membership]::GeneratePassword(24, 6)
    $securePassword = ConvertTo-SecureString $randomPassword -AsPlainText -Force
    Set-ADAccountPassword -Identity $SamAccountName -NewPassword $securePassword -Reset
    Write-Log "Password reset to random value" -Level SUCCESS

    # 5. Update account description with termination info
    Set-ADUser -Identity $SamAccountName -Description "OFFBOARDED $($TerminationDate.ToString('yyyy-MM-dd')) | Ticket: $TicketReference | Manual retention review: $retentionReviewDate"
    Write-Log "Account description updated with offboarding metadata" -Level SUCCESS

    # 6. Remove all group memberships (except Domain Users — cannot remove)
    foreach ($groupName in $originalGroups) {
        $groupStatus = 'Retained'
        $removedDate = $null
        if ($groupName -ne 'Domain Users') {
            try {
                Remove-ADGroupMember -Identity $groupName -Members $SamAccountName -Confirm:$false
                Write-Log "Removed from group: $groupName" -Level SUCCESS
                $groupStatus = 'Removed'
                $removedDate = (Get-Date).ToString('yyyy-MM-dd')
            } catch {
                $groupStatus = 'Failed'
                $warnings += "Could not remove group: $groupName"
                Write-Log "Could not remove from $groupName — $($_.Exception.Message)" -Level WARN
            }
        }
        $groupResults += [PSCustomObject]@{
            Group = $groupName; User = $SamAccountName; Status = $groupStatus; RemovedDate = $removedDate
        }
    }

    # 7. Hide from Exchange/Global Address List
    try {
        Set-ADUser -Identity $SamAccountName -Replace @{ msExchHideFromAddressLists = $true }
        $hiddenFromGAL = $true
        Write-Log "Hidden from Global Address List" -Level SUCCESS
    } catch {
        $warnings += 'Could not hide from Global Address List'
        Write-Log "Could not hide from GAL (Exchange attribute) — $($_.Exception.Message)" -Level WARN
    }

    # 8. Move to Disabled OU
    Move-ADObject -Identity $user.DistinguishedName -TargetPath $config.DisabledOU
    Write-Log "Account moved to: $($config.DisabledOU)" -Level SUCCESS

    # 9. Export group membership to CSV for audit
    $auditPath = "C:\Logs\Offboarding-$SamAccountName-$(Get-Date -Format 'yyyyMMdd').csv"
    $groupResults | Export-Csv -Path $auditPath -NoTypeInformation
    $groupsRemoved = @($groupResults | Where-Object Status -eq 'Removed').Count
    $status = if ($warnings.Count) { 'Partial failure - manual follow-up required' } else { 'Completed' }
    Write-Log "Group audit exported to: $auditPath" -Level SUCCESS

    # 10. Send notification
    $emailBody = @"
User offboarding status: $status

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
  - Removed from $groupsRemoved groups (see per-group status in audit CSV)
  - Hidden from Global Address List: $hiddenFromGAL
  - Moved to Disabled OU

Manual retention review: $retentionReviewDate (after $RetainDays days; no deletion scheduled)
Warnings: $($warnings -join '; ')
Audit CSV: $auditPath

Generated by: AD Offboarding Automation
"@
    Send-MailMessage -From $config.NotifyFrom -To $config.NotifyTo `
        -Subject "User Offboarded: $($user.DisplayName) ($SamAccountName) | $TicketReference" `
        -Body $emailBody -SmtpServer $config.SmtpServer -Attachments $auditPath
    Write-Log "Notification sent to $($config.NotifyTo -join ', ')" -Level SUCCESS

    $completionLevel = if ($warnings.Count) { 'WARN' } else { 'SUCCESS' }
    Write-Log "=== OFFBOARDING: $($user.DisplayName) | $status | Manual retention review: $retentionReviewDate ===" -Level $completionLevel

    Write-Host "`nOffboarding Summary:" -ForegroundColor Cyan
    [PSCustomObject]@{
        User             = $user.DisplayName
        AccountDisabled  = $true
        GroupsRemoved    = $groupsRemoved
        Status           = $status
        Warnings         = $warnings
        HiddenFromGAL    = $hiddenFromGAL
        MovedToOU        = $config.DisabledOU
        RetentionReviewDate = $retentionReviewDate
        DeletionScheduled = $false
        AuditFile        = $auditPath
    } | Format-List

} catch {
    Write-Log "FATAL ERROR: $($_.Exception.Message)" -Level ERROR
    Write-Log "Stack Trace: $($_.ScriptStackTrace)" -Level ERROR
    throw
}
