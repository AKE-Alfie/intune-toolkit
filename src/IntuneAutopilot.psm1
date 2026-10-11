#Requires -Version 7.0
<#
    IntuneAutopilot module
    Collects Windows Autopilot hardware hashes and imports them into Intune via Microsoft Graph.
#>

Set-StrictMode -Version Latest
$script:Graph = 'https://graph.microsoft.com/v1.0'
$script:CsvHeader = 'Device Serial Number', 'Windows Product ID', 'Hardware Hash', 'Group Tag'

function Get-AutopilotDeviceDetail {
    <#
    .SYNOPSIS
        Internal wrapper around the local CIM queries (kept separate so it can be mocked in tests).
    #>
    [CmdletBinding()]
    param()
    $devDetail = Get-CimInstance -Namespace 'root/cimv2/mdm/dmmap' -ClassName 'MDM_DevDetail_Ext01' -Filter "InstanceID='Ext' AND ParentID='./DevDetail'" -ErrorAction Stop
    $bios = Get-CimInstance -ClassName Win32_BIOS -ErrorAction Stop
    [pscustomobject]@{ SerialNumber = $bios.SerialNumber; HardwareHash = $devDetail.DeviceHardwareData; ComputerName = $env:COMPUTERNAME }
}

function Get-AutopilotHardwareHash {
    <#
    .SYNOPSIS
        Reads this PC's Autopilot hardware hash and serial number and optionally appends it to a CSV.
    .DESCRIPTION
        Must run elevated on Windows 10/11. The CSV uses the exact header Intune expects for manual
        import ("Device Serial Number,Windows Product ID,Hardware Hash,Group Tag"), so the same file
        works in the Intune portal or with Import-AutopilotDevice. Safe to run from an RMM against
        many PCs that append to one network share CSV.
    .PARAMETER OutputCsv
        Append the device to this CSV (created with header if missing).
    .PARAMETER GroupTag
        Optional Autopilot group tag (used for dynamic group / profile assignment).
    .EXAMPLE
        Get-AutopilotHardwareHash -OutputCsv \\fs01\it$\autopilot\contoso.csv -GroupTag 'Contoso-Standard'
    #>
    [CmdletBinding()]
    param([string]$OutputCsv, [ValidatePattern('^[\w\-. ]{0,200}$')][string]$GroupTag = '')

    if ($IsLinux -or $IsMacOS) { throw 'Get-AutopilotHardwareHash only runs on Windows.' }
    $d = Get-AutopilotDeviceDetail
    if (-not $d.HardwareHash) { throw 'Hardware hash is empty. Run elevated (as Administrator) on a physical or supported virtual machine.' }
    $row = [pscustomobject][ordered]@{
        'Device Serial Number' = $d.SerialNumber
        'Windows Product ID'   = ''
        'Hardware Hash'        = $d.HardwareHash
        'Group Tag'            = $GroupTag
    }
    if ($OutputCsv) {
        if (Test-Path -LiteralPath $OutputCsv) {
            $existing = @(Import-Csv -LiteralPath $OutputCsv)
            if ($existing | Where-Object { $_.'Device Serial Number' -eq $d.SerialNumber }) {
                Write-Warning "Serial $($d.SerialNumber) already in $OutputCsv; not added again"
                return $row
            }
        }
        $row | Export-Csv -LiteralPath $OutputCsv -Append -NoTypeInformation -Encoding utf8
    }
    $row
}

