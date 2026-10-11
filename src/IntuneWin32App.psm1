#Requires -Version 7.0
<#
    IntuneWin32App module
    Packages installers with Microsoft's IntuneWinAppUtil.exe and uploads the result to Intune
    as a Win32 app through Microsoft Graph (content version, Azure blob chunked upload, commit).
#>

Set-StrictMode -Version Latest
$script:Graph = 'https://graph.microsoft.com/v1.0'
$script:ToolUrl = 'https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool/raw/master/IntuneWinAppUtil.exe'

#region Packaging
function Get-IntuneWinAppUtil {
    <#
    .SYNOPSIS
        Downloads IntuneWinAppUtil.exe from Microsoft's official GitHub repository (if not already present).
    .PARAMETER Path
        Folder to save the tool in.
    .PARAMETER Force
        Download again even if the file exists.
    .OUTPUTS
        Full path to IntuneWinAppUtil.exe
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path, [switch]$Force)
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
    $exe = Join-Path $Path 'IntuneWinAppUtil.exe'
    if ($Force -or -not (Test-Path -LiteralPath $exe)) {
        Write-Verbose "Downloading IntuneWinAppUtil.exe from $script:ToolUrl"
        Invoke-WebRequest -Uri $script:ToolUrl -OutFile $exe -UseBasicParsing -ErrorAction Stop
    }
    $exe
}

function New-IntuneWinPackage {
    <#
    .SYNOPSIS
        Wraps IntuneWinAppUtil.exe to build a .intunewin package from a source folder.
    .PARAMETER SourceFolder
        Folder containing the installer and any supporting files.
    .PARAMETER SetupFile
        Installer file name inside SourceFolder (e.g. setup.exe, app.msi, Install.ps1).
    .PARAMETER OutputFolder
        Where the .intunewin file is written.
    .PARAMETER ToolPath
        Path to IntuneWinAppUtil.exe. Use Get-IntuneWinAppUtil to download it.
    .PARAMETER Force
        Overwrite an existing package.
    .EXAMPLE
        New-IntuneWinPackage -SourceFolder .\src\7zip -SetupFile 7z2408-x64.msi -OutputFolder .\out -ToolPath .\tools\IntuneWinAppUtil.exe
    .OUTPUTS
        System.IO.FileInfo of the created .intunewin
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })][string]$SourceFolder,
        [Parameter(Mandatory)][ValidatePattern('\.(exe|msi|ps1|cmd|bat)$')][string]$SetupFile,
        [Parameter(Mandatory)][string]$OutputFolder,
        [Parameter(Mandatory)][ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })][string]$ToolPath,
        [switch]$Force
    )
    $setupFull = Join-Path $SourceFolder $SetupFile
    if (-not (Test-Path -LiteralPath $setupFull -PathType Leaf)) { throw "Setup file '$SetupFile' not found in '$SourceFolder'" }
    if (-not (Test-Path -LiteralPath $OutputFolder)) { New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null }

    $expected = Join-Path $OutputFolder (([System.IO.Path]::GetFileNameWithoutExtension($SetupFile)) + '.intunewin')
    if ((Test-Path -LiteralPath $expected) -and -not $Force) { throw "Package already exists: $expected (use -Force to overwrite)" }

    if ($PSCmdlet.ShouldProcess($expected, 'Build .intunewin package')) {
        if (Test-Path -LiteralPath $expected) { Remove-Item -LiteralPath $expected -Force }
        $argList = @('-c', "`"$((Resolve-Path $SourceFolder).Path)`"", '-s', "`"$SetupFile`"", '-o', "`"$((Resolve-Path $OutputFolder).Path)`"", '-q')
        Write-Verbose "Running $ToolPath $($argList -join ' ')"
        $p = Start-Process -FilePath $ToolPath -ArgumentList $argList -Wait -PassThru -NoNewWindow
        if ($p.ExitCode -ne 0) { throw "IntuneWinAppUtil.exe failed with exit code $($p.ExitCode)" }
        if (-not (Test-Path -LiteralPath $expected)) { throw "IntuneWinAppUtil.exe finished but $expected was not created" }
        Get-Item -LiteralPath $expected
    }
}

