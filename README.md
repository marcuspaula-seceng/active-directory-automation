# Active Directory Automation

PowerShell lab for identity lifecycle, access review, privileged-account auditing and operational reporting.

This repository is designed as **security-focused engineering evidence**. It demonstrates safe automation patterns rather than claiming production deployment in any specific employer environment.

## Provenance

This automation suite was developed in 2026 from professional Windows administration
practice, and is published as portfolio work.

The identity data, domain names and site codes are synthetic, and the scripts are not
presented as having been executed against any production directory. Domains use the
reserved `example.com` space (RFC 2606); no organisation, host, site code or account
from any real environment appears in this repository.

## Runtime

The Active Directory scripts target **Windows PowerShell 5.1 on Windows**, with the
`ActiveDirectory` module available through the appropriate Windows Server role or RSAT
tooling. That is the environment these scripts are written for. In this repository,
Windows PowerShell 5.1 compatibility has been validated for parsing and character
handling; the Active Directory operations themselves have not been executed against
a live directory.

PowerShell 7 (`pwsh`) is used by CI to run the automated helper tests. The Active Directory
operations themselves have **not** been validated under PowerShell 7, and this repository
makes no claim that they are.

Script files that contain non-ASCII characters are stored as **UTF-8 with BOM**. Windows
PowerShell 5.1 reads a BOM-less UTF-8 file using the system ANSI code page, which corrupts
those characters and can break parsing; the BOM makes the encoding explicit. Do not strip
it.

## Security principles

- `Set-StrictMode -Version Latest` and terminating errors
- `SupportsShouldProcess` for privileged or destructive actions
- no reusable passwords or secrets committed to source
- temporary onboarding credentials supplied at runtime as `SecureString`
- pre-approved OUs only; onboarding does not create directory structure
- delegated OU/group permissions preferred over Domain Admin
- validation before privileged changes
- structured logging without secret material
- Pester coverage for testable helper logic

## Repository structure

```text
.
├── lifecycle/
│   ├── onboard-user.ps1
│   ├── offboard-user.ps1
│   └── transfer-user.ps1
├── access-management/
│   ├── access-review.ps1
│   ├── privileged-accounts-audit.ps1
│   └── stale-accounts-report.ps1
├── reporting/
│   ├── ad-health-report.ps1
│   ├── group-membership-report.ps1
│   └── password-policy-audit.ps1
├── lib/
│   └── IdentityHelpers.psm1
├── tests/
│   └── IdentityHelpers.Tests.ps1
└── docs/
```

## Secure onboarding example

```powershell
$tempPassword = Read-Host 'Temporary password' -AsSecureString

.\lifecycle\onboard-user.ps1 `
    -FirstName 'Jane' `
    -LastName 'Smith' `
    -Department 'Engineering' `
    -Site 'Dublin' `
    -Manager 'jdoe' `
    -Title 'IT Engineer' `
    -TemporaryPassword $tempPassword `
    -TicketReference 'REQ-2026-0042' `
    -WhatIf
```

Run with `-WhatIf` first. Remove it only after validating the target OU, groups, manager, ticket and delegated execution identity.

## Privilege model

Routine provisioning should use a **dedicated delegated identity** with only the permissions needed for the approved OUs and groups.

Recommended capabilities:

- create/update user objects only in approved user OUs;
- reset/set initial user password in those OUs;
- update the required user attributes;
- add/remove users only from approved operational groups;
- read manager, OU and group metadata required for validation.

Routine onboarding should **not** require Domain Admin, Enterprise Admin or broad directory-control permissions.

## Credential handling

The repository does not store a reusable onboarding password. The caller supplies a `SecureString` at runtime. In a production design, the runtime value should come from an approved privileged workflow or secret-management system and should never be logged or committed.

## Testing

The helper module is intentionally isolated from the Active Directory dependency so deterministic logic can be tested without a domain controller.

```powershell
Install-Module Pester -MinimumVersion 5.5.0 -Scope CurrentUser
Invoke-Pester ./tests
pwsh -NoProfile -File ./tests/Lifecycle.Regression.ps1
```

The suite uses Pester 5 syntax and requires **Pester 5.5.0 or later**. The Pester version
shipped with Windows (3.4.0) cannot run it. CI enforces the same minimum.

Current tests cover:

- SAMAccountName generation;
- punctuation/diacritic normalization;
- length enforcement;
- invalid input handling;
- log-safe identifier redaction.

The separate offline lifecycle checks use in-memory AD, file and mail test doubles.
They cover partial-failure reporting, manual retention, future-date rejection, target-OU
validation and `-WhatIf` refusal. They do not validate a live directory, SMTP delivery
or password generation.

## Operational workflows

### Lifecycle

- onboarding into approved OUs and groups;
- transfer between approved department/site structures;
- offboarding with account disablement, per-group removal results and a manual retention
  review date; no account deletion is scheduled. Future termination dates are rejected
  before directory changes.

### Access management

- access review reporting;
- privileged group/account audit;
- stale-account identification.

### Reporting

- AD health reporting;
- group-membership snapshots and delta comparison;
- password-policy audit.

## Failure model

Automation is considered unsafe if it silently continues after an identity-control failure. Scripts should stop or clearly surface failures when critical validation fails.

Examples:

- manager cannot be resolved;
- target OU is missing;
- required security group is missing;
- directory operation fails;
- delegated permissions are insufficient.

## Learning objectives

This lab is used to develop and demonstrate:

`PowerShell` · `Active Directory` · `IAM` · `Least Privilege` · `Identity Lifecycle` · `Access Review` · `Auditability` · `Pester`

## Next engineering steps

- expand Pester coverage to access-review and reporting helper functions;
- add Entra ID / Microsoft Graph equivalents as a separate, clearly scoped lab;
- model an approval boundary between HR/request intake and privileged execution;
- add structured JSON audit events for SIEM ingestion.


## Architecture

```mermaid
flowchart LR
    A[Operator input] --> B{Parameter validation}
    B -->|invalid| X[Fail fast, nothing changes]
    B -->|valid| C[IdentityHelpers module]
    C --> D{ShouldProcess}
    D -->|WhatIf| E[Planned actions only]
    D -->|confirmed| F[Directory operation]
    C --> G[Reporting]
    G --> H[CSV and HTML for managers]
    F --> I[Levelled log, no secret material]
