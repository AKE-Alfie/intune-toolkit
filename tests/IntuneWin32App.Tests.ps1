#Requires -Modules Pester
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'Global stubs stand in for Microsoft.Graph cmdlets')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub signatures mirror real cmdlets')]
param()

BeforeAll {
    if (-not (Get-Command Invoke-MgGraphRequest -ErrorAction SilentlyContinue)) {
        function global:Invoke-MgGraphRequest { param($Method, $Uri, $Body, $ContentType, $OutputType) }
    }
    $script:RepoRoot = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $RepoRoot 'src/IntuneWin32App.psm1') -Force
    $script:M = 'IntuneWin32App'

    # Build a fake .intunewin (same zip layout IntuneWinAppUtil produces, fake keys/content).
    function script:New-FakeIntuneWin {
        param([string]$Path, [int]$ContentBytes = 1024, [switch]$Msi)
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $root = Join-Path $TestDrive ([guid]::NewGuid())
        New-Item -ItemType Directory -Path "$root/IntuneWinPackage/Metadata", "$root/IntuneWinPackage/Contents" -Force | Out-Null
        $msiXml = if ($Msi) { '<MsiInfo><MsiProductCode>{23170F69-40C1-2702-2408-000001000000}</MsiProductCode><MsiProductVersion>24.08.00.0</MsiProductVersion></MsiInfo>' } else { '' }
        @"
<ApplicationInfo xmlns:xsd="http://www.w3.org/2001/XMLSchema" ToolVersion="1.8.6">
  <Name>DemoApp</Name><UnencryptedContentSize>900</UnencryptedContentSize><FileName>IntunePackage.intunewin</FileName><SetupFile>setup.msi</SetupFile>
  <EncryptionInfo><EncryptionKey>RkFLRUtFWQ==</EncryptionKey><MacKey>RkFLRU1BQw==</MacKey><InitializationVector>RkFLRUlW</InitializationVector><Mac>RkFLRQ==</Mac><ProfileIdentifier>ProfileVersion1</ProfileIdentifier><FileDigest>RkFLRURJRw==</FileDigest><FileDigestAlgorithm>SHA256</FileDigestAlgorithm></EncryptionInfo>
  $msiXml
</ApplicationInfo>
"@ | Set-Content "$root/IntuneWinPackage/Metadata/Detection.xml"
        [IO.File]::WriteAllBytes("$root/IntuneWinPackage/Contents/IntunePackage.intunewin", [byte[]]::new($ContentBytes))
        [IO.Compression.ZipFile]::CreateFromDirectory($root, $Path)
        $Path
    }
}

Describe 'Get-IntuneWinPackageInfo' {
    It 'parses Detection.xml and encrypted content size' {
        $p = New-FakeIntuneWin -Path (Join-Path $TestDrive 'a.intunewin') -ContentBytes 2048 -Msi
        $m = Get-IntuneWinPackageInfo -Path $p
        $m.Name | Should -Be 'DemoApp'
        $m.UnencryptedContentSize | Should -Be 900
        $m.EncryptedContentSize | Should -Be 2048
        $m.EncryptionInfo.profileIdentifier | Should -Be 'ProfileVersion1'
        $m.MsiProductCode | Should -Be '{23170F69-40C1-2702-2408-000001000000}'
    }
    It 'rejects a zip that is not a package' {
        $dir = Join-Path $TestDrive 'notpkg'; New-Item -ItemType Directory $dir | Out-Null; 'x' | Set-Content "$dir/readme.txt"
        $zip = Join-Path $TestDrive 'bad.intunewin'
        [IO.Compression.ZipFile]::CreateFromDirectory($dir, $zip)
        { Get-IntuneWinPackageInfo -Path $zip } | Should -Throw '*Detection.xml missing*'
    }
}

Describe 'New-IntuneWin32DetectionRule' {
    It 'builds an MSI product code rule' {
        (New-IntuneWin32DetectionRule -ProductCode '{23170F69-40C1-2702-2408-000001000000}').'@odata.type' | Should -Be '#microsoft.graph.win32LobAppProductCodeRule'
    }
    It 'normalises HKLM registry paths' {
        (New-IntuneWin32DetectionRule -RegistryKeyPath 'HKLM\SOFTWARE\Contoso').keyPath | Should -Be 'HKEY_LOCAL_MACHINE\SOFTWARE\Contoso'
    }
    It 'builds a file rule' {
        $r = New-IntuneWin32DetectionRule -Path 'C:\Program Files\Contoso' -FileOrFolderName 'app.exe'
        $r.operationType | Should -Be 'exists'
    }
    It 'rejects a malformed product code' {
        { New-IntuneWin32DetectionRule -ProductCode 'not-a-guid' } | Should -Throw
    }
}

