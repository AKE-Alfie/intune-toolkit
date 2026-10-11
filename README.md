# Intune Compliance Report

PowerShell tool that pulls every Intune-managed device and its compliance state from **Microsoft Graph** and produces a **CSV** for analysis plus a **clean, self-contained HTML report** you can email to a client or manager.

![Sample HTML report (demo data)](examples/sample-report.png)

## The problem

Getting a compliance picture out of Intune usually means exporting from the admin center, cleaning columns in Excel, and building a summary by hand, once per tenant. For an MSP with many customers, or an IT team that reports monthly, that adds up and is easy to get wrong.

## Features

- Pulls all managed devices via Graph with **automatic paging** (`@odata.nextLink`) and **retry/back-off on throttling** (HTTP 429/503/504)
- Filters: **operating system** (`Windows`, `macOS`, `iOS`, `iPadOS`, `Android`, `Linux`) and **non-compliant only**
- Flags **stale devices** that haven't checked in for N days (default 30)
- Exports **CSV** (one row per device) and a **branded HTML report** with summary cards, per-OS breakdown and a device table, non-compliant devices listed first
- **Three auth modes**: delegated (interactive / device code), app-only **certificate**, app-only **client secret**
- **Read-only**: it never changes a device
- Timestamped **log file** for every run; HTML output is encoded to prevent injection from device names
- Pester tests with Graph fully mocked, PSScriptAnalyzer-clean, GitHub Actions CI

## Time saved

Estimate: a manual export, cleanup and summary takes roughly **30-60 minutes per tenant**. This script does it in **under a minute** and can run on a schedule for every customer.

## Requirements

- PowerShell **7.0+** (Windows, macOS or Linux)
- `Microsoft.Graph.Authentication` module:
  ```powershell
  Install-Module Microsoft.Graph.Authentication -Scope CurrentUser
  ```
- An Intune licence in the tenant

## Permissions needed

| Auth mode | Permission | Type |
|---|---|---|
| Delegated | `DeviceManagementManagedDevices.Read.All` | Delegated (signed-in user needs an Intune role such as *Intune Read Only Operator* or *Global Reader*) |
| App-only | `DeviceManagementManagedDevices.Read.All` | Application (admin consent required) |

For unattended runs, create an app registration, grant the application permission above, give admin consent, and upload a certificate. Certificate auth is preferred over client secrets.

## Usage

```powershell
# Interactive sign-in, all devices
./Get-IntuneComplianceReport.ps1 -TenantId contoso.onmicrosoft.com

# Device-code sign-in (servers / SSH)
./Get-IntuneComplianceReport.ps1 -TenantId contoso.onmicrosoft.com -UseDeviceCode

# Non-compliant Windows devices only, flag anything not seen in 14 days
./Get-IntuneComplianceReport.ps1 -TenantId contoso.onmicrosoft.com -OperatingSystem Windows -NonCompliantOnly -StaleDays 14

# Unattended (scheduled task / RMM / Azure Automation), certificate auth
./Get-IntuneComplianceReport.ps1 -TenantId $TenantId -ClientId $AppId -CertificateThumbprint $Thumbprint `
    -TenantName 'Contoso Ltd' -OutputPath 'D:\Reports\Contoso'

# Client secret auth (UserName = ClientId, Password = secret)
$cred = Get-Credential -UserName $AppId -Message 'Client secret'
./Get-IntuneComplianceReport.ps1 -TenantId $TenantId -ClientSecretCredential $cred -ClientId $AppId

# Reuse an existing Connect-MgGraph session
./Get-IntuneComplianceReport.ps1 -TenantId $TenantId -SkipConnect -Verbose
```

Full help: `Get-Help ./Get-IntuneComplianceReport.ps1 -Full`

### Preview without a tenant

```powershell
./examples/New-SampleReport.ps1   # writes sample-report.csv/.html from fake data
```

## Sample output

The script returns an object and writes three files to `-OutputPath`:

```text
Summary  : @{Total=12; Compliant=6; NonCompliant=6; CompliancePct=50; Stale=2; ...}
CsvPath  : ./reports/IntuneCompliance_20261011_134100.csv
HtmlPath : ./reports/IntuneCompliance_20261011_134100.html
LogPath  : ./reports/IntuneCompliance_20261011_134100.log
```

CSV columns: `DeviceName, User, UserDisplayName, OperatingSystem, OSVersion, ComplianceState, LastSyncUtc, DaysSinceSync, IsStale, Ownership, Manufacturer, Model, SerialNumber, Encrypted, JailBroken, DeviceId`

See [`examples/sample-report.csv`](examples/sample-report.csv) and [`examples/sample-report.html`](examples/sample-report.html). All sample data is fictitious.

## Project layout

```text
Get-IntuneComplianceReport.ps1   entry script (parameters, auth, export)
src/IntuneComplianceReport.psm1  Graph paging, filtering, summary, HTML rendering
tests/                           Pester tests (Graph mocked, no tenant needed)
examples/                        demo generator + sample CSV/HTML/PNG
```

## Running the tests

```powershell
Install-Module Pester -MinimumVersion 5.5 -Scope CurrentUser
Install-Module PSScriptAnalyzer -Scope CurrentUser
Invoke-Pester ./tests -Output Detailed
Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1
```

## Roadmap ideas

- Include per-policy failure reasons (`deviceCompliancePolicyStates`)
- Email the HTML report via Graph `sendMail`
- Multi-tenant loop for MSPs (GDAP)

## License

MIT, see [LICENSE](LICENSE).
