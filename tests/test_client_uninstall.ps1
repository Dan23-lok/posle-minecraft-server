$ErrorActionPreference = 'Stop'

$sourceUninstaller = Join-Path $PSScriptRoot '..\client-pack\Uninstall-HorrorClient.ps1'
$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$scratch = [IO.Path]::GetFullPath((Join-Path $tempRoot ('posle-uninstall-' + [Guid]::NewGuid().ToString('N'))))
if (-not $scratch.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Scratch directory is outside the system temp directory.'
}

function Assert-True {
    param([bool]$Condition, [string]$Case)
    if (-not $Condition) { throw $Case }
}

function New-ManagedFile {
    param([string]$Client, [string]$Folder, [string]$Filename, [string]$Content,
        [string]$Algorithm = 'SHA256', [bool]$Created = $true)
    $directory = Join-Path $Client $Folder
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $file = Join-Path $directory $Filename
    [IO.File]::WriteAllText($file, $Content)
    return [ordered]@{
        folder = $Folder
        filename = $Filename
        hash_algorithm = $Algorithm
        hash = (Get-FileHash -LiteralPath $file -Algorithm $Algorithm).Hash
        default_enabled = ($Folder -eq 'resourcepacks')
        created_by_posle = $Created
    }
}

function Write-Receipt {
    param([string]$Client, [object[]]$Files, [string]$DirectoryOverride)
    New-Item -ItemType Directory -Path $Client -Force | Out-Null
    $directory = if ($DirectoryOverride) { $DirectoryOverride } else { $Client }
    $receipt = [ordered]@{
        pack = (Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\client-pack\client-modpack.json') -Raw -Encoding UTF8 | ConvertFrom-Json).pack
        pack_version = 'test'
        minecraft_version = '1.20.1'
        forge_version = '47.4.10'
        minecraft_directory = $directory
        managed_files = @($Files)
    }
    $receipt | ConvertTo-Json -Depth 6 |
        Set-Content -LiteralPath (Join-Path $Client 'horror-apocalypse-install.json') -Encoding UTF8
}

try {
    New-Item -ItemType Directory -Path $scratch -Force | Out-Null

    $client = Join-Path $scratch 'normal-client'
    $mod = New-ManagedFile $client 'mods' 'owned.jar' 'owned mod' 'SHA512'
    $shader = New-ManagedFile $client 'shaderpacks' 'owned.zip' 'owned shader'
    $resource = New-ManagedFile $client 'resourcepacks' 'owned.zip' 'owned pack'
    $changed = New-ManagedFile $client 'mods' 'changed.jar' 'before'
    $old = New-ManagedFile (Join-Path $scratch 'old-template') 'mods' 'old.jar' 'historical asset'
    $package = Join-Path $scratch 'package'
    $historical = Join-Path $package 'historical'
    New-Item -ItemType Directory -Path $historical -Force | Out-Null
    $uninstaller = Join-Path $package 'Uninstall-HorrorClient.ps1'
    Copy-Item -LiteralPath $sourceUninstaller -Destination $uninstaller
    $packName = (Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\client-pack\client-modpack.json') -Raw -Encoding UTF8 | ConvertFrom-Json).pack
    [ordered]@{ pack = $packName; pack_version = 'test-current'; minecraft_version = '1.20.1';
        forge_version = '47.4.10'; java_major = 17; files = @($mod, $shader, $resource, $changed) } |
        ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $package 'client-modpack.json') -Encoding UTF8
    [ordered]@{ pack = $packName; pack_version = '2026.10.11.4'; minecraft_version = '1.20.1';
        forge_version = '47.4.10'; java_major = 17; files = @($old) } |
        ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $historical 'client-modpack-2026.10.11.4.json') -Encoding UTF8
    [IO.File]::WriteAllText((Join-Path $client 'mods\changed.jar'), 'player edited')
    [IO.File]::WriteAllText((Join-Path $client 'mods\unrelated.jar'), 'unrelated')
    New-Item -ItemType Directory -Path (Join-Path $client 'saves') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $client 'saves\world.txt'), 'my world')
    New-Item -ItemType Directory -Path (Join-Path $client 'config') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $client 'config\oculus.properties'), 'enableShaders=true')
    [IO.File]::WriteAllText((Join-Path $client 'options.txt'), 'resourcePacks:["vanilla","file/owned.zip","file/custom.zip"]')
    New-Item -ItemType Directory -Path (Join-Path $client 'runtime') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $client 'runtime\java.exe'), 'shared runtime')
    New-Item -ItemType Directory -Path (Join-Path $client 'versions') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $client 'versions\forge.json'), 'shared Forge')
    Write-Receipt $client @($mod, $shader, $resource, $changed)
    & $uninstaller -MinecraftDirectory $client | Out-Null
    foreach ($relative in @('mods\owned.jar', 'shaderpacks\owned.zip', 'resourcepacks\owned.zip')) {
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $client $relative))) "owned file remains: $relative"
    }
    foreach ($relative in @('mods\changed.jar', 'mods\unrelated.jar', 'saves\world.txt',
            'config\oculus.properties', 'options.txt', 'runtime\java.exe', 'versions\forge.json')) {
        Assert-True (Test-Path -LiteralPath (Join-Path $client $relative)) "unrelated or modified file removed: $relative"
    }
    Assert-True ((Get-Content -LiteralPath (Join-Path $client 'options.txt') -Raw) -eq
        'resourcePacks:["vanilla","file/owned.zip","file/custom.zip"]') 'options.txt changed'
    $receipt = Get-Content -LiteralPath (Join-Path $client 'horror-apocalypse-install.json') -Raw | ConvertFrom-Json
    Assert-True (@($receipt.managed_files).Count -eq 1) 'modified file was lost from receipt'
    Assert-True ($receipt.managed_files[0].filename -eq 'changed.jar') 'wrong retained receipt entry'
    & $uninstaller -MinecraftDirectory $client | Out-Null
    Assert-True (Test-Path -LiteralPath (Join-Path $client 'mods\changed.jar')) 'second run removed modified file'
    [IO.File]::WriteAllText((Join-Path $client 'mods\changed.jar'), 'before')
    & $uninstaller -MinecraftDirectory $client | Out-Null
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $client 'mods\changed.jar'))) 'restored original was not removed'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $client 'horror-apocalypse-install.json'))) 'receipt remains after complete removal'

    $whatIfClient = Join-Path $scratch 'whatif-client'
    $whatIfFile = New-ManagedFile $whatIfClient 'mods' 'owned.jar' 'owned mod' 'SHA512'
    Write-Receipt $whatIfClient @($whatIfFile)
    & $uninstaller -MinecraftDirectory $whatIfClient -WhatIf | Out-Null
    Assert-True (Test-Path -LiteralPath (Join-Path $whatIfClient 'mods\owned.jar')) 'WhatIf removed file'
    Assert-True (Test-Path -LiteralPath (Join-Path $whatIfClient 'horror-apocalypse-install.json')) 'WhatIf removed receipt'

    foreach ($case in @(
        @{ folder = 'saves'; filename = 'world.txt'; hash_algorithm = 'SHA256' },
        @{ folder = 'mods'; filename = '..\outside.jar'; hash_algorithm = 'SHA256' },
        @{ folder = 'mods'; filename = 'owned.jar'; hash_algorithm = 'MD5' },
        @{ folder = 'mods'; filename = 'owned.jar'; hash_algorithm = 'SHA256'; hash = 'not-a-hash' }
    )) {
        $badClient = Join-Path $scratch ([Guid]::NewGuid().ToString('N'))
        $good = New-ManagedFile $badClient 'mods' 'owned.jar' 'owned mod' 'SHA512'
        $bad = [ordered]@{ folder = $case.folder; filename = $case.filename;
            hash_algorithm = $case.hash_algorithm; hash = $good.hash }
        if ($case.ContainsKey('hash')) { $bad.hash = $case.hash }
        Write-Receipt $badClient @($good, $bad)
        $failed = $false
        try { & $uninstaller -MinecraftDirectory $badClient | Out-Null } catch { $failed = $true }
        Assert-True $failed "unsafe receipt accepted: $($case.folder)/$($case.filename)"
        Assert-True (Test-Path -LiteralPath (Join-Path $badClient 'mods\owned.jar')) 'file deleted before full receipt validation'
    }

    $forgedClient = Join-Path $scratch 'forged-client'
    $good = New-ManagedFile $forgedClient 'mods' 'owned.jar' 'owned mod' 'SHA512'
    $forged = New-ManagedFile $forgedClient 'mods' 'unrelated.jar' 'unrelated but valid hash'
    Write-Receipt $forgedClient @($good, $forged)
    $failed = $false
    try { & $uninstaller -MinecraftDirectory $forgedClient | Out-Null } catch { $failed = $true }
    Assert-True $failed 'forged receipt with valid unrelated hash accepted'
    Assert-True (Test-Path -LiteralPath (Join-Path $forgedClient 'mods\owned.jar')) 'owned file deleted before forged receipt rejected'
    Assert-True (Test-Path -LiteralPath (Join-Path $forgedClient 'mods\unrelated.jar')) 'unrelated file deleted by forged receipt'

    $historicalClient = Join-Path $scratch 'historical-client'
    $historicalEntry = New-ManagedFile $historicalClient 'mods' 'old.jar' 'historical asset'
    Write-Receipt $historicalClient @($historicalEntry)
    & $uninstaller -MinecraftDirectory $historicalClient | Out-Null
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $historicalClient 'mods\old.jar'))) 'historical pinned file not removed'

    $preexistingClient = Join-Path $scratch 'preexisting-client'
    $preexisting = New-ManagedFile $preexistingClient 'mods' 'owned.jar' 'owned mod' 'SHA512' $false
    Write-Receipt $preexistingClient @($preexisting)
    & $uninstaller -MinecraftDirectory $preexistingClient | Out-Null
    Assert-True (Test-Path -LiteralPath (Join-Path $preexistingClient 'mods\owned.jar')) 'pre-existing identical file removed'
    Assert-True (Test-Path -LiteralPath (Join-Path $preexistingClient 'horror-apocalypse-install.json')) 'pre-existing ownership record lost'

    $legacyClient = Join-Path $scratch 'legacy-client'
    $legacy = New-ManagedFile $legacyClient 'mods' 'owned.jar' 'owned mod' 'SHA512'
    $legacy.Remove('created_by_posle')
    Write-Receipt $legacyClient @($legacy)
    & $uninstaller -MinecraftDirectory $legacyClient | Out-Null
    Assert-True (Test-Path -LiteralPath (Join-Path $legacyClient 'mods\owned.jar')) 'legacy unknown-ownership file removed'

    $wrongClient = Join-Path $scratch 'wrong-root-client'
    $wrongFile = New-ManagedFile $wrongClient 'mods' 'owned.jar' 'owned mod' 'SHA512'
    Write-Receipt $wrongClient @($wrongFile) (Join-Path $scratch 'different-root')
    $failed = $false
    try { & $uninstaller -MinecraftDirectory $wrongClient | Out-Null } catch { $failed = $true }
    Assert-True $failed 'receipt for a different directory accepted'
    Assert-True (Test-Path -LiteralPath (Join-Path $wrongClient 'mods\owned.jar')) 'wrong-root file removed'

    $junctionClient = Join-Path $scratch 'junction-client'
    $outside = Join-Path $scratch 'outside'
    New-Item -ItemType Directory -Path $junctionClient, $outside -Force | Out-Null
    $outsideFile = Join-Path $outside 'owned.jar'
    [IO.File]::WriteAllText($outsideFile, 'owned mod')
    New-Item -ItemType Junction -Path (Join-Path $junctionClient 'mods') -Target $outside | Out-Null
    $junctionEntry = [ordered]@{ folder = 'mods'; filename = 'owned.jar'; hash_algorithm = 'SHA512';
        hash = (Get-FileHash -LiteralPath $outsideFile -Algorithm SHA512).Hash; created_by_posle = $true }
    Write-Receipt $junctionClient @($junctionEntry)
    $failed = $false
    try { & $uninstaller -MinecraftDirectory $junctionClient | Out-Null } catch { $failed = $true }
    Assert-True $failed 'junction escape accepted'
    Assert-True (Test-Path -LiteralPath $outsideFile) 'file outside instance removed'

    Write-Output 'Client uninstall tests passed.'
} finally {
    if (Test-Path -LiteralPath $scratch) {
        $resolved = [IO.Path]::GetFullPath($scratch)
        if (-not $resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or
            -not (Split-Path -Leaf $resolved).StartsWith('posle-uninstall-')) {
            throw 'Refusing to remove scratch outside the expected temp scope.'
        }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
