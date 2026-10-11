<#
.SYNOPSIS
    Generates sample CSV/HTML output from FAKE device data (no tenant or Graph module needed).
.DESCRIPTION
    Useful for previewing the report layout. All names, users and serial numbers are fictitious.
.PARAMETER OutputPath
    Folder to write sample-report.csv and sample-report.html. Defaults to this folder.
.EXAMPLE
    ./examples/New-SampleReport.ps1
#>
[CmdletBinding()]
param([string]$OutputPath = $PSScriptRoot)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../src/IntuneComplianceReport.psm1') -Force

$now = (Get-Date).ToUniversalTime()
$seed = @(
    ,@('FAB-LT-0142', 'j.rivera@fabrikam.example', 'Windows', '10.0.22631.4317', 'compliant', 0.2, 'Dell', 'Latitude 7440', $true)
    ,@('FAB-LT-0157', 'm.chen@fabrikam.example', 'Windows', '10.0.22631.4317', 'compliant', 0.5, 'Lenovo', 'ThinkPad T14 Gen 4', $true)
    ,@('FAB-LT-0163', 's.patel@fabrikam.example', 'Windows', '10.0.19045.4894', 'noncompliant', 2.1, 'HP', 'EliteBook 840 G9', $false)
    ,@('FAB-DT-0021', 'reception@fabrikam.example', 'Windows', '10.0.19045.3803', 'noncompliant', 47.0, 'Dell', 'OptiPlex 7010', $false)
    ,@('FAB-LT-0171', 'a.okafor@fabrikam.example', 'Windows', '10.0.22631.4317', 'inGracePeriod', 1.3, 'Microsoft', 'Surface Laptop 5', $true)
    ,@('FAB-LT-0174', 'l.garcia@fabrikam.example', 'Windows', '10.0.26100.2033', 'compliant', 0.1, 'Lenovo', 'ThinkPad X1 Carbon', $true)
    ,@('FAB-MAC-009', 'd.kim@fabrikam.example', 'macOS', '14.6.1', 'compliant', 0.8, 'Apple', 'MacBook Pro 14', $true)
    ,@('FAB-MAC-012', 'r.silva@fabrikam.example', 'macOS', '13.6.9', 'noncompliant', 5.4, 'Apple', 'MacBook Air M2', $true)
    ,@('iPhone-JRivera', 'j.rivera@fabrikam.example', 'iOS', '17.6.1', 'compliant', 0.3, 'Apple', 'iPhone 15', $true)
    ,@('iPhone-SPatel', 's.patel@fabrikam.example', 'iOS', '16.7.8', 'noncompliant', 12.6, 'Apple', 'iPhone 12', $true)
    ,@('Galaxy-MChen', 'm.chen@fabrikam.example', 'Android', '14', 'compliant', 0.9, 'Samsung', 'Galaxy S23', $true)
    ,@('Pixel-AOkafor', 'a.okafor@fabrikam.example', 'Android', '13', 'error', 33.0, 'Google', 'Pixel 7', $true)
)
$i = 0
$raw = foreach ($s in $seed) {
    $i++
    [pscustomobject]@{
        id = [guid]::new("00000000-0000-0000-0000-{0:d12}" -f $i).Guid; deviceName = $s[0]; userPrincipalName = $s[1]
        userDisplayName = ($s[1] -split '@')[0]; operatingSystem = $s[2]; osVersion = $s[3]; complianceState = $s[4]
        lastSyncDateTime = $now.AddDays(-$s[5]).ToString('o'); managedDeviceOwnerType = 'company'
        manufacturer = $s[6]; model = $s[7]; serialNumber = 'DEMO{0:d6}' -f $i; isEncrypted = $s[8]; jailBroken = 'False'
    }
}

# Feed the fake data through the real pipeline by mocking Graph in-module.
& (Get-Module IntuneComplianceReport) {
    param($data)
    $script:DemoData = $data
    function script:Invoke-ICRGraphPagedRequest { param($Uri) Write-Verbose "Demo data instead of $Uri"; , @($script:DemoData) }
} $raw

$rows = @(Get-ICRManagedDevice)
$rows | Export-Csv (Join-Path $OutputPath 'sample-report.csv') -NoTypeInformation -Encoding utf8
ConvertTo-ICRHtml -Device $rows -TenantName 'Fabrikam (demo data)' | Set-Content (Join-Path $OutputPath 'sample-report.html') -Encoding utf8
Get-ICRSummary -Device $rows | Select-Object Total, Compliant, NonCompliant, CompliancePct, Stale
