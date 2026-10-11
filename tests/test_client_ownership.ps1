$ErrorActionPreference = 'Stop'
$repoClient = Join-Path $PSScriptRoot '..\client-pack'
$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$scratch = [IO.Path]::GetFullPath((Join-Path $tempRoot ('posle-ownership-' + [Guid]::NewGuid().ToString('N'))))
if (-not $scratch.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Scratch directory is outside the system temp directory.'
}
function Assert-True {
    param([bool]$Condition, [string]$Case)
    if (-not $Condition) { throw $Case }
}
try {
    $package = Join-Path $scratch 'package'
    $client = Join-Path $scratch 'client'
    New-Item -ItemType Directory -Path (Join-Path $package 'historical'), (Join-Path $client 'mods') -Force | Out-Null
    $sourceInstaller = Join-Path $repoClient 'Install-HorrorClient.ps1'
    $source = Get-Content -LiteralPath $sourceInstaller -Raw -Encoding UTF8
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$errors)
    if ($errors.Count -ne 0) { throw 'Installer source has syntax errors.' }
    $downloadFunction = $ast.Find({ param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Get-VerifiedFile'
    }, $true)
    if (-not $downloadFunction) { throw 'Installer downloader function not found.' }
    # Replace only the download function in a disposable copy. The production
    # installer still uses official URLs and hash verification.
    $stub = @'