function Get-IntuneWinPackageInfo {
    <#
    .SYNOPSIS
        Reads Detection.xml (name, sizes, encryption info, MSI info) from a .intunewin package.
    .PARAMETER Path
        Path to the .intunewin file.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })][string]$Path)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead((Resolve-Path -LiteralPath $Path).Path)
    try {
        $entry = $zip.Entries | Where-Object FullName -eq 'IntuneWinPackage/Metadata/Detection.xml' | Select-Object -First 1
        if (-not $entry) { throw "'$Path' is not a valid .intunewin package (Detection.xml missing)" }
        $reader = [System.IO.StreamReader]::new($entry.Open())
        try { [xml]$xml = $reader.ReadToEnd() } finally { $reader.Dispose() }
        $content = $zip.Entries | Where-Object FullName -like 'IntuneWinPackage/Contents/*' | Select-Object -First 1
        if (-not $content) { throw "'$Path' has no encrypted content file" }
    }
    finally { $zip.Dispose() }

    $ai = $xml.ApplicationInfo
    $enc = $ai.EncryptionInfo
    $msi = if ($ai.PSObject.Properties['MsiInfo'] -and $ai.MsiInfo) { $ai.MsiInfo } else { $null }
    [pscustomobject]@{
        Name                   = $ai.Name
        SetupFile              = $ai.SetupFile
        FileName               = $ai.FileName
        UnencryptedContentSize = [long]$ai.UnencryptedContentSize
        EncryptedContentName   = $content.FullName
        EncryptedContentSize   = [long]$content.Length
        EncryptionInfo         = [ordered]@{
            encryptionKey        = $enc.EncryptionKey
            macKey               = $enc.MacKey
            initializationVector = $enc.InitializationVector
            mac                  = $enc.Mac
            profileIdentifier    = $enc.ProfileIdentifier
            fileDigest           = $enc.FileDigest
            fileDigestAlgorithm  = $enc.FileDigestAlgorithm
        }
        MsiProductCode         = if ($msi) { $msi.MsiProductCode } else { $null }
        MsiProductVersion      = if ($msi) { $msi.MsiProductVersion } else { $null }
    }
}
#endregion

#region Detection rules
function New-IntuneWin32DetectionRule {
    <#
    .SYNOPSIS
        Builds a Graph win32LobAppRule (detection) object.
    .PARAMETER ProductCode
        MSI product code detection.
    .PARAMETER Path
        Folder for a file/folder existence rule.
    .PARAMETER FileOrFolderName
        File or folder name for the file rule.
    .PARAMETER RegistryKeyPath
        Registry key for a registry existence rule (e.g. HKEY_LOCAL_MACHINE\SOFTWARE\Contoso\App).
    .PARAMETER ValueName
        Registry value name (optional).
    .PARAMETER Check32BitOn64System
        Look in the 32-bit view on 64-bit Windows.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Only builds an in-memory object')]
    [CmdletBinding(DefaultParameterSetName = 'Msi')]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Msi')][ValidatePattern('^\{[0-9A-Fa-f-]{36}\}$')][string]$ProductCode,
        [Parameter(Mandatory, ParameterSetName = 'File')][string]$Path,
        [Parameter(Mandatory, ParameterSetName = 'File')][string]$FileOrFolderName,
        [Parameter(Mandatory, ParameterSetName = 'Registry')][ValidatePattern('^(HKEY_LOCAL_MACHINE|HKEY_CURRENT_USER|HKLM|HKCU)\\')][string]$RegistryKeyPath,
        [Parameter(ParameterSetName = 'Registry')][string]$ValueName,
        [switch]$Check32BitOn64System
    )
    switch ($PSCmdlet.ParameterSetName) {
        'Msi' {
            [ordered]@{ '@odata.type' = '#microsoft.graph.win32LobAppProductCodeRule'; ruleType = 'detection'; productCode = $ProductCode; productVersionOperator = 'notConfigured'; productVersion = $null }
        }
        'File' {
            [ordered]@{ '@odata.type' = '#microsoft.graph.win32LobAppFileSystemRule'; ruleType = 'detection'; path = $Path; fileOrFolderName = $FileOrFolderName
                check32BitOn64System = [bool]$Check32BitOn64System; operationType = 'exists'; operator = 'notConfigured'; comparisonValue = $null }
        }
        'Registry' {
            $key = $RegistryKeyPath -replace '^HKLM\\', 'HKEY_LOCAL_MACHINE\' -replace '^HKCU\\', 'HKEY_CURRENT_USER\'
            [ordered]@{ '@odata.type' = '#microsoft.graph.win32LobAppRegistryRule'; ruleType = 'detection'; keyPath = $key; valueName = $ValueName
                check32BitOn64System = [bool]$Check32BitOn64System; operationType = 'exists'; operator = 'notConfigured'; comparisonValue = $null }
        }
    }
}
#endregion

