#Requires -Version 7.0
<#
    IntuneComplianceReport module
    Pulls Intune managed devices and their compliance state from Microsoft Graph
    and turns them into CSV and HTML reports.
#>

Set-StrictMode -Version Latest

$script:LogPath = $null

function Write-ICRLog {
    <#
    .SYNOPSIS
        Writes a timestamped log line to the verbose stream and (optionally) a log file.
    .PARAMETER Message
        The message to log.
    .PARAMETER Level
        INFO, WARN or ERROR.
    .PARAMETER Path
        Optional log file path. Once set, it is remembered for the rest of the session.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO',
        [string]$Path
    )
    if ($Path) { $script:LogPath = $Path }
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    if ($Level -eq 'WARN') { Write-Warning $Message } else { Write-Verbose $line }
    if ($script:LogPath) {
        Add-Content -LiteralPath $script:LogPath -Value $line -Encoding utf8
    }
}

function Connect-ICRGraph {
    <#
    .SYNOPSIS
        Connects to Microsoft Graph using delegated or app-only authentication.
    .DESCRIPTION
        Delegated (interactive) is the default. For unattended/scheduled runs use an
        app registration with either a certificate (recommended) or a client secret.
        Required Graph permission: DeviceManagementManagedDevices.Read.All
    .PARAMETER TenantId
        Entra ID tenant ID (GUID) or primary domain.
    .PARAMETER ClientId
        Application (client) ID of the app registration. Required for app-only auth.
    .PARAMETER CertificateThumbprint
        Thumbprint of a certificate in the current user's or local machine's store (app-only).
    .PARAMETER ClientSecretCredential
        PSCredential where the user name is the ClientId and the password is the client secret (app-only).
    .PARAMETER UseDeviceCode
        Use device-code flow for delegated sign-in (useful on servers / SSH sessions).
    .EXAMPLE
        Connect-ICRGraph -TenantId contoso.onmicrosoft.com
    .EXAMPLE
        Connect-ICRGraph -TenantId $tid -ClientId $appId -CertificateThumbprint 'A1B2...'
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

        [Parameter(ParameterSetName = 'Delegated')][switch]$UseDeviceCode
    )

    if (-not (Get-Command -Name Connect-MgGraph -ErrorAction SilentlyContinue)) {
        throw 'Microsoft.Graph.Authentication module not found. Run: Install-Module Microsoft.Graph.Authentication -Scope CurrentUser'
    }

    $connectParams = @{ TenantId = $TenantId; NoWelcome = $true; ErrorAction = 'Stop' }
    switch ($PSCmdlet.ParameterSetName) {
        'AppCertificate' {
            $connectParams.ClientId = $ClientId
            $connectParams.CertificateThumbprint = $CertificateThumbprint
        }
        'AppSecret' {
            $connectParams.ClientSecretCredential = $ClientSecretCredential
        }
        default {
            $connectParams.Scopes = @('DeviceManagementManagedDevices.Read.All')
            if ($UseDeviceCode) { $connectParams.UseDeviceCode = $true }
        }
    }

    Write-ICRLog "Connecting to Microsoft Graph ($($PSCmdlet.ParameterSetName)) for tenant $TenantId"
    try {
        Connect-MgGraph @connectParams | Out-Null
    }
    catch {
        Write-ICRLog "Graph connection failed: $($_.Exception.Message)" -Level ERROR
        throw
    }
}

function Invoke-ICRGraphPagedRequest {
    <#
    .SYNOPSIS
        GETs a Graph collection and follows @odata.nextLink until all pages are returned.
        Retries on HTTP 429 / 503 with exponential back-off.
    .PARAMETER Uri
        Relative or absolute Graph URI.
    .PARAMETER MaxRetries
        Retries per page for throttling / transient errors.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Uri,
        [ValidateRange(0, 10)][int]$MaxRetries = 4
    )

    $results = [System.Collections.Generic.List[object]]::new()
    $next = $Uri
    $page = 0
    while ($next) {
        $page++
        $attempt = 0
        while ($true) {
            try {
                $response = Invoke-MgGraphRequest -Method GET -Uri $next -OutputType PSObject -ErrorAction Stop
                break
            }
            catch {
                $status = $null
                if ($_.Exception.PSObject.Properties['Response'] -and $_.Exception.Response) {
                    $status = [int]$_.Exception.Response.StatusCode
                }
                if ($attempt -lt $MaxRetries -and $status -in 429, 503, 504) {
                    $attempt++
                    $delay = [math]::Pow(2, $attempt)
                    Write-ICRLog "Graph returned $status on page $page. Retry $attempt/$MaxRetries in ${delay}s" -Level WARN
                    Start-Sleep -Seconds $delay
                    continue
                }
                Write-ICRLog "Graph request failed: $($_.Exception.Message)" -Level ERROR
                throw
            }
        }
        if ($response.PSObject.Properties['value']) {
            foreach ($item in @($response.value)) { $results.Add($item) }
        }
        $next = if ($response.PSObject.Properties['@odata.nextLink']) { $response.'@odata.nextLink' } else { $null }
        Write-ICRLog "Fetched page $page ($($results.Count) items so far)"
    }
    return , $results.ToArray()
}

