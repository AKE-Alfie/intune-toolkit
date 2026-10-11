#Requires -Version 7.0

<#
.SYNOPSIS
    Exports Intune device compliance to CSV and a clean HTML report using Microsoft Graph.

.DESCRIPTION
    Pulls every Intune managed device (with paging and throttling retries), applies optional
    filters (operating system, non-compliant only), flags stale devices, and writes:
      * <OutputPath>\IntuneCompliance_<timestamp>.csv
      * <OutputPath>\IntuneCompliance_<timestamp>.html
      * <OutputPath>\IntuneCompliance_<timestamp>.log

    Authentication:
      * Delegated (default)  - interactive or device-code sign-in.
      * App-only certificate - -ClientId + -CertificateThumbprint (recommended for scheduled runs).
      * App-only secret      - -ClientId + -ClientSecretCredential.

    Required Microsoft Graph permission: DeviceManagementManagedDevices.Read.All
    (delegated or application). Read-only: the script never changes a device.

.PARAMETER TenantId
    Tenant ID (GUID) or primary domain, e.g. contoso.onmicrosoft.com.
.PARAMETER ClientId
    App registration (client) ID for app-only auth.
.PARAMETER CertificateThumbprint
    Certificate thumbprint for app-only auth.
.PARAMETER ClientSecretCredential
    PSCredential (UserName = ClientId, Password = secret) for app-only auth.
.PARAMETER UseDeviceCode
    Use device-code flow for delegated sign-in.
.PARAMETER OperatingSystem
    Limit to one or more OS families: Windows, macOS, iOS, iPadOS, Android, Linux.
.PARAMETER NonCompliantOnly
    Only include devices that are not compliant.
.PARAMETER StaleDays
    Devices that have not checked in for this many days are flagged as stale. Default 30.
.PARAMETER OutputPath
    Folder for the CSV/HTML/log files. Created if missing. Default: .\reports
.PARAMETER TenantName
    Friendly customer/tenant name printed in the HTML header.
.PARAMETER SkipConnect
    Reuse an existing Connect-MgGraph session instead of connecting.

.EXAMPLE
    ./Get-IntuneComplianceReport.ps1 -TenantId contoso.onmicrosoft.com

    Delegated sign-in, all devices, reports written to .\reports.

.EXAMPLE
    ./Get-IntuneComplianceReport.ps1 -TenantId $tid -ClientId $appId -CertificateThumbprint $thumb `
        -OperatingSystem Windows -NonCompliantOnly -TenantName 'Contoso Ltd' -OutputPath D:\Reports\Contoso

    Unattended run for an MSP customer: non-compliant Windows devices only.

.OUTPUTS
    PSCustomObject with Summary, CsvPath, HtmlPath and LogPath.

.NOTES
    Author : Miguel
    License: MIT
#>
[CmdletBinding(DefaultParameterSetName = 'Delegated')]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$TenantId,

    [Parameter(Mandatory, ParameterSetName = 'AppCertificate')]
    [Parameter(Mandatory, ParameterSetName = 'AppSecret')]
    [ValidatePattern('^[0-9a-fA-F-]{36}$')][string]$ClientId,

    [Parameter(Mandatory, ParameterSetName = 'AppCertificate')]
    [ValidatePattern('^[0-9a-fA-F]{40}$')][string]$CertificateThumbprint,

    [Parameter(Mandatory, ParameterSetName = 'AppSecret')]
    [System.Management.Automation.PSCredential]$ClientSecretCredential,

    [Parameter(ParameterSetName = 'Delegated')][switch]$UseDeviceCode,

    [ValidateSet('Windows', 'macOS', 'iOS', 'iPadOS', 'Android', 'Linux')]
    [string[]]$OperatingSystem,

    [switch]$NonCompliantOnly,

    [ValidateRange(1, 3650)][int]$StaleDays = 30,

    [ValidateNotNullOrEmpty()][string]$OutputPath = (Join-Path -Path (Get-Location) -ChildPath 'reports'),

    [ValidateLength(0, 100)][string]$TenantName,

    [switch]$SkipConnect
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'src/IntuneComplianceReport.psm1') -Force

if (-not (Test-Path -LiteralPath $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$base = Join-Path $OutputPath "IntuneCompliance_$stamp"
$logPath = "$base.log"
Write-ICRLog "Run started. Filters: OS=[$($OperatingSystem -join ',')] NonCompliantOnly=$NonCompliantOnly StaleDays=$StaleDays" -Path $logPath

try {
    if (-not $SkipConnect) {
        $connect = @{ TenantId = $TenantId }
        switch ($PSCmdlet.ParameterSetName) {
            'AppCertificate' { $connect.ClientId = $ClientId; $connect.CertificateThumbprint = $CertificateThumbprint }
            'AppSecret'      { $connect.ClientId = $ClientId; $connect.ClientSecretCredential = $ClientSecretCredential }
            default          { if ($UseDeviceCode) { $connect.UseDeviceCode = $true } }
        }
        Connect-ICRGraph @connect
    }

    $getParams = @{ StaleDays = $StaleDays; NonCompliantOnly = $NonCompliantOnly }
    if ($OperatingSystem) { $getParams.OperatingSystem = $OperatingSystem }
    $devices = @(Get-ICRManagedDevice @getParams)
    Write-ICRLog "Retrieved $($devices.Count) device(s) after filtering"

    $csvPath = "$base.csv"
    $htmlPath = "$base.html"
    $devices | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding utf8
    ConvertTo-ICRHtml -Device $devices -TenantName $TenantName | Set-Content -LiteralPath $htmlPath -Encoding utf8

    $summary = Get-ICRSummary -Device $devices
    Write-ICRLog "Done. Total=$($summary.Total) Compliant=$($summary.Compliant) NonCompliant=$($summary.NonCompliant) Stale=$($summary.Stale)"

    [pscustomobject]@{
        Summary  = $summary
        CsvPath  = $csvPath
        HtmlPath = $htmlPath
        LogPath  = $logPath
    }
}
catch {
    Write-ICRLog "Run failed: $($_.Exception.Message)" -Level ERROR
    throw
}