```

Name normalisation and identifier redaction are isolated in the helper module and tested
without a directory. Active Directory calls remain in the lifecycle and reporting scripts.

## Validation

| Layer | What it checks |
|---|---|
| Pester 5 unit tests | Module logic against controlled inputs |
| GitHub Actions CI | Pester and offline lifecycle checks run for changes to `lib/`, `lifecycle/`, `tests/` or their workflow, on `windows-latest` with `permissions: contents: read`; the separate validation workflow checks parsing, Markdown fences and relative links |
| Strict mode | Undeclared variables fail rather than evaluating to empty |
| `ShouldProcess` | Every destructive path supports `-WhatIf` before it acts |
| Pre-approved scope | Operations are constrained to explicitly listed organisational units |

## Limitations

**These operations have not been executed against a live production directory.** The
repository is a laboratory build. Anyone adopting it should expect to validate behaviour in a
test forest first.

- Reporting is designed for review by a human, not for automated enforcement.
- Rollback for directory changes is not automated. `-WhatIf` previews intent; it does not
  prove that subsequent directory operations will succeed. Offboarding and transfer
  report partial group/GAL failures for manual follow-up.
- Tests cover the helper module and selected lifecycle paths with test doubles, not
  end-to-end directory interaction.

## Lessons learned

A publication readiness gate on this repository failed on its first run and surfaced that
nine of eleven scripts did not parse, after they had been read and judged fine. The defect
was reduced to a four-case minimal reproduction and confirmed as pre-existing. The lesson
kept: code that looks right is not evidence, and a gate that never fails is not a gate.

## Future improvements

- Integration tests against a disposable test forest.
- Structured output for ingestion by a reporting pipeline.
- Signed releases once the repository is published.


## Engineering timeline

**Phase 1 — Security baseline.** The recurring work was identity lifecycle: accounts created,
moved and disabled by hand, access reviewed irregularly, privileged membership known only by
asking. The baseline question was which of those steps could be made repeatable without
increasing risk.

**Phase 2 — Development.** Each flow was written so that the dangerous part is explicit:
strict mode on, `ShouldProcess` on every destructive path, operations constrained to
pre-approved organisational units, and logging that records what happened without recording
secret material.

**Phase 3 — Automation and validation.** Name normalisation and identifier redaction were
isolated in a helper module. Pester 5 covers those helpers without a live directory; its CI
workflow runs on relevant path changes under `permissions: contents: read`. These checks
do not demonstrate end-to-end directory operation.

**Phase 4 — Outcome and lessons learned.** A four-stage publication gate failed on first use
and surfaced that nine of eleven scripts did not parse — after I had read them and judged them
fine. It was reduced to a four-case minimal reproduction and confirmed as pre-existing. The
rule kept: code that reads correctly is not evidence, and a gate that never fails is not a gate.

## Problem

Identity lifecycle work is repetitive, high-consequence and easy to get quietly wrong. Accounts
are created, moved and disabled by hand; access is reviewed irregularly; privileged group
membership is known only by asking. Each of those is a place where an account outlives the
person's role, and nobody notices until an audit or an incident.

This repository rebuilds those steps as automation that can be reviewed, tested and refused
safely, rather than as scripts that are trusted because they usually work.

## Technologies

PowerShell 5.1 and 7 · Active Directory module · Pester 5 · GitHub Actions ·
CSV and HTML reporting · `SecureString` for runtime credentials
