#Requires -Modules Pester
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'Global stubs stand in for Microsoft.Graph cmdlets')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub signatures mirror real cmdlets')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '', Justification = 'Stub only')]
param()
BeforeAll {
    # Stub Graph cmdlets so tests run without the Microsoft.Graph module or a tenant.
    if (-not (Get-Command Invoke-MgGraphRequest -ErrorAction SilentlyContinue)) {
        function global:Invoke-MgGraphRequest { param($Method, $Uri, $OutputType, $Body) }
    }
    if (-not (Get-Command Connect-MgGraph -ErrorAction SilentlyContinue)) {
        function global:Connect-MgGraph { param($TenantId, $ClientId, $CertificateThumbprint, $ClientSecretCredential, $Scopes, [switch]$UseDeviceCode, [switch]$NoWelcome) }
    }
    $script:RepoRoot = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $RepoRoot 'src/IntuneComplianceReport.psm1') -Force

    $now = (Get-Date).ToUniversalTime()
    $script:FakeDevices = @(
        [pscustomobject]@{ id = '1'; deviceName = 'CON-LT-001'; userPrincipalName = 'ana@contoso.example'; userDisplayName = 'Ana'; operatingSystem = 'Windows'; osVersion = '10.0.22631'; complianceState = 'compliant'; lastSyncDateTime = $now.AddHours(-3).ToString('o'); managedDeviceOwnerType = 'company'; model = 'Latitude 7440'; manufacturer = 'Dell'; serialNumber = 'FAKE001'; isEncrypted = $true; jailBroken = 'False' }
        [pscustomobject]@{ id = '2'; deviceName = 'CON-LT-002'; userPrincipalName = 'ben@contoso.example'; userDisplayName = 'Ben'; operatingSystem = 'Windows'; osVersion = '10.0.19045'; complianceState = 'noncompliant'; lastSyncDateTime = $now.AddDays(-45).ToString('o'); managedDeviceOwnerType = 'company'; model = 'ThinkPad T14'; manufacturer = 'Lenovo'; serialNumber = 'FAKE002'; isEncrypted = $false; jailBroken = 'False' }
        [pscustomobject]@{ id = '3'; deviceName = 'Cara-iPhone'; userPrincipalName = 'cara@contoso.example'; userDisplayName = 'Cara <script>'; operatingSystem = 'iOS'; osVersion = '17.5'; complianceState = 'inGracePeriod'; lastSyncDateTime = $now.AddDays(-1).ToString('o'); managedDeviceOwnerType = 'personal'; model = 'iPhone 15'; manufacturer = 'Apple'; serialNumber = 'FAKE003'; isEncrypted = $true; jailBroken = 'False' }
    )
}

Describe 'Invoke-ICRGraphPagedRequest' {
    It 'follows @odata.nextLink across pages' {
        Mock -ModuleName IntuneComplianceReport Invoke-MgGraphRequest -ParameterFilter { $Uri -eq 'page1' } {
            [pscustomobject]@{ value = @($FakeDevices[0], $FakeDevices[1]); '@odata.nextLink' = 'page2' }
        }
        Mock -ModuleName IntuneComplianceReport Invoke-MgGraphRequest -ParameterFilter { $Uri -eq 'page2' } {
            [pscustomobject]@{ value = @($FakeDevices[2]) }
        }
        $r = Invoke-ICRGraphPagedRequest -Uri 'page1'
        $r.Count | Should -Be 3
        Should -Invoke -ModuleName IntuneComplianceReport Invoke-MgGraphRequest -Times 2 -Exactly
    }

    It 'rethrows non-transient errors' {
        Mock -ModuleName IntuneComplianceReport Invoke-MgGraphRequest { throw 'Forbidden' }
        { Invoke-ICRGraphPagedRequest -Uri 'x' } | Should -Throw '*Forbidden*'
    }
}

