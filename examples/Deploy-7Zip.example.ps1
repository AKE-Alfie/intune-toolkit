<#
.SYNOPSIS
    End-to-end example: package an MSI with IntuneWinAppUtil and publish it to Intune as a Win32 app.
.DESCRIPTION
    Edit the paths/IDs for your environment. Nothing in this file is a real tenant value.
    Requires Windows (IntuneWinAppUtil.exe is a Windows tool) and DeviceManagementApps.ReadWrite.All.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$TenantId = 'fabrikam.onmicrosoft.com',
    [string]$SourceFolder = 'C:\Packaging\7zip\source',
    [string]$SetupFile = '7z2408-x64.msi',
    [string]$OutputFolder = 'C:\Packaging\7zip\out'
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../IntuneToolkit.psd1') -Force
Connect-ICRGraph -TenantId $TenantId    # delegated sign-in; see README for app-only

$tool = Get-IntuneWinAppUtil -Path 'C:\Packaging\tools'
$pkg = New-IntuneWinPackage -SourceFolder $SourceFolder -SetupFile $SetupFile -OutputFolder $OutputFolder -ToolPath $tool -Force
$info = Get-IntuneWinPackageInfo -Path $pkg.FullName

Publish-IntuneWin32App -Path $pkg.FullName -DisplayName '7-Zip 24.08 (x64)' -Publisher 'Igor Pavlov' `
    -InstallCommandLine "msiexec /i `"$SetupFile`" /qn /norestart" `
    -UninstallCommandLine "msiexec /x $($info.MsiProductCode) /qn /norestart" -Verbose -WhatIf:$WhatIfPreference
