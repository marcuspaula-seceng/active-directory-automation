<#
Offline regression checks for lifecycle reporting and refusal paths.
Every AD, mail and file-write command is replaced with an in-memory test double.
These checks do not validate a directory, SMTP delivery or password generation.
#>
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (Get-Module ActiveDirectory) { throw 'Run these isolated checks in a fresh PowerShell process.' }
if (-not ('System.Web.Security.Membership' -as [type])) {
    Add-Type 'namespace System.Web.Security { public static class Membership { public static string GeneratePassword(int length, int nonAlpha) { return "test-only-placeholder"; } } }'
}

$testModule = New-Module -Name ActiveDirectory -ScriptBlock {
    function Get-ADUser {
        [CmdletBinding()] param($Identity, $Properties)
        [PSCustomObject]@{ DisplayName='Test User'; Title='Engineer'; Department='Old'; Office='Madrid';
            DistinguishedName='CN=Test,OU=Madrid,OU=Users,OU=EMEA,DC=corp,DC=example,DC=com';
            MemberOf=@('GRP-Old', 'GRP-Fails'); EmailAddress='test@example.com' }
    }
    function Get-ADGroup { [CmdletBinding()] param($Identity) [PSCustomObject]@{Name=$Identity} }
    function Get-ADOrganizationalUnit {
        [CmdletBinding()] param($Identity)
        $global:LifecycleTestState.ValidatedOU = $Identity
        if ($global:LifecycleTestState.MissingOU) { throw 'Test: destination OU missing' }
    }
    function Disable-ADAccount { [CmdletBinding()] param($Identity) $global:LifecycleTestState.Writes++ }
    function Set-ADAccountPassword { [CmdletBinding()] param($Identity,$NewPassword,[switch]$Reset) $global:LifecycleTestState.Writes++ }
    function Set-ADUser {
        [CmdletBinding()] param($Identity,$Description,$Replace,$Department,$Office,$Title,$Manager)
        $global:LifecycleTestState.Writes++
        if ($Replace -and $global:LifecycleTestState.FailGAL) { throw 'Test: GAL failure' }
    }
    function Move-ADObject {
        [CmdletBinding()] param($Identity,$TargetPath)
        $global:LifecycleTestState.Writes++
        $global:LifecycleTestState.MovedTo = $TargetPath
    }
    function Remove-ADGroupMember {
        [CmdletBinding(SupportsShouldProcess)] param($Identity,$Members)
        $global:LifecycleTestState.Writes++
        if ($global:LifecycleTestState.FailGroups -and $Identity -in @('GRP-Fails','GRP-Dept-Old')) {
            throw 'Test: group removal failure'
        }
    }
    function Add-ADGroupMember { [CmdletBinding()] param($Identity,$Members) $global:LifecycleTestState.Writes++ }
    Export-ModuleMember -Function *
}
Import-Module $testModule

function New-Item { [CmdletBinding(SupportsShouldProcess)] param($ItemType,[switch]$Force,$Path) }
function Add-Content { [CmdletBinding(SupportsShouldProcess)] param($Path,$Value) }
function Export-Csv {
    [CmdletBinding()] param([Parameter(ValueFromPipeline)]$InputObject,$Path,[switch]$NoTypeInformation)
    process { $global:LifecycleTestState.Csv += $InputObject }
}
function Send-MailMessage {
    [CmdletBinding()] param($From,$To,$Subject,$Body,$SmtpServer,$Attachments)
    $global:LifecycleTestState.MailBody = $Body
}
function Reset-TestState {
    $global:LifecycleTestState = @{Writes=0; ValidatedOU=''; MovedTo=''; Csv=@(); MailBody='';
        MissingOU=$false; FailGAL=$false; FailGroups=$false}
}
function Assert-True($Value, $Message) { if (-not $Value) { throw "Assertion failed: $Message" } }

$offboard = Join-Path $PSScriptRoot '../lifecycle/offboard-user.ps1'
$transfer = Join-Path $PSScriptRoot '../lifecycle/transfer-user.ps1'
try {
    Reset-TestState
    $global:LifecycleTestState.FailGroups = $true
    $global:LifecycleTestState.FailGAL = $true
    & $offboard -SamAccountName 'testuser' -Confirm:$false | Out-Null
    Assert-True ($global:LifecycleTestState.MailBody -match 'Partial failure') 'partial offboarding must not report success'
    Assert-True ($global:LifecycleTestState.MailBody -match 'Removed from 1 groups') 'count only successful group removals'
    Assert-True ($global:LifecycleTestState.MailBody -match 'no deletion scheduled') 'retention is manual'
    $failed = @($global:LifecycleTestState.Csv | Where-Object Status -eq 'Failed')
    Assert-True ($failed.Count -eq 1 -and $null -eq $failed[0].RemovedDate) 'failed group removal must have no removal date'

    Reset-TestState
    & $offboard -SamAccountName 'testuser' -WhatIf | Out-Null
    Assert-True ($global:LifecycleTestState.Writes -eq 0 -and $global:LifecycleTestState.MailBody -eq '') 'WhatIf must not mutate or notify'

    Reset-TestState
    $caught = $false
    try { & $offboard -SamAccountName 'testuser' -TerminationDate (Get-Date).AddDays(1) -Confirm:$false | Out-Null } catch { $caught = $true }
    Assert-True ($caught -and $global:LifecycleTestState.Writes -eq 0) 'future termination must fail before changes'

    Reset-TestState
    $global:LifecycleTestState.MissingOU = $true
    $caught = $false
    try { & $transfer -SamAccountName 'testuser' -NewDepartment 'New' -NewSite 'Dublin' -Confirm:$false | Out-Null } catch { $caught = $true }
    Assert-True ($caught -and $global:LifecycleTestState.Writes -eq 0) 'missing target OU must fail before attribute updates'

    Reset-TestState
    $global:LifecycleTestState.FailGroups = $true
    & $transfer -SamAccountName 'testuser' -NewDepartment 'New' -NewSite 'Dublin' -Confirm:$false | Out-Null
    Assert-True ($global:LifecycleTestState.MovedTo -eq 'OU=Dublin,OU=Users,OU=EMEA,DC=corp,DC=example,DC=com') 'transfer OU order must match onboarding'
    Assert-True ($global:LifecycleTestState.MailBody -match 'Partial failure' -and $global:LifecycleTestState.MailBody -match 'GRP-Dept-Old') 'department-removal failure must be surfaced'

    Reset-TestState
    & $transfer -SamAccountName 'testuser' -NewDepartment 'New' -NewSite 'Dublin' -WhatIf | Out-Null
    Assert-True ($global:LifecycleTestState.Writes -eq 0 -and $global:LifecycleTestState.MailBody -eq '') 'transfer WhatIf must not mutate or notify'
    Write-Output 'PASS: six offline lifecycle regression scenarios'
} finally {
    Remove-Module $testModule
    Remove-Variable LifecycleTestState -Scope Global -ErrorAction SilentlyContinue
}
