<#
.SYNOPSIS
    Provision an Active Directory user using delegated permissions and a runtime-supplied credential.

.DESCRIPTION
    Creates a user in an approved existing OU, validates the manager and group targets,
    assigns approved groups, and records the operation without writing secrets to logs.

    Security design:
    - no password is stored in source code;
    - target OUs must already exist and be delegated to the operator/service identity;
    - routine onboarding should not require Domain Admin;
    - destructive or privileged operations support -WhatIf/-Confirm;
    - failures stop execution and are logged.

.EXAMPLE
    $tempPassword = Read-Host 'Temporary password' -AsSecureString
    .\onboard-user.ps1 -FirstName 'Jane' -LastName 'Smith' -Department 'Engineering' `
        -Site 'Dublin' -Manager 'jdoe' -Title 'IT Engineer' -TemporaryPassword $tempPassword -WhatIf
#>

#Requires -Modules ActiveDirectory
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

[CmdletBinding(SupportsShouldProcess, ConfirmImpact='Medium')]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$FirstName,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$LastName,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Department,
    [Parameter(Mandatory)][ValidateSet('Dublin','Madrid','Milan')][string]$Site,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Manager,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Title,
    [Parameter(Mandatory)][SecureString]$TemporaryPassword,
    [Parameter()][datetime]$StartDate = (Get-Date),
    [Parameter()][string]$TicketReference,
    [Parameter()][string]$LogPath = 'C:\Logs\AD-Onboarding.log'
)

Import-Module "$PSScriptRoot/../lib/IdentityHelpers.psm1" -Force

function Write-Log {
    param([string]$Message, [ValidateSet('INFO','WARN','ERROR','SUCCESS')]$Level = 'INFO')
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $entry = "[$timestamp][$Level] $Message"
    $null = New-Item -ItemType Directory -Force -Path (Split-Path $LogPath)
    Add-Content -Path $LogPath -Value $entry
    Write-Host $entry
}

$config = @{
    Domain   = 'corp.example.com'
    DomainDN = 'DC=corp,DC=example,DC=com'
    SiteOUs  = @{
        Dublin = 'OU=Dublin,OU=Users,OU=EMEA,DC=corp,DC=example,DC=com'
        Madrid = 'OU=Madrid,OU=Users,OU=EMEA,DC=corp,DC=example,DC=com'
        Milan  = 'OU=Milan,OU=Users,OU=EMEA,DC=corp,DC=example,DC=com'
    }
    SiteGroups = @{
        Dublin = @('GRP-Dublin-Users','GRP-VPN-EMEA','GRP-Office365')
        Madrid = @('GRP-Madrid-Users','GRP-VPN-EMEA','GRP-Office365')
        Milan  = @('GRP-Milan-Users','GRP-VPN-EMEA','GRP-Office365')
    }
}

Write-Log "=== ONBOARDING START: $FirstName $LastName ==="

try {
    $baseSam = ConvertTo-SafeSamAccountName -FirstName $FirstName -LastName $LastName
    $samAccount = $baseSam
    $suffix = 1

    while (Get-ADUser -Filter "SamAccountName -eq '$samAccount'" -ErrorAction SilentlyContinue) {
        $suffix++
        $suffixText = [string]$suffix
        $prefixLength = [Math]::Max(1, 20 - $suffixText.Length)
        $samAccount = ($baseSam.Substring(0, [Math]::Min($baseSam.Length, $prefixLength))) + $suffixText
    }

    $displayName = "$FirstName $LastName"
    $upn = "$samAccount@$($config.Domain)"
    $ouPath = $config.SiteOUs[$Site]

    $managerObj = Get-ADUser -Identity $Manager -Properties DisplayName
    $null = Get-ADOrganizationalUnit -Identity $ouPath

    foreach ($group in $config.SiteGroups[$Site]) {
        $null = Get-ADGroup -Identity $group
    }

    $deptGroup = "GRP-Dept-$($Department -replace '\s','-')"
    $deptGroupExists = $null -ne (Get-ADGroup -Identity $deptGroup -ErrorAction SilentlyContinue)

    $adParams = @{
        SamAccountName        = $samAccount
        UserPrincipalName     = $upn
        GivenName             = $FirstName
        Surname               = $LastName
        DisplayName           = $displayName
        Name                  = $displayName
        Department            = $Department
        Title                 = $Title
        Office                = $Site
        Manager               = $managerObj.DistinguishedName
        Path                  = $ouPath
        AccountPassword       = $TemporaryPassword
        ChangePasswordAtLogon = $true
        Enabled               = ($StartDate.Date -le (Get-Date).Date)
        Description           = "Provisioned by IT Automation$(if ($TicketReference) { ' | Ticket: ' + $TicketReference })"
    }

    if ($PSCmdlet.ShouldProcess($displayName, 'Create AD user and assign approved groups')) {
        New-ADUser @adParams

        foreach ($group in $config.SiteGroups[$Site]) {
            Add-ADGroupMember -Identity $group -Members $samAccount
        }

        if ($deptGroupExists) {
            Add-ADGroupMember -Identity $deptGroup -Members $samAccount
        }

        Write-Log "Provisioned account $(Get-RedactedIdentifier -Value $samAccount) in approved OU $ouPath" -Level SUCCESS
    }

    [PSCustomObject]@{
        DisplayName   = $displayName
        SAMAccount    = $samAccount
        UPN           = $upn
        OU            = $ouPath
        SiteGroups    = ($config.SiteGroups[$Site] -join ', ')
        DepartmentGrp = $(if ($deptGroupExists) { $deptGroup } else { 'Not assigned: group not found' })
        Ticket        = $TicketReference
        AccountReady  = ($StartDate.Date -le (Get-Date).Date)
    }
}
catch {
    Write-Log "FATAL ERROR: $($_.Exception.Message)" -Level ERROR
    throw
}