function Get-ICRManagedDevice {
    <#
    .SYNOPSIS
        Returns Intune managed devices, optionally filtered by OS and compliance state.
    .PARAMETER OperatingSystem
        One or more of Windows, macOS, iOS, Android, Linux. Matching is prefix-based
        (e.g. "iOS" also matches "iPadOS" is NOT implied - list both if needed).
    .PARAMETER NonCompliantOnly
        Return only devices whose complianceState is not 'compliant'
        (noncompliant, inGracePeriod, conflict, error, unknown, configManager).
    .PARAMETER StaleDays
        Flag devices that have not synced within this many days (adds IsStale = $true).
    .EXAMPLE
        Get-ICRManagedDevice -OperatingSystem Windows -NonCompliantOnly
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('Windows', 'macOS', 'iOS', 'iPadOS', 'Android', 'Linux')]
        [string[]]$OperatingSystem,
        [switch]$NonCompliantOnly,
        [ValidateRange(1, 3650)][int]$StaleDays = 30
    )

    $select = 'id,deviceName,userPrincipalName,userDisplayName,operatingSystem,osVersion,complianceState,' +
              'lastSyncDateTime,enrolledDateTime,managedDeviceOwnerType,model,manufacturer,serialNumber,isEncrypted,jailBroken'
    $uri = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?`$select=$select&`$top=999"

    if ($NonCompliantOnly) {
        # Server-side filter reduces payload on large tenants.
        $uri += "&`$filter=complianceState ne 'compliant'"
    }

    Write-ICRLog 'Retrieving Intune managed devices'
    $devices = Invoke-ICRGraphPagedRequest -Uri $uri

    if ($OperatingSystem) {
        $devices = @($devices | Where-Object {
                $os = $_.operatingSystem
                $OperatingSystem | Where-Object { $os -like "$_*" }
            })
    }
    if ($NonCompliantOnly) {
        # Defensive client-side filter as well (some tenants ignore 'ne' on this property).
        $devices = @($devices | Where-Object { $_.complianceState -ne 'compliant' })
    }

    $cutoff = (Get-Date).ToUniversalTime().AddDays(-$StaleDays)
    foreach ($d in $devices) {
        $lastSync = $null
        if ($d.lastSyncDateTime) { $lastSync = ([datetime]$d.lastSyncDateTime).ToUniversalTime() }
        [pscustomobject]@{
            DeviceName        = $d.deviceName
            User              = $d.userPrincipalName
            UserDisplayName   = $d.userDisplayName
            OperatingSystem   = $d.operatingSystem
            OSVersion         = $d.osVersion
            ComplianceState   = $d.complianceState
            LastSyncUtc       = if ($lastSync) { $lastSync.ToString('yyyy-MM-dd HH:mm:ss') } else { $null }
            DaysSinceSync     = if ($lastSync) { [int][math]::Floor(((Get-Date).ToUniversalTime() - $lastSync).TotalDays) } else { $null }
            IsStale           = if ($lastSync) { $lastSync -lt $cutoff } else { $true }
            Ownership         = $d.managedDeviceOwnerType
            Manufacturer      = $d.manufacturer
            Model             = $d.model
            SerialNumber      = $d.serialNumber
            Encrypted         = $d.isEncrypted
            JailBroken        = $d.jailBroken
            DeviceId          = $d.id
        }
    }
}

function Get-ICRSummary {
    <#
    .SYNOPSIS
        Builds summary counts (by compliance state and by OS) from report rows.
    .PARAMETER Device
        Rows produced by Get-ICRManagedDevice.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Device)

    $total = $Device.Count
    $compliant = @($Device | Where-Object ComplianceState -eq 'compliant').Count
    [pscustomobject]@{
        Total          = $total
        Compliant      = $compliant
        NonCompliant   = $total - $compliant
        CompliancePct  = if ($total) { [math]::Round(($compliant / $total) * 100, 1) } else { 0 }
        Stale          = @($Device | Where-Object IsStale).Count
        ByState        = @($Device | Group-Object ComplianceState | Sort-Object Count -Descending |
                            ForEach-Object { [pscustomobject]@{ Name = $_.Name; Count = $_.Count } })
        ByOS           = @($Device | Group-Object OperatingSystem | Sort-Object Count -Descending |
                            ForEach-Object {
                                $c = @($_.Group | Where-Object ComplianceState -eq 'compliant').Count
                                [pscustomobject]@{ Name = $_.Name; Count = $_.Count; Compliant = $c; NonCompliant = $_.Count - $c }
                            })
    }
}