#region Upload
function Wait-IntuneWin32FileState {
    <#
    .SYNOPSIS
        Polls a content file until it reaches the wanted uploadState.
    .PARAMETER FileUri
        Graph URI of the content file.
    .PARAMETER State
        Target state (azureStorageUriRequestSuccess or commitFileSuccess).
    .PARAMETER TimeoutSeconds
        Give up after this long.
    .PARAMETER PollSeconds
        Seconds between polls.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FileUri,
        [Parameter(Mandatory)][ValidateSet('azureStorageUriRequestSuccess', 'commitFileSuccess')][string]$State,
        [ValidateRange(1, 3600)][int]$TimeoutSeconds = 300,
        [ValidateRange(0, 60)][int]$PollSeconds = 5
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ($true) {
        $f = Invoke-MgGraphRequest -Method GET -Uri $FileUri -OutputType PSObject -ErrorAction Stop
        if ($f.uploadState -eq $State) { return $f }
        if ($f.uploadState -like '*Failed' -or $f.uploadState -like '*TimedOut') { throw "Content file entered state '$($f.uploadState)' while waiting for '$State'" }
        if ((Get-Date) -ge $deadline) { throw "Timed out after ${TimeoutSeconds}s waiting for '$State' (last state: $($f.uploadState))" }
        Start-Sleep -Seconds $PollSeconds
    }
}