function Get-VerifiedFile {
    param([string]$Url, [string]$Destination, [string]$Algorithm, [string]$Expected)
    if (Test-Path -LiteralPath $Destination -PathType Leaf) {
        if (-not (Test-MatchingHash -Path $Destination -Algorithm $Algorithm -Expected $Expected)) {
            throw "Fixture file has a different hash: $Destination"
        }
        return
    }
    New-Item -ItemType Directory -Path (Split-Path -Parent $Destination) -Force | Out-Null
    [IO.File]::WriteAllText($Destination, 'created asset')
    if (-not (Test-MatchingHash -Path $Destination -Algorithm $Algorithm -Expected $Expected)) {
        throw 'Fixture download hash mismatch.'
    }
}
'@
    $offset = $downloadFunction.Extent.StartOffset
    $end = $downloadFunction.Extent.EndOffset
    $copiedSource = $source.Substring(0, $offset) + $stub + $source.Substring($end)
    $installer = Join-Path $package 'Install-HorrorClient.ps1'
    [IO.File]::WriteAllText($installer, $copiedSource, (New-Object Text.UTF8Encoding($false)))
    Copy-Item -LiteralPath (Join-Path $repoClient 'Uninstall-HorrorClient.ps1') -Destination $package

    $preexistingPath = Join-Path $client 'mods\preexisting.jar'
    [IO.File]::WriteAllText($preexistingPath, 'preexisting asset')
    $createdPath = Join-Path $client 'mods\created.jar'
    [IO.File]::WriteAllText($createdPath, 'created asset')
    $preexistingHash = (Get-FileHash -LiteralPath $preexistingPath -Algorithm SHA256).Hash
    $createdHash = (Get-FileHash -LiteralPath $createdPath -Algorithm SHA256).Hash
    Remove-Item -LiteralPath $createdPath -Force
    $realManifest = Get-Content -LiteralPath (Join-Path $repoClient 'client-modpack.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $files = @(
        [ordered]@{ folder='mods'; filename='preexisting.jar'; url='https://cdn.modrinth.com/fixture/preexisting.jar'; hash_algorithm='SHA256'; hash=$preexistingHash },
        [ordered]@{ folder='mods'; filename='created.jar'; url='https://cdn.modrinth.com/fixture/created.jar'; hash_algorithm='SHA256'; hash=$createdHash }
    )
    $fixtureManifest = [ordered]@{ pack=$realManifest.pack; pack_version='test-ownership';
        minecraft_version='1.20.1'; forge_version='47.4.10'; java_major=17;
        java_runtime=$realManifest.java_runtime;
        server_address='example.invalid'; files=$files }
    $fixtureManifest | ConvertTo-Json -Depth 6 |
        Set-Content -LiteralPath (Join-Path $package 'client-modpack.json') -Encoding UTF8
    ([ordered]@{ pack=$realManifest.pack; pack_version='2026.10.11.4';
        minecraft_version='1.20.1'; forge_version='47.4.10'; files=@() }) |
        ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $package 'historical\client-modpack-2026.10.11.4.json') -Encoding UTF8

    & $installer -MinecraftDirectory $client -SkipForge | Out-Null
    $receiptPath = Join-Path $client 'horror-apocalypse-install.json'
    $receipt = Get-Content -LiteralPath $receiptPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $preexisting = @($receipt.managed_files | Where-Object filename -eq 'preexisting.jar')[0]
    $created = @($receipt.managed_files | Where-Object filename -eq 'created.jar')[0]
    Assert-True ($preexisting.created_by_posle -is [bool] -and -not $preexisting.created_by_posle) 'installer claimed identical pre-existing file'
    Assert-True ($created.created_by_posle -is [bool] -and $created.created_by_posle) 'installer did not claim newly created file'

    & $installer -MinecraftDirectory $client -SkipForge | Out-Null
    $receipt = Get-Content -LiteralPath $receiptPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True (@($receipt.managed_files | Where-Object filename -eq 'created.jar')[0].created_by_posle -eq $true) 'rerun lost created ownership'
    Assert-True (@($receipt.managed_files | Where-Object filename -eq 'preexisting.jar')[0].created_by_posle -eq $false) 'rerun claimed pre-existing ownership'

    & (Join-Path $package 'Uninstall-HorrorClient.ps1') -MinecraftDirectory $client | Out-Null
    Assert-True (-not (Test-Path -LiteralPath $createdPath)) 'uninstaller left owned file'
    Assert-True (Test-Path -LiteralPath $preexistingPath) 'uninstaller removed identical pre-existing file'
    $receipt = Get-Content -LiteralPath $receiptPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True (@($receipt.managed_files).Count -eq 1) 'retained receipt should contain only pre-existing file'
    Assert-True ($receipt.managed_files[0].created_by_posle -eq $false) 'retained receipt changed ownership'

    # Simulate the already-published v5 receipt, which has no ownership field.
    $legacyClient = Join-Path $scratch 'legacy-client'
    New-Item -ItemType Directory -Path (Join-Path $legacyClient 'mods') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $legacyClient 'mods\preexisting.jar'), 'preexisting asset')
    $legacyReceipt = [ordered]@{ pack=$realManifest.pack; pack_version='2026.10.11.5';
        minecraft_version='1.20.1'; forge_version='47.4.10'; minecraft_directory=$legacyClient;
        managed_files=@($files[0]) }
    # The owner's published v5 receipt is UTF-8 without a BOM. Windows PowerShell
    # 5.1 defaults to the local code page unless the installer opts into UTF-8.
    [IO.File]::WriteAllText((Join-Path $legacyClient 'horror-apocalypse-install.json'),
        ($legacyReceipt | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))
    & $installer -MinecraftDirectory $legacyClient -SkipForge | Out-Null
    $legacyAfter = Get-Content -LiteralPath (Join-Path $legacyClient 'horror-apocalypse-install.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True (@($legacyAfter.managed_files | Where-Object filename -eq 'preexisting.jar')[0].created_by_posle -eq $false) 'legacy unknown ownership was promoted to owned'
    Assert-True (@($legacyAfter.managed_files | Where-Object filename -eq 'created.jar')[0].created_by_posle -eq $true) 'new file after legacy receipt not owned'
    Write-Output 'Client ownership integration tests passed (fixture downloader only).'
} finally {
    if (Test-Path -LiteralPath $scratch) {
        $resolved = [IO.Path]::GetFullPath($scratch)
        if (-not $resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or
            -not (Split-Path -Leaf $resolved).StartsWith('posle-ownership-')) {
            throw 'Refusing to remove scratch outside the expected temp scope.'
        }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
