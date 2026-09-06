# AD Naming Conventions

> Standards for Active Directory accounts, groups, and OUs.
> Consistent naming enables automation, reduces errors, and supports audit readability.

---

## User Accounts

### SAMAccountName

| Pattern | Format | Example |
|---------|--------|---------|
| Standard | `[firstinitial][lastname]` | Marcus Paula → `mpaula` |
| Duplicate | Append `2`, `3`... | `mpaula2` |
| Service accounts | `svc-[purpose]` | `svc-backup`, `svc-monitoring` |
| Admin accounts | `adm-[samAccountName]` | `adm-mpaula` |
| Test accounts | `tst-[purpose]` | `tst-deployment` |

**Rules:**
- Lowercase only
- No spaces or special characters
- Max 20 characters
- Alphanumeric only (a-z, 0-9, hyphens for service/admin accounts)

### UPN (User Principal Name)

Format: `[samAccountName]@corp.example.com`  
Example: `mpaula@corp.example.com`

### Display Name

Format: `[First Name] [Last Name]`  
Example: `Marcus Paula`

---

## Groups

### Security Groups

| Category | Format | Example |
|----------|--------|---------|
| Site groups | `GRP-[Site]-[Purpose]` | `GRP-Dublin-Users`, `GRP-Madrid-VPN` |
| Department groups | `GRP-Dept-[DepartmentName]` | `GRP-Dept-Engineering`, `GRP-Dept-Finance` |
| Application groups | `GRP-App-[AppName]-[Role]` | `GRP-App-SharePoint-ReadOnly` |
| Privileged groups | `GRP-Priv-[Purpose]` | `GRP-Priv-ServerAdmins` |
| Resource groups | `GRP-Res-[ResourceName]` | `GRP-Res-Printers-Floor3` |
| EMEA regional | `GRP-EMEA-[Purpose]` | `GRP-EMEA-VPN`, `GRP-EMEA-Office365` |

**Rules:**
- All caps prefix (GRP, DL, SG)
- PascalCase for names after the prefix separator
- No spaces — use hyphens
- Descriptive — name should indicate purpose without needing to open Properties

### Distribution Lists

Format: `DL-[Team/Purpose]@corp.example.com`  
Example: `DL-ITTeam@corp.example.com`, `DL-Dublin-Ops@corp.example.com`

---

## Organisational Units (OUs)

### Structure

```
DC=corp,DC=example,DC=com
├── OU=EMEA
│   ├── OU=Dublin
│   │   ├── OU=Users
│   │   ├── OU=Computers
│   │   └── OU=Groups
│   ├── OU=Madrid
│   │   ├── OU=Users
│   │   ├── OU=Computers
│   │   └── OU=Groups
│   ├── OU=Milan
│   │   ├── OU=Users
│   │   ├── OU=Computers
│   │   └── OU=Groups
│   └── OU=Disabled          ← Offboarded accounts
├── OU=ServiceAccounts        ← svc-* accounts
├── OU=AdminAccounts          ← adm-* accounts
└── OU=TestAccounts           ← tst-* accounts
```

### OU Naming

- PascalCase for geographic names: `Dublin`, `Madrid`, `Milan`
- Lowercase for type descriptors: `Users`, `Computers`, `Groups`
- No abbreviations for site names (Dublin, not DUB)

---

## Computer Accounts

| Pattern | Format | Example |
|---------|--------|---------|
| Workstation | `[SITE]-WS-[ASSET#]` | `SITE-WS-00142` |
| Laptop | `[SITE]-LT-[ASSET#]` | `SITE-LT-00089` |
| Server | `[SITE]-SRV-[PURPOSE]-[#]` | `SITE-SRV-DC-01` |
| Virtual | `[SITE]-VM-[PURPOSE]-[#]` | `SITE-VM-APP-01` |

Site codes: `DUB` (Dublin) | `MAD` (Madrid) | `MIL` (Milan)

---

## Service Accounts

| Type | Format | Example | Description |
|------|--------|---------|-------------|
| Application | `svc-[app]-[env]` | `svc-backup-prod` | Backup service, production |
| Monitoring | `svc-monitor-[tool]` | `svc-monitor-grafana` | Grafana monitoring |
| Automation | `svc-auto-[purpose]` | `svc-auto-adprovisioning` | AD automation scripts |

**Rules for service accounts:**
- `PasswordNeverExpires = $true` — documented and justified
- Least privilege — only permissions required for their function
- Named owner in Description field: `Owner: [name] | Ticket: [ref]`
- Annual review — confirm still in use and owner still active
- Never used for interactive logon unless absolutely required

---

## Password Policy Alignment

| Account Type | Policy | Min Length | Max Age |
|-------------|--------|-----------|---------|
| Standard users | Default Domain Policy | 12 | 90 days |
| Admin accounts (`adm-*`) | Fine-Grained PSO — Admins | 16 | 60 days |
| Service accounts (`svc-*`) | Fine-Grained PSO — Service | 24 | Never (managed) |

---

*See also: [AD Lifecycle Guide](ad-lifecycle-guide.md)*
