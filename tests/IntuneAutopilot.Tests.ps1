#Requires -Modules Pester
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'Global stubs stand in for Microsoft.Graph cmdlets')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub signatures mirror real cmdlets')]
param()

BeforeAll {
    if (-not (Get-Command Invoke-MgGraphRequest -ErrorAction SilentlyContinue)) {
        function global:Invoke-MgGraphRequest { param($Method, $Uri, $Body, $ContentType, $OutputType) }
    }
    $script:RepoRoot = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $RepoRoot 'src/IntuneAutopilot.psm1') -Force
    $script:M = 'IntuneAutopilot'
    $script:Hash = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes('FAKE-HARDWARE-HASH-FOR-TESTS'))
}

Describe 'Get-AutopilotHardwareHash' {
    BeforeEach {
        Mock -ModuleName $M Get-AutopilotDeviceDetail { [pscustomobject]@{ SerialNumber = 'DEMO-SN-001'; HardwareHash = $script:Hash; ComputerName = 'PC1' } }
    }
    It 'writes the Intune CSV header and does not duplicate a serial' -Skip:(-not $IsWindows) {
        $csv = Join-Path $TestDrive 'ap.csv'
        Get-AutopilotHardwareHash -OutputCsv $csv -GroupTag 'Std' | Out-Null
        Get-AutopilotHardwareHash -OutputCsv $csv -GroupTag 'Std' -WarningAction SilentlyContinue | Out-Null
        (Get-Content $csv)[0] | Should -Be '"Device Serial Number","Windows Product ID","Hardware Hash","Group Tag"'
        @(Import-Csv $csv).Count | Should -Be 1
    }
    It 'refuses to run on non-Windows' -Skip:($IsWindows) {
        { Get-AutopilotHardwareHash } | Should -Throw '*only runs on Windows*'
    }
}

Describe 'Import-AutopilotDevice' {
    BeforeAll {
        $script:Csv = Join-Path $TestDrive 'devices.csv'
        @(
            [pscustomobject]@{ 'Device Serial Number' = 'SN-OK'; 'Windows Product ID' = ''; 'Hardware Hash' = $Hash; 'Group Tag' = 'Std' }
            [pscustomobject]@{ 'Device Serial Number' = 'SN-DUP'; 'Windows Product ID' = ''; 'Hardware Hash' = $Hash; 'Group Tag' = 'Std' }
            [pscustomobject]@{ 'Device Serial Number' = 'SN-BAD'; 'Windows Product ID' = ''; 'Hardware Hash' = 'not base64!!'; 'Group Tag' = '' }
        ) | Export-Csv $Csv -NoTypeInformation
    }
    BeforeEach {
        Mock -ModuleName $M Start-Sleep { }
        Mock -ModuleName $M Invoke-MgGraphRequest { [pscustomobject]@{ id = 'imp-' + ($Body | ConvertFrom-Json).serialNumber } } -ParameterFilter { $Method -eq 'POST' -and $Uri -like '*importedWindowsAutopilotDeviceIdentities' }
        Mock -ModuleName $M Invoke-MgGraphRequest {
            if ($Uri -like '*imp-SN-DUP') { [pscustomobject]@{ state = [pscustomobject]@{ deviceImportStatus = 'error'; deviceErrorCode = 806; deviceErrorName = 'ZtdDeviceAlreadyAssigned' } } }
            else { [pscustomobject]@{ state = [pscustomobject]@{ deviceImportStatus = 'complete'; deviceErrorCode = 0; deviceErrorName = '' } } }
        } -ParameterFilter { $Method -eq 'GET' }
        Mock -ModuleName $M Invoke-MgGraphRequest { } -ParameterFilter { $Uri -like '*sync' }
    }
    It 'imports valid rows, reports errors and invalid hashes' {
        $r = Import-AutopilotDevice -CsvPath $Csv -Sync -PollSeconds 0 -Confirm:$false
        ($r | Where-Object SerialNumber -eq 'SN-OK').Status | Should -Be 'complete'
        ($r | Where-Object SerialNumber -eq 'SN-DUP').ErrorName | Should -Match 'ZtdDeviceAlreadyAssigned'
        ($r | Where-Object SerialNumber -eq 'SN-BAD').Status | Should -Be 'invalid'
        Should -Invoke -ModuleName $M Invoke-MgGraphRequest -Times 1 -Exactly -ParameterFilter { $Uri -like '*sync' }
    }
    It 'overrides the group tag when asked' {
        Import-AutopilotDevice -CsvPath $Csv -GroupTag 'Kiosk' -PollSeconds 0 -Confirm:$false | Out-Null
        Should -Invoke -ModuleName $M Invoke-MgGraphRequest -Times 2 -Exactly -ParameterFilter { $Method -eq 'POST' -and $Body -match '"groupTag":\s*"Kiosk"' }
    }
    It 'makes no changes with -WhatIf' {
        $r = Import-AutopilotDevice -CsvPath $Csv -WhatIf
        Should -Invoke -ModuleName $M Invoke-MgGraphRequest -Times 0
        @($r | Where-Object Status -eq 'whatif').Count | Should -Be 2
    }
    It 'rejects a CSV without the required columns' {
        $bad = Join-Path $TestDrive 'bad.csv'; "Serial,Hash`n1,2" | Set-Content $bad
        { Import-AutopilotDevice -CsvPath $bad -WhatIf } | Should -Throw "*missing the 'Device Serial Number' column*"
    }
}