function Import-AutopilotDevice {
    <#
    .SYNOPSIS
        Imports devices from an Autopilot CSV into Intune and waits for each import to finish.
    .DESCRIPTION
        Posts each row to /deviceManagement/importedWindowsAutopilotDeviceIdentities, polls until the
        status is complete or error, and returns one result per device. Requires
        DeviceManagementServiceConfig.ReadWrite.All.
    .PARAMETER CsvPath
        CSV with "Device Serial Number" and "Hardware Hash" columns (Group Tag optional).
    .PARAMETER GroupTag
        Override the group tag for every device.
    .PARAMETER AssignedUser
        Optional UPN to pre-assign (user-driven mode).
    .PARAMETER TimeoutSeconds
        How long to wait for all imports to finish.
    .PARAMETER PollSeconds
        Seconds between status checks.
    .PARAMETER Sync
        Trigger an Autopilot sync after import.
    .EXAMPLE
        Import-AutopilotDevice -CsvPath .\contoso.csv -GroupTag 'Contoso-Kiosk' -Sync -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory)][ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })][string]$CsvPath,
        [ValidatePattern('^[\w\-. ]{0,200}$')][string]$GroupTag,
        [ValidatePattern('^$|^[^@\s]+@[^@\s]+\.[^@\s]+$')][string]$AssignedUser = '',
        [ValidateRange(10, 7200)][int]$TimeoutSeconds = 900,
        [ValidateRange(0, 300)][int]$PollSeconds = 15,
        [switch]$Sync
    )
    $rows = @(Import-Csv -LiteralPath $CsvPath)
    foreach ($col in 'Device Serial Number', 'Hardware Hash') {
        if ($rows.Count -and -not $rows[0].PSObject.Properties[$col]) { throw "CSV is missing the '$col' column" }
    }
    $pending = [System.Collections.Generic.List[object]]::new()
    $results = [System.Collections.Generic.List[object]]::new()
    $line = 1
    foreach ($r in $rows) {
        $line++
        $serial = "$($r.'Device Serial Number')".Trim()
        $hash = "$($r.'Hardware Hash')".Trim()
        if (-not $serial -or -not $hash) {
            $results.Add([pscustomobject]@{ SerialNumber = $serial; Status = 'invalid'; ErrorName = "Line ${line}: serial or hash missing"; ImportId = $null }); continue
        }
        try { [void][Convert]::FromBase64String($hash) }
        catch { $results.Add([pscustomobject]@{ SerialNumber = $serial; Status = 'invalid'; ErrorName = "Line ${line}: hardware hash is not valid base64"; ImportId = $null }); continue }

        $tag = if ($PSBoundParameters.ContainsKey('GroupTag')) { $GroupTag } elseif ($r.PSObject.Properties['Group Tag']) { $r.'Group Tag' } else { '' }
        if ($PSCmdlet.ShouldProcess($serial, "Import Autopilot device (group tag '$tag')")) {
            $body = @{
                '@odata.type'             = '#microsoft.graph.importedWindowsAutopilotDeviceIdentity'
                serialNumber              = $serial
                hardwareIdentifier        = $hash
                groupTag                  = $tag
                productKey                = ''
                assignedUserPrincipalName = $AssignedUser
                state                     = @{ deviceImportStatus = 'pending'; deviceRegistrationId = ''; deviceErrorCode = 0; deviceErrorName = '' }
            } | ConvertTo-Json -Depth 4
            try {
                $created = Invoke-MgGraphRequest -Method POST -Uri "$script:Graph/deviceManagement/importedWindowsAutopilotDeviceIdentities" -Body $body -ContentType 'application/json' -OutputType PSObject -ErrorAction Stop
                $pending.Add([pscustomobject]@{ SerialNumber = $serial; ImportId = $created.id })
            }
            catch { $results.Add([pscustomobject]@{ SerialNumber = $serial; Status = 'error'; ErrorName = $_.Exception.Message; ImportId = $null }) }
        }
        else { $results.Add([pscustomobject]@{ SerialNumber = $serial; Status = 'whatif'; ErrorName = ''; ImportId = $null }) }
    }

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ($pending.Count) {
        foreach ($p in @($pending)) {
            $s = Invoke-MgGraphRequest -Method GET -Uri "$script:Graph/deviceManagement/importedWindowsAutopilotDeviceIdentities/$($p.ImportId)" -OutputType PSObject -ErrorAction Stop
            $status = $s.state.deviceImportStatus
            if ($status -in 'complete', 'error') {
                $err = if ($status -eq 'error') { "$($s.state.deviceErrorName) ($($s.state.deviceErrorCode))" } else { '' }
                $results.Add([pscustomobject]@{ SerialNumber = $p.SerialNumber; Status = $status; ErrorName = $err; ImportId = $p.ImportId })
                [void]$pending.Remove($p)
            }
        }
        if (-not $pending.Count) { break }
        if ((Get-Date) -ge $deadline) {
            foreach ($p in $pending) { $results.Add([pscustomobject]@{ SerialNumber = $p.SerialNumber; Status = 'timeout'; ErrorName = 'Still processing; check Intune later'; ImportId = $p.ImportId }) }
            break
        }
        Start-Sleep -Seconds $PollSeconds
    }

    if ($Sync -and @($results | Where-Object Status -eq 'complete').Count -and $PSCmdlet.ShouldProcess('Autopilot service', 'Sync')) {
        try { Invoke-MgGraphRequest -Method POST -Uri "$script:Graph/deviceManagement/windowsAutopilotSettings/sync" -ErrorAction Stop | Out-Null }
        catch { Write-Warning "Autopilot sync request failed (it is rate-limited to once every 10 minutes): $($_.Exception.Message)" }
    }
    $results.ToArray()
}

Export-ModuleMember -Function Get-AutopilotDeviceDetail, Get-AutopilotHardwareHash, Import-AutopilotDevice