function ConvertTo-ICRHtml {
    <#
    .SYNOPSIS
        Renders report rows into a self-contained HTML report (no external CSS/JS).
    .PARAMETER Device
        Rows produced by Get-ICRManagedDevice.
    .PARAMETER Title
        Report title.
    .PARAMETER TenantName
        Optional tenant / customer name shown in the header.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Device,
        [string]$Title = 'Intune Device Compliance Report',
        [string]$TenantName
    )

    $enc = { param($v) [System.Net.WebUtility]::HtmlEncode([string]$v) }
    $s = Get-ICRSummary -Device $Device
    $generated = Get-Date -Format 'yyyy-MM-dd HH:mm'

    $osRows = ($s.ByOS | ForEach-Object {
            "<tr><td>$(& $enc $_.Name)</td><td>$($_.Count)</td><td>$($_.Compliant)</td><td>$($_.NonCompliant)</td></tr>"
        }) -join "`n"

    $deviceRows = ($Device | Sort-Object @{ e = { $_.ComplianceState -eq 'compliant' } }, DeviceName | ForEach-Object {
            $cls = switch ($_.ComplianceState) { 'compliant' { 'ok' } 'inGracePeriod' { 'warn' } default { 'bad' } }
            $sync = if ($_.LastSyncUtc) { ([datetime]$_.LastSyncUtc).ToString('yyyy-MM-dd HH:mm') } else { 'never' }
            $staleTag = if ($_.IsStale) { ' <span class="tag">stale</span>' } else { '' }
            "<tr><td>$(& $enc $_.DeviceName)</td><td>$(& $enc $_.User)</td><td>$(& $enc $_.OperatingSystem) $(& $enc $_.OSVersion)</td>" +
            "<td><span class=`"pill $cls`">$(& $enc $_.ComplianceState)</span></td><td>$sync$staleTag</td><td>$(& $enc $_.Ownership)</td><td>$(& $enc $_.Model)</td></tr>"
        }) -join "`n"

    $tenantLine = if ($TenantName) { " &middot; $(& $enc $TenantName)" } else { '' }

    @"
<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>$(& $enc $Title)</title>
<style>
 body{font-family:Segoe UI,Roboto,Helvetica,Arial,sans-serif;margin:0;background:#f4f6f9;color:#1f2933}
 header{background:#0b3d91;color:#fff;padding:24px 32px}header h1{margin:0;font-size:22px}header p{margin:6px 0 0;opacity:.85;font-size:13px}
 main{padding:24px 32px}.cards{display:flex;gap:16px;flex-wrap:wrap;margin-bottom:24px}
 .card{background:#fff;border-radius:8px;padding:16px 20px;min-width:150px;box-shadow:0 1px 3px rgba(0,0,0,.08)}
 .card .v{font-size:28px;font-weight:600}.card .l{font-size:12px;color:#616e7c;text-transform:uppercase;letter-spacing:.04em}
 .card.ok .v{color:#1b7f3b}.card.bad .v{color:#c62828}.card.warn .v{color:#b26a00}
 table{width:100%;border-collapse:collapse;background:#fff;border-radius:8px;overflow:hidden;box-shadow:0 1px 3px rgba(0,0,0,.08);margin-bottom:24px;font-size:13px}
 th{background:#e9eef5;text-align:left;padding:8px 10px;font-weight:600}td{padding:7px 10px;border-top:1px solid #edf0f3}
 .pill{padding:2px 8px;border-radius:10px;font-size:12px;font-weight:600}.pill.ok{background:#e3f4e8;color:#1b7f3b}
 .pill.bad{background:#fde8e8;color:#c62828}.pill.warn{background:#fff4e0;color:#b26a00}
 .tag{background:#eceff1;color:#455a64;border-radius:4px;padding:1px 5px;font-size:11px}
 h2{font-size:16px;margin:8px 0 10px}footer{font-size:12px;color:#7b8794;padding:0 32px 24px}
</style></head><body>
<header><h1>$(& $enc $Title)</h1><p>Generated $generated$tenantLine</p></header>
<main>
<div class="cards">
 <div class="card"><div class="v">$($s.Total)</div><div class="l">Devices</div></div>
 <div class="card ok"><div class="v">$($s.Compliant)</div><div class="l">Compliant</div></div>
 <div class="card bad"><div class="v">$($s.NonCompliant)</div><div class="l">Not compliant</div></div>
 <div class="card"><div class="v">$($s.CompliancePct)%</div><div class="l">Compliance rate</div></div>
 <div class="card warn"><div class="v">$($s.Stale)</div><div class="l">Stale (no recent sync)</div></div>
</div>
<h2>By operating system</h2>
<table><thead><tr><th>OS</th><th>Devices</th><th>Compliant</th><th>Not compliant</th></tr></thead><tbody>
$osRows
</tbody></table>
<h2>Devices</h2>
<table><thead><tr><th>Device</th><th>User</th><th>OS</th><th>Compliance</th><th>Last sync (UTC)</th><th>Ownership</th><th>Model</th></tr></thead><tbody>
$deviceRows
</tbody></table>
</main>
<footer>Source: Microsoft Graph /deviceManagement/managedDevices &middot; intune-compliance-report</footer>
</body></html>
"@
}

Export-ModuleMember -Function Write-ICRLog, Connect-ICRGraph, Invoke-ICRGraphPagedRequest, Get-ICRManagedDevice, Get-ICRSummary, ConvertTo-ICRHtml