Describe 'New-IntuneWinPackage' {
    It 'runs IntuneWinAppUtil with quiet switches and returns the package' {
        $src = Join-Path $TestDrive 'src'; $out = Join-Path $TestDrive 'out'
        New-Item -ItemType Directory $src, $out -Force | Out-Null
        'msi' | Set-Content "$src/setup.msi"; 'exe' | Set-Content "$TestDrive/IntuneWinAppUtil.exe"
        Mock -ModuleName $M Start-Process { Set-Content -Path ($ArgumentList[5].Trim('"') + '/setup.intunewin') -Value 'pkg'; [pscustomobject]@{ ExitCode = 0 } }
        $f = New-IntuneWinPackage -SourceFolder $src -SetupFile 'setup.msi' -OutputFolder $out -ToolPath "$TestDrive/IntuneWinAppUtil.exe"
        $f.Name | Should -Be 'setup.intunewin'
        Should -Invoke -ModuleName $M Start-Process -ParameterFilter { $ArgumentList -contains '-q' }
    }
    It 'throws when the tool fails' {
        $src = Join-Path $TestDrive 'src2'; New-Item -ItemType Directory $src -Force | Out-Null; 'msi' | Set-Content "$src/setup.msi"
        Mock -ModuleName $M Start-Process { [pscustomobject]@{ ExitCode = 1 } }
        { New-IntuneWinPackage -SourceFolder $src -SetupFile 'setup.msi' -OutputFolder (Join-Path $TestDrive 'o2') -ToolPath "$TestDrive/IntuneWinAppUtil.exe" } | Should -Throw '*exit code 1*'
    }
    It 'throws when the setup file is missing' {
        { New-IntuneWinPackage -SourceFolder $TestDrive -SetupFile 'nope.exe' -OutputFolder (Join-Path $TestDrive 'o3') -ToolPath "$TestDrive/IntuneWinAppUtil.exe" } | Should -Throw '*not found*'
    }
}

Describe 'Publish-IntuneWin32App (Graph + blob mocked)' {
    BeforeAll {
        $script:Pkg = New-FakeIntuneWin -Path (Join-Path $TestDrive 'pub.intunewin') -ContentBytes (3MB + 10) -Msi
        $script:FileStates = [System.Collections.Generic.Queue[string]]::new()
        'azureStorageUriRequestPending', 'azureStorageUriRequestSuccess', 'commitFilePending', 'commitFileSuccess' | ForEach-Object { $FileStates.Enqueue($_) }
        Mock -ModuleName $M Start-Sleep { }
        Mock -ModuleName $M Invoke-MgGraphRequest { [pscustomobject]@{ id = 'app-1' } } -ParameterFilter { $Method -eq 'POST' -and $Uri -match 'mobileApps$' }
        Mock -ModuleName $M Invoke-MgGraphRequest { [pscustomobject]@{ id = 'cv-1' } } -ParameterFilter { $Method -eq 'POST' -and $Uri -match 'contentVersions$' }
        Mock -ModuleName $M Invoke-MgGraphRequest { [pscustomobject]@{ id = 'file-1' } } -ParameterFilter { $Method -eq 'POST' -and $Uri -match 'files$' }
        Mock -ModuleName $M Invoke-MgGraphRequest { [pscustomobject]@{ uploadState = $script:FileStates.Dequeue(); azureStorageUri = 'https://fake.blob.core.windows.net/c/f?sig=x' } } -ParameterFilter { $Method -eq 'GET' }
        Mock -ModuleName $M Invoke-MgGraphRequest { } -ParameterFilter { $Uri -match 'commit$' -or $Method -eq 'PATCH' }
        Mock -ModuleName $M Invoke-RestMethod { }
        $script:Result = Publish-IntuneWin32App -Path $Pkg -Publisher 'Contoso' -InstallCommandLine 'msiexec /i setup.msi /qn' -UninstallCommandLine 'msiexec /x {23170F69-40C1-2702-2408-000001000000} /qn' -ChunkSizeMB 1 -Confirm:$false
    }
    It 'creates the app with an automatic MSI detection rule' {
        Should -Invoke -Scope Describe -ModuleName $M Invoke-MgGraphRequest -ParameterFilter { $Uri -match 'mobileApps$' -and $Body -match 'win32LobAppProductCodeRule' -and $Body -match '"setupFilePath":\s*"setup.msi"' }
    }
    It 'uploads in chunks and commits the block list' {
        $Result.Blocks | Should -Be 4
        Should -Invoke -Scope Describe -ModuleName $M Invoke-RestMethod -Times 4 -Exactly -ParameterFilter { $Uri -like '*comp=block&*' }
        Should -Invoke -Scope Describe -ModuleName $M Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $Uri -like '*comp=blocklist' -and $Body -match '<BlockList>' }
    }
    It 'commits with the package encryption info and sets the content version' {
        Should -Invoke -Scope Describe -ModuleName $M Invoke-MgGraphRequest -ParameterFilter { $Uri -match 'commit$' -and $Body -match 'ProfileVersion1' }
        Should -Invoke -Scope Describe -ModuleName $M Invoke-MgGraphRequest -ParameterFilter { $Method -eq 'PATCH' -and $Body -match '"committedContentVersion":\s*"cv-1"' }
        $Result.AppId | Should -Be 'app-1'
    }
    It 'does nothing with -WhatIf' {
        Publish-IntuneWin32App -Path $Pkg -Publisher 'Contoso' -InstallCommandLine 'a' -UninstallCommandLine 'b' -WhatIf
        Should -Invoke -ModuleName $M Invoke-MgGraphRequest -Times 0
    }
    It 'requires a detection rule for non-MSI packages' {
        $p = New-FakeIntuneWin -Path (Join-Path $TestDrive 'exe.intunewin')
        { Publish-IntuneWin32App -Path $p -Publisher 'C' -InstallCommandLine 'a' -UninstallCommandLine 'b' -WhatIf } | Should -Throw '*DetectionRule is required*'
    }
}

Describe 'Wait-IntuneWin32FileState' {
    It 'fails fast on a failed upload state' {
        Mock -ModuleName $M Invoke-MgGraphRequest { [pscustomobject]@{ uploadState = 'commitFileFailed' } }
        { Wait-IntuneWin32FileState -FileUri 'x' -State commitFileSuccess -PollSeconds 0 } | Should -Throw "*commitFileFailed*"
    }
}
