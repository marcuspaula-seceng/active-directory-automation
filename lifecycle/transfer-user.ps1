<#
.SYNOPSIS
    Transfer a user between departments or sites — updates AD attributes and group memberships.

.DESCRIPTION
    Automates inter-departmental or inter-site user transfers.
    Updates OU placement, department/title attributes, manager, and group memberships
    (removes old site/dept groups, assigns new ones). Logs all changes and notifies IT.

.PARAMETER SamAccountName
    SAMAccountName of the user being transferred.

.PARAMETER NewDepartment
    New department name.

.PARAMETER NewSite
    New site location: Dublin, Madrid, or Milan.

.PARAMETER NewTitle
    New job title (optional — keeps current if not specified).

.PARAMETER NewManager
    SAMAccountName of the new manager (optional).

.PARAMETER TicketReference
    HR or IT ticket reference for audit trail.

.PARAMETER LogPath
    Path for the operation log. Defaults to C:\Logs\AD-Transfers.log

.EXAMPLE
    .\transfer-user.ps1 -SamAccountName "jsmith" -NewDepartment "Security" -NewSite "Dublin" -NewTitle "Security Engineer" -NewManager "tdavis" -TicketReference "HR-2026-0089"

.NOTES
    Author:  Marcus Paula
    Version: 1.0
    Date:    2026-01-15
    Requires: ActiveDirectory module.
#>

#Requires -Modules ActiveDirectory

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$SamAccountName,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$NewDepartment,
    [Parameter(Mandatory)][ValidateSet('Dublin','Madrid','Milan')][string]$NewSite,
    [Parameter()][string]$NewTitle,
    [Parameter()][string]$NewManager,
    [Parameter()][string]$TicketReference = 'N/A',
    [Parameter()][string]$LogPath = 'C:\Logs\AD-Transfers.log'
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
    Domain    = 'corp.example.com'
    DomainDN  = 'DC=corp,DC=example,DC=com'
    BaseOU    = 'OU=Users,OU=EMEA'
    SmtpServer = 'smtp.example.com'
    NotifyFrom = 'it-automation@example.com'
    NotifyTo   = 'it-helpdesk@example.com'
    SiteGroups = @{
        Dublin = @('GRP-Dublin-Users', 'GRP-VPN-EMEA', 'GRP-Office365')
        Madrid = @('GRP-Madrid-Users', 'GRP-VPN-EMEA', 'GRP-Office365')
        Milan  = @('GRP-Milan-Users',  'GRP-VPN-EMEA', 'GRP-Office365')
    }
}

$null = New-Item -ItemType Directory -Force -Path (Split-Path $LogPath)

Write-Log "=== TRANSFER START: $SamAccountName | Ticket: $TicketReference ===" -Level INFO