function Send-IntuneWin32BlobContent {
    <#
    .SYNOPSIS
        Uploads a file to an Azure Storage SAS URI as a block blob in chunks.
    .PARAMETER SasUri
        azureStorageUri returned by Intune.
    .PARAMETER Bytes
        File content.
    .PARAMETER ChunkSizeMB
        Block size in MB (default 6).
    .OUTPUTS
        Number of blocks uploaded.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)][string]$SasUri, [Parameter(Mandatory)][byte[]]$Bytes, [ValidateRange(1, 100)][int]$ChunkSizeMB = 6)
    $chunk = $ChunkSizeMB * 1MB
    $ids = [System.Collections.Generic.List[string]]::new()
    $count = [math]::Max(1, [math]::Ceiling($Bytes.Length / $chunk))
    for ($i = 0; $i -lt $count; $i++) {
        $id = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($i.ToString('0000')))
        $start = $i * $chunk
        $len = [math]::Min($chunk, $Bytes.Length - $start)
        $part = [byte[]]::new($len)
        [Array]::Copy($Bytes, $start, $part, 0, $len)
        Invoke-RestMethod -Method Put -Uri "$SasUri&comp=block&blockid=$([uri]::EscapeDataString($id))" -Body $part `
            -Headers @{ 'x-ms-blob-type' = 'BlockBlob' } -ContentType 'application/octet-stream' -ErrorAction Stop | Out-Null
        $ids.Add($id)
        Write-Verbose "Uploaded block $($i + 1)/$count"
    }
    $xml = '<?xml version="1.0" encoding="utf-8"?><BlockList>' + (($ids | ForEach-Object { "<Latest>$_</Latest>" }) -join '') + '</BlockList>'
    Invoke-RestMethod -Method Put -Uri "$SasUri&comp=blocklist" -Body $xml -ContentType 'application/xml' -ErrorAction Stop | Out-Null
    $count
}

function Publish-IntuneWin32App {
    <#
    .SYNOPSIS
        Creates a Win32 app in Intune and uploads a .intunewin package to it.
    .DESCRIPTION
        1. POST mobileApps (win32LobApp)  2. create content version  3. create content file
        4. wait for Azure SAS URI  5. chunked blob upload  6. commit with encryption info
        7. wait for commit  8. set committedContentVersion.
        Requires DeviceManagementApps.ReadWrite.All.
    .PARAMETER Path
        Path to the .intunewin file.
    .PARAMETER DisplayName
        App name in Intune. Defaults to the package name.
    .PARAMETER Publisher
        Publisher shown in Company Portal.
    .PARAMETER Description
        App description.
    .PARAMETER InstallCommandLine
        Install command (e.g. 'msiexec /i app.msi /qn' or 'setup.exe /S').
    .PARAMETER UninstallCommandLine
        Uninstall command.
    .PARAMETER DetectionRule
        One or more rules from New-IntuneWin32DetectionRule. For MSI packages a product-code rule is created automatically if omitted.
    .PARAMETER RunAsAccount
        system or user.
    .PARAMETER Architecture
        x64, x86 or 'x86,x64'.
    .PARAMETER ChunkSizeMB
        Upload block size.
    .PARAMETER TimeoutSeconds
        Per-wait timeout for Intune processing.
    .EXAMPLE
        $rule = New-IntuneWin32DetectionRule -ProductCode '{23170F69-40C1-2702-2408-000001000000}'
        Publish-IntuneWin32App -Path .\out\7z2408-x64.intunewin -DisplayName '7-Zip 24.08' -Publisher 'Igor Pavlov' `
            -InstallCommandLine 'msiexec /i 7z2408-x64.msi /qn' -UninstallCommandLine 'msiexec /x {23170F69-40C1-2702-2408-000001000000} /qn' -DetectionRule $rule
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory)][ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })][string]$Path,
        [ValidateLength(1, 200)][string]$DisplayName,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Publisher,
        [string]$Description,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$InstallCommandLine,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$UninstallCommandLine,
        [System.Collections.IDictionary[]]$DetectionRule,
        [ValidateSet('system', 'user')][string]$RunAsAccount = 'system',
        [ValidateSet('x64', 'x86', 'x86,x64')][string]$Architecture = 'x64',
        [ValidateRange(1, 100)][int]$ChunkSizeMB = 6,
        [ValidateRange(1, 3600)][int]$TimeoutSeconds = 600
    )
    $meta = Get-IntuneWinPackageInfo -Path $Path
    if (-not $DisplayName) { $DisplayName = $meta.Name }
    if (-not $DetectionRule) {
        if ($meta.MsiProductCode) { $DetectionRule = @(New-IntuneWin32DetectionRule -ProductCode $meta.MsiProductCode) }
        else { throw 'A -DetectionRule is required for non-MSI packages' }
    }

    $app = [ordered]@{
        '@odata.type'                   = '#microsoft.graph.win32LobApp'
        displayName                     = $DisplayName
        description                     = if ($Description) { $Description } else { $DisplayName }
        publisher                       = $Publisher
        fileName                        = [System.IO.Path]::GetFileName($Path)
        setupFilePath                   = $meta.SetupFile
        installCommandLine              = $InstallCommandLine
        uninstallCommandLine            = $UninstallCommandLine
        applicableArchitectures         = $Architecture
        minimumSupportedOperatingSystem = @{ v10_1607 = $true }
        installExperience               = @{ runAsAccount = $RunAsAccount; deviceRestartBehavior = 'basedOnReturnCode' }
        rules                           = @($DetectionRule)
        returnCodes                     = @(
            @{ returnCode = 0; type = 'success' }, @{ returnCode = 1707; type = 'success' }, @{ returnCode = 3010; type = 'softReboot' }
            @{ returnCode = 1641; type = 'hardReboot' }, @{ returnCode = 1618; type = 'retry' }
        )
    }
    if ($meta.MsiProductCode) {
        $app.msiInformation = @{ productCode = $meta.MsiProductCode; productVersion = $meta.MsiProductVersion; packageType = 'perMachine' }
    }

    if (-not $PSCmdlet.ShouldProcess($DisplayName, 'Create Win32 app in Intune and upload content')) { return }

    $created = Invoke-MgGraphRequest -Method POST -Uri "$script:Graph/deviceAppManagement/mobileApps" -Body ($app | ConvertTo-Json -Depth 10) -ContentType 'application/json' -OutputType PSObject -ErrorAction Stop
    $appUri = "$script:Graph/deviceAppManagement/mobileApps/$($created.id)"
    Write-Verbose "Created app $($created.id)"
    try {
        $cv = Invoke-MgGraphRequest -Method POST -Uri "$appUri/microsoft.graph.win32LobApp/contentVersions" -Body '{}' -ContentType 'application/json' -OutputType PSObject -ErrorAction Stop
        $filesUri = "$appUri/microsoft.graph.win32LobApp/contentVersions/$($cv.id)/files"
        $fileBody = @{ '@odata.type' = '#microsoft.graph.mobileAppContentFile'; name = [System.IO.Path]::GetFileName($Path)
            size = $meta.UnencryptedContentSize; sizeEncrypted = $meta.EncryptedContentSize; manifest = $null; isDependency = $false } | ConvertTo-Json
        $file = Invoke-MgGraphRequest -Method POST -Uri $filesUri -Body $fileBody -ContentType 'application/json' -OutputType PSObject -ErrorAction Stop
        $fileUri = "$filesUri/$($file.id)"

        $ready = Wait-IntuneWin32FileState -FileUri $fileUri -State azureStorageUriRequestSuccess -TimeoutSeconds $TimeoutSeconds
        $bytes = Get-IntuneWinEncryptedContent -Path $Path -EntryName $meta.EncryptedContentName
        $blocks = Send-IntuneWin32BlobContent -SasUri $ready.azureStorageUri -Bytes $bytes -ChunkSizeMB $ChunkSizeMB

        $commit = @{ fileEncryptionInfo = $meta.EncryptionInfo } | ConvertTo-Json -Depth 5
        Invoke-MgGraphRequest -Method POST -Uri "$fileUri/commit" -Body $commit -ContentType 'application/json' -ErrorAction Stop | Out-Null
        Wait-IntuneWin32FileState -FileUri $fileUri -State commitFileSuccess -TimeoutSeconds $TimeoutSeconds | Out-Null

        $patch = @{ '@odata.type' = '#microsoft.graph.win32LobApp'; committedContentVersion = $cv.id } | ConvertTo-Json
        Invoke-MgGraphRequest -Method PATCH -Uri $appUri -Body $patch -ContentType 'application/json' -ErrorAction Stop | Out-Null
    }
    catch {
        Write-Warning "Upload failed; app '$DisplayName' ($($created.id)) was created without content. Delete it or re-run. Error: $($_.Exception.Message)"
        throw
    }
    [pscustomobject]@{ AppId = $created.id; DisplayName = $DisplayName; ContentVersion = $cv.id; Blocks = $blocks; SizeBytes = $meta.UnencryptedContentSize }
}

function Get-IntuneWinEncryptedContent {
    <#
    .SYNOPSIS
        Returns the encrypted inner payload of a .intunewin package as bytes.
    .PARAMETER Path
        Path to the .intunewin file.
    .PARAMETER EntryName
        Zip entry name of the encrypted content.
    #>
    [CmdletBinding()]
    [OutputType([byte[]], [System.Array])]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$EntryName)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead((Resolve-Path -LiteralPath $Path).Path)
    try {
        $e = $zip.GetEntry($EntryName)
        $ms = [System.IO.MemoryStream]::new()
        $s = $e.Open(); try { $s.CopyTo($ms) } finally { $s.Dispose() }
        , $ms.ToArray()
    }
    finally { $zip.Dispose() }
}
#endregion

Export-ModuleMember -Function Get-IntuneWinAppUtil, New-IntuneWinPackage, Get-IntuneWinPackageInfo, New-IntuneWin32DetectionRule,
    Wait-IntuneWin32FileState, Send-IntuneWin32BlobContent, Publish-IntuneWin32App, Get-IntuneWinEncryptedContent