Describe 'Get-ICRManagedDevice' {
    BeforeEach {
        Mock -ModuleName IntuneComplianceReport Invoke-MgGraphRequest { [pscustomobject]@{ value = $FakeDevices } }
    }

    It 'returns all devices mapped to report columns' {
        $r = @(Get-ICRManagedDevice)
        $r.Count | Should -Be 3
        $r[0].PSObject.Properties.Name | Should -Contain 'ComplianceState'
        $r[0].PSObject.Properties.Name | Should -Contain 'DaysSinceSync'
    }

    It 'filters by operating system' {
        $r = @(Get-ICRManagedDevice -OperatingSystem iOS)
        $r.Count | Should -Be 1
        $r[0].DeviceName | Should -Be 'Cara-iPhone'
    }

    It 'filters to non-compliant devices and sends a server-side filter' {
        $r = @(Get-ICRManagedDevice -NonCompliantOnly)
        $r.Count | Should -Be 2
        $r.ComplianceState | Should -Not -Contain 'compliant'
        Should -Invoke -ModuleName IntuneComplianceReport Invoke-MgGraphRequest -ParameterFilter { $Uri -like "*complianceState ne 'compliant'*" }
    }

    It 'flags stale devices' {
        $r = @(Get-ICRManagedDevice -StaleDays 30)
        ($r | Where-Object DeviceName -eq 'CON-LT-002').IsStale | Should -BeTrue
        ($r | Where-Object DeviceName -eq 'CON-LT-001').IsStale | Should -BeFalse
    }

    It 'rejects an unsupported OS value' {
        { Get-ICRManagedDevice -OperatingSystem 'BeOS' } | Should -Throw
    }
}

Describe 'Reporting' {
    BeforeAll {
        Mock -ModuleName IntuneComplianceReport Invoke-MgGraphRequest { [pscustomobject]@{ value = $FakeDevices } }
        $script:Rows = @(Get-ICRManagedDevice)
    }

    It 'computes summary counts' {
        $s = Get-ICRSummary -Device $Rows
        $s.Total | Should -Be 3
        $s.Compliant | Should -Be 1
        $s.NonCompliant | Should -Be 2
        $s.CompliancePct | Should -Be 33.3
    }

    It 'handles an empty device list' {
        (Get-ICRSummary -Device @()).CompliancePct | Should -Be 0
        ConvertTo-ICRHtml -Device @() | Should -Match '<html'
    }

    It 'HTML-encodes values to prevent injection' {
        $html = ConvertTo-ICRHtml -Device $Rows -TenantName 'Contoso'
        $html | Should -Not -Match '<script>'
        $html | Should -Match 'CON-LT-002'
        $html | Should -Match 'Contoso'
    }
}

Describe 'Connect-ICRGraph' {
    It 'uses delegated scopes by default' {
        Mock -ModuleName IntuneComplianceReport Connect-MgGraph { }
        Connect-ICRGraph -TenantId 'contoso.example'
        Should -Invoke -ModuleName IntuneComplianceReport Connect-MgGraph -ParameterFilter { $Scopes -contains 'DeviceManagementManagedDevices.Read.All' }
    }

    It 'uses certificate auth when ClientId and thumbprint are supplied' {
        Mock -ModuleName IntuneComplianceReport Connect-MgGraph { }
        Connect-ICRGraph -TenantId 'contoso.example' -ClientId '00000000-0000-0000-0000-000000000000' -CertificateThumbprint ('A' * 40)
        Should -Invoke -ModuleName IntuneComplianceReport Connect-MgGraph -ParameterFilter { $CertificateThumbprint -eq ('A' * 40) -and -not $Scopes }
    }

    It 'validates the thumbprint format' {
        { Connect-ICRGraph -TenantId 't' -ClientId '00000000-0000-0000-0000-000000000000' -CertificateThumbprint 'bad' } | Should -Throw
    }
}

Describe 'Get-IntuneComplianceReport.ps1 (end to end, mocked)' {
    It 'writes CSV, HTML and log files' {
        $out = Join-Path $TestDrive 'out'
        # The script re-imports the module with -Force (dropping module-scoped mocks),
        # so swap the global Graph stub for one that returns fake data.
        $global:ICRFakeDevices = $FakeDevices
        function global:Invoke-MgGraphRequest { param($Method, $Uri, $OutputType, $Body) [pscustomobject]@{ value = $global:ICRFakeDevices } }

        $r = & (Join-Path $RepoRoot 'Get-IntuneComplianceReport.ps1') -TenantId 'contoso.example' -SkipConnect -OutputPath $out
        Test-Path $r.CsvPath | Should -BeTrue
        Test-Path $r.HtmlPath | Should -BeTrue
        Test-Path $r.LogPath | Should -BeTrue
        (Import-Csv $r.CsvPath).Count | Should -Be 3
        $r.Summary.NonCompliant | Should -Be 2
    }
}
