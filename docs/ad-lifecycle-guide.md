# Active Directory User Lifecycle Guide

> Complete process documentation: from pre-hire provisioning to post-departure account deletion.
> Covers all stages with script references, decision points, and audit requirements.

---

## Overview

The user lifecycle in Active Directory spans four stages:

```
[Pre-Hire]  →  [Active Employment]  →  [Transfer]  →  [Offboarding]  →  [Deletion]
onboard-user.ps1    (ongoing ops)    transfer-user.ps1  offboard-user.ps1  (scheduled)
```

---

## Stage 1: Pre-Hire Provisioning (Onboarding)

**Trigger**: Signed offer letter + IT ticket from HR (e.g. Jira/ServiceNow)  
**Script**: `lifecycle/onboard-user.ps1`  
**SLA**: Account ready 48 hours before start date

### Required Information from HR

| Field | Source | Notes |
|-------|--------|-------|
| First Name / Last Name | Offer letter | Must match legal name |
| Department | HR system | Maps to OU and group assignment |
| Site | HR system | Dublin / Madrid / Milan |
| Manager | HR system | SAMAccountName required |
| Job Title | Offer letter | Used in AD Title attribute |
| Start Date | Offer letter | Account enabled on this date |

### Provisioning Checklist

- [ ] AD account created in correct OU
- [ ] SAMAccountName and UPN generated (format: `firstlast@corp.example.com`)
- [ ] Temporary password set — `ChangePasswordAtLogon = $true`
- [ ] Site security groups assigned (`GRP-[Site]-Users`, `GRP-VPN-EMEA`, `GRP-Office365`)
- [ ] Department group assigned (`GRP-Dept-[DeptName]`)
- [ ] Manager attribute set
- [ ] Notification sent to IT helpdesk and manager
- [ ] Hardware provisioned in ITAM system (separate process)
- [ ] Account start date verified — enabled on or after start date only

### SAMAccountName Convention

Format: `[first initial][lastname]` — e.g. Marcus Paula → `mpaula`  
Max length: 20 characters, lowercase, alphanumeric only  
Duplicate handling: append `2`, `3` etc. (e.g. `mpaula2`)

---

## Stage 2: Active Employment

### Regular Maintenance Tasks

| Task | Frequency | Script |
|------|-----------|--------|
| Stale account scan | Monthly | `access-management/stale-accounts-report.ps1` |
| Quarterly access review | Quarterly | `access-management/access-review.ps1` |
| Privileged account audit | Quarterly | `access-management/privileged-accounts-audit.ps1` |
| Weekly AD health check | Weekly | `reporting/ad-health-report.ps1` |
| Group membership snapshot | Weekly | `reporting/group-membership-report.ps1` |
| Password policy audit | Bi-annually | `reporting/password-policy-audit.ps1` |

### Access Changes During Employment

All access changes require:
1. IT ticket with manager approval
2. Documented business justification
3. Implementation tracked in ITAM/ITSM system

---

## Stage 3: User Transfer

**Trigger**: HR notification of internal transfer — ticket from HR  
**Script**: `lifecycle/transfer-user.ps1`  
**SLA**: Completed on transfer effective date

### Transfer Checklist

- [ ] New department, site, title, and manager confirmed in HR ticket
- [ ] AD attributes updated (Department, Office, Title, Manager)
- [ ] OU moved to new site OU (if site change)
- [ ] Old site groups removed; new site groups assigned
- [ ] Old department group removed; new department group assigned
- [ ] Previous state snapshot logged (for audit)
- [ ] Manager notified of completion

---

## Stage 4: Offboarding

**Trigger**: HR termination notification — IT ticket with last working day  
**Script**: `lifecycle/offboard-user.ps1`  
**SLA**: Account disabled by end of last working day (or immediately for involuntary termination)

### Offboarding Checklist

- [ ] Account disabled
- [ ] Password reset to random unrecoverable value
- [ ] All group memberships removed and exported to audit CSV
- [ ] Account hidden from Global Address List
- [ ] Account moved to `OU=Disabled,OU=EMEA`
- [ ] Description updated with termination date and ticket reference
- [ ] Audit CSV archived to `C:\Logs\Offboarding-[sam]-[date].csv`
- [ ] Notification sent to IT helpdesk and Security team
- [ ] Hardware collection confirmed with ITAM team (separate process)
- [ ] Data retention/mailbox hold — coordinate with Legal/Compliance if required
- [ ] 30-day retention countdown started

### Involuntary Termination (Immediate Action Required)

For involuntary separations, the following must happen **before** the employee is informed:
1. Account disabled
2. Remote sessions terminated
3. VPN access revoked
4. Badge access revoked (Physical Security — separate team)
5. Manager notified

---

## Stage 5: Account Deletion (30-Day Retention)

After 30-day retention period:

1. Verify no active legal hold or HR investigation
2. Export mailbox data to PST if required by Legal
3. Transfer file share ownership to manager or archive
4. Delete AD account
5. Update ITAM system — mark user as fully offboarded

**Default retention**: 30 days  
**Extended retention scenarios**: Active investigation, legal hold, compliance requirement

---

## Audit Trail

All lifecycle scripts generate:
- Log files in `C:\Logs\`
- CSV exports for each major action
- Email notifications to IT helpdesk and/or Security

These records support:
- SOX audit requirements
- ISO 27001 access control evidence
- GDPR data subject activity records
- Internal access review cycles

---

## Emergency Procedures

### Account Compromise — Immediate Disable
```powershell
Disable-ADAccount -Identity "[samAccountName]"
Get-ADUser -Identity "[samAccountName]" | Set-ADObject -Replace @{msExchHideFromAddressLists=$true}
# Then follow offboarding script for full revocation
```

### Locked Account Unlock
```powershell
Unlock-ADAccount -Identity "[samAccountName]"
# Check BadLogonCount — if high, investigate before unlocking
Get-ADUser -Identity "[samAccountName]" -Properties BadLogonCount, LockedOut | Select-Object DisplayName, BadLogonCount, LockedOut
```

---

*See also: [Naming Convention](naming-convention.md)*
