@{
    RootModule        = ''
    ModuleVersion     = '1.1.0'
    GUID              = '5d0b6f2e-8a51-4c2e-9e57-3b1f4f6f7a10'
    Author            = 'Miguel'
    Copyright         = '(c) 2026 Miguel. MIT License.'
    Description       = 'Intune toolkit: compliance reporting, Win32 app packaging/upload and Autopilot hardware hash import via Microsoft Graph.'
    PowerShellVersion = '7.0'
    NestedModules     = @('src/IntuneComplianceReport.psm1', 'src/IntuneWin32App.psm1', 'src/IntuneAutopilot.psm1')
    FunctionsToExport = @(
        'Connect-ICRGraph', 'Get-ICRManagedDevice', 'Get-ICRSummary', 'ConvertTo-ICRHtml', 'Invoke-ICRGraphPagedRequest', 'Write-ICRLog',
        'Get-IntuneWinAppUtil', 'New-IntuneWinPackage', 'Get-IntuneWinPackageInfo', 'New-IntuneWin32DetectionRule', 'Publish-IntuneWin32App',
        'Wait-IntuneWin32FileState', 'Send-IntuneWin32BlobContent', 'Get-IntuneWinEncryptedContent',
        'Get-AutopilotDeviceDetail', 'Get-AutopilotHardwareHash', 'Import-AutopilotDevice'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData       = @{ PSData = @{ Tags = @('Intune', 'Graph', 'Autopilot', 'Win32', 'MSP'); LicenseUri = 'https://opensource.org/licenses/MIT' } }
}