try {
    $user = Get-ADUser -Identity $SamAccountName -Properties MemberOf, DisplayName,
        Department, Title, Office, Manager, DistinguishedName
    Write-Log "User found: $($user.DisplayName) | From: $($user.Department) / $($user.Office)" -Level INFO

    # Snapshot current state for audit
    $previousState = [PSCustomObject]@{
        Department = $user.Department
        Site       = $user.Office
        Title      = $user.Title
        OU         = $user.DistinguishedName
        Groups     = ($user.MemberOf | ForEach-Object { (Get-ADGroup -Identity $_).Name }) -join ', '
    }

    # Determine new OU
    $newOU = "OU=$NewSite,$($config.BaseOU),$($config.DomainDN)"
    $null = Get-ADOrganizationalUnit -Identity $newOU
    $newSiteGroups = $config.SiteGroups[$NewSite]
    foreach ($group in $newSiteGroups) {
        $null = Get-ADGroup -Identity $group
    }
    $oldDeptGroup = "GRP-Dept-$($user.Department -replace '\s','-')"
    $newDeptGroup = "GRP-Dept-$($NewDepartment -replace '\s','-')"
    $null = Get-ADGroup -Identity $newDeptGroup

    # Build attribute update hash
    $updateParams = @{ Department = $NewDepartment; Office = $NewSite }
    if ($NewTitle)   { $updateParams.Title   = $NewTitle }
    if ($NewManager) {
        $mgr = Get-ADUser -Identity $NewManager -Properties DisplayName
        $updateParams.Manager = $mgr.DistinguishedName
        Write-Log "New manager: $($mgr.DisplayName)" -Level INFO
    }

    if (-not $PSCmdlet.ShouldProcess($SamAccountName, "Transfer attributes, OU and group memberships to $NewDepartment / $NewSite")) {
        Write-Log 'Transfer not applied; no directory changes or notification performed.' -Level INFO
        return
    }
    $warnings = @()

    # Update attributes only after validating the destination, manager and groups.
    Set-ADUser -Identity $SamAccountName @updateParams
    Write-Log "Attributes updated: $($updateParams.Keys -join ', ')" -Level SUCCESS

    # Move OU if site changed
    if ($NewSite -ne $user.Office) {
        Move-ADObject -Identity $user.DistinguishedName -TargetPath $newOU
        Write-Log "Moved to new OU: $newOU" -Level SUCCESS
    }

    # Remove old site-specific groups
    $oldSiteGroups = @()
    if ($user.Office -and $NewSite -ne $user.Office -and $config.SiteGroups.ContainsKey([string]$user.Office)) {
        $oldSiteGroups = @($config.SiteGroups[$user.Office] | Where-Object { $_ -notlike '*VPN*' -and $_ -notlike '*Office365*' })
    }
    foreach ($group in $oldSiteGroups) {
        try {
            Remove-ADGroupMember -Identity $group -Members $SamAccountName -Confirm:$false
            Write-Log "Removed from old site group: $group" -Level SUCCESS
        } catch {
            $warnings += "Could not remove group: $group"
            Write-Log "Could not remove from $group — $($_.Exception.Message)" -Level WARN
        }
    }

    # Assign new site-specific groups
    foreach ($group in $newSiteGroups) {
        try {
            Add-ADGroupMember -Identity $group -Members $SamAccountName
            Write-Log "Added to new site group: $group" -Level SUCCESS
        } catch {
            $warnings += "Could not add group: $group"
            Write-Log "Could not add to $group — $($_.Exception.Message)" -Level WARN
        }
    }

    # Swap department group only when the department changes.
    if ($oldDeptGroup -ne $newDeptGroup) {
        try {
            Remove-ADGroupMember -Identity $oldDeptGroup -Members $SamAccountName -Confirm:$false
            Write-Log "Removed from old dept group: $oldDeptGroup" -Level SUCCESS
        } catch {
            $warnings += "Could not remove department group: $oldDeptGroup"
            Write-Log "Could not remove from $oldDeptGroup — $($_.Exception.Message)" -Level WARN
        }
        try {
            Add-ADGroupMember -Identity $newDeptGroup -Members $SamAccountName
            Write-Log "Added to new dept group: $newDeptGroup" -Level SUCCESS
        } catch {
            $warnings += "Could not add department group: $newDeptGroup"
            Write-Log "Could not add to $newDeptGroup — $($_.Exception.Message)" -Level WARN
        }
    }
    $status = if ($warnings.Count) { 'Partial failure - manual follow-up required' } else { 'Completed' }

    # Notify
    $emailBody = @"
User transfer status: $status

User: $($user.DisplayName) ($SamAccountName)
Ticket: $TicketReference

Previous State:
  Department: $($previousState.Department)
  Site:       $($previousState.Site)
  Title:      $($previousState.Title)

Requested State (see warnings for incomplete group changes):
  Department: $NewDepartment
  Site:       $NewSite
  Title:      $(if ($NewTitle) { $NewTitle } else { $user.Title })

Warnings: $($warnings -join '; ')

Generated by: AD Transfer Automation
"@
    Send-MailMessage -From $config.NotifyFrom -To $config.NotifyTo `
        -Subject "User Transfer: $($user.DisplayName) → $NewDepartment / $NewSite | $TicketReference" `
        -Body $emailBody -SmtpServer $config.SmtpServer
    Write-Log "Notification sent" -Level SUCCESS

    $completionLevel = if ($warnings.Count) { 'WARN' } else { 'SUCCESS' }
    Write-Log "=== TRANSFER: $($user.DisplayName) → $NewDepartment / $NewSite | $status ===" -Level $completionLevel

    Write-Host "`nTransfer Summary:" -ForegroundColor Cyan
    [PSCustomObject]@{
        User      = $user.DisplayName
        OldSite   = $previousState.Site
        NewSite   = $NewSite
        OldDept   = $previousState.Department
        NewDept   = $NewDepartment
        NewOU     = $newOU
        Status    = $status
        Warnings  = $warnings
    } | Format-List

} catch {
    Write-Log "FATAL ERROR: $($_.Exception.Message)" -Level ERROR
    throw
}
