$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$repoClient = Join-Path $PSScriptRoot '..\client-pack'
$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$scratch = [IO.Path]::GetFullPath((Join-Path $tempRoot ('posle-preflight-' + [Guid]::NewGuid().ToString('N'))))
if (-not $scratch.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Scratch directory is outside system temp.'
}

function Assert-True {
    param([bool]$Condition, [string]$Case)
    if (-not $Condition) { throw $Case }
}

function New-FakeModJar {
    param([string]$Path, [string]$ModId, [switch]$SingleQuoted)
    $zip = [IO.Compression.ZipFile]::Open($Path, [IO.Compression.ZipArchiveMode]::Create)
    try {
        $entry = $zip.CreateEntry('META-INF/mods.toml')
        $writer = New-Object IO.StreamWriter($entry.Open())
        $quote = if ($SingleQuoted) { "'" } else { '"' }
        try { $writer.Write(("[[mods]]`nmodId={0}{1}{0}`nversion=`"1.0`"`n" -f $quote, $ModId)) }
        finally { $writer.Dispose() }
    } finally { $zip.Dispose() }
}

function New-FileEntry {
    param([string]$Source, [string]$Project, [string]$Folder)
    return [ordered]@{
        project = $Project
        version = 'fixture'
        filename = [IO.Path]::GetFileName($Source)
        url = 'https://cdn.modrinth.com/fixture/' + [IO.Path]::GetFileName($Source)
        hash_algorithm = 'SHA256'
        hash = (Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash
        folder = $Folder
    }
}

function New-CasePackage {
    param([string]$Name, [object[]]$Files, [object[]]$HistoricalFiles)
    $package = Join-Path $scratch ($Name + '-package')
    New-Item -ItemType Directory -Path (Join-Path $package 'historical') -Force | Out-Null
    Copy-Item -LiteralPath $installerFixture -Destination (Join-Path $package 'Install-HorrorClient.ps1')
    Copy-Item -LiteralPath (Join-Path $repoClient 'Forge-ClientReadiness.ps1') -Destination $package
    [ordered]@{ pack=$packName; pack_version='fixture-v6'; minecraft_version='1.20.1';
        forge_version='47.4.10'; java_major=17; server_address='example.invalid';
        java_runtime=[ordered]@{ java_exe_sha256='1E1BE5FB92E33218323825B284C16377BDF10F7ED5CB4D30323F6B596EA45E5F' };
        files=@($Files) } |
        ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $package 'client-modpack.json') -Encoding UTF8
    [ordered]@{ pack=$packName; pack_version='2026.10.11.4'; minecraft_version='1.20.1';
        forge_version='47.4.10'; java_major=17; files=@($HistoricalFiles) } |
        ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $package 'historical\client-modpack-2026.10.11.4.json') -Encoding UTF8
    return $package
}

function Assert-FailedInstall {
    param([string]$Installer, [string]$Client, [string]$Case)
    $failed = $false
    try { & $Installer -MinecraftDirectory $Client -SkipForge | Out-Null }
    catch { $failed = $true }
    Assert-True $failed $Case
}

try {
    New-Item -ItemType Directory -Path $scratch -Force | Out-Null
    $fixtures = Join-Path $scratch 'fixtures'
    New-Item -ItemType Directory -Path $fixtures -Force | Out-Null
    $source = Get-Content -LiteralPath (Join-Path $repoClient 'Install-HorrorClient.ps1') -Raw -Encoding UTF8
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$errors)
    Assert-True ($errors.Count -eq 0) 'installer parse error'
    $function = $ast.Find({ param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-VerifiedFile'
    }, $true)
    Assert-True ($null -ne $function) 'Get-VerifiedFile not found'
    $stub = @'
function Get-VerifiedFile {
    param([string]$Url, [string]$Destination, [string]$Algorithm, [string]$Expected)
    if ($env:POSLE_FAIL_DOWNLOAD -eq [IO.Path]::GetFileName($Destination)) {
        throw 'Fixture download failed.'
    }
    if (Test-Path -LiteralPath $Destination -PathType Leaf) {
        if (-not (Test-MatchingHash -Path $Destination -Algorithm $Algorithm -Expected $Expected)) {
            throw 'Fixture existing file has wrong hash.'
        }
        return
    }
    New-Item -ItemType Directory -Path (Split-Path -Parent $Destination) -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $env:POSLE_FIXTURE_DIR ([IO.Path]::GetFileName($Destination))) -Destination $Destination
    if (-not (Test-MatchingHash -Path $Destination -Algorithm $Algorithm -Expected $Expected)) {
        throw 'Fixture file hash mismatch.'
    }
}
'@
    $copiedSource = $source.Substring(0, $function.Extent.StartOffset) + $stub +
        $source.Substring($function.Extent.EndOffset)
    $installerFixture = Join-Path $scratch 'Install-HorrorClient.ps1'
    [IO.File]::WriteAllText($installerFixture, $copiedSource, (New-Object Text.UTF8Encoding($false)))

    $packName = (Get-Content -LiteralPath (Join-Path $repoClient 'client-modpack.json') -Raw -Encoding UTF8 |
        ConvertFrom-Json).pack
    $modIds = [ordered]@{ pehkui='pehkui.jar'; 'mutant-monsters'='mutantmonsters.jar'; 'puzzles-lib'='puzzleslib.jar' }
    $entries = @()
    foreach ($id in $modIds.Keys) {
        $path = Join-Path $fixtures $modIds[$id]
        $actualId = switch ($id) { 'mutant-monsters' { 'mutantmonsters' } 'puzzles-lib' { 'puzzleslib' } default { $id } }
        New-FakeModJar -Path $path -ModId $actualId
        $entries += New-FileEntry -Source $path -Project $id -Folder 'mods'
    }
    $late = Join-Path $fixtures 'late-shader.zip'
    [IO.File]::WriteAllText($late, 'shader fixture')
    $entries += New-FileEntry -Source $late -Project 'late-shader' -Folder 'shaderpacks'
    $env:POSLE_FIXTURE_DIR = $fixtures

    # All new files must be verified before touching the client directory.
    $package = New-CasePackage -Name 'late-download' -Files $entries -HistoricalFiles @()
    $client = Join-Path $scratch 'late-download-client'
    $env:POSLE_FAIL_DOWNLOAD = 'late-shader.zip'
    Assert-FailedInstall -Installer (Join-Path $package 'Install-HorrorClient.ps1') -Client $client -Case 'late download failure accepted'
    Assert-True (-not (Test-Path -LiteralPath $client)) 'late download changed client before preflight completed'
    Remove-Item Env:POSLE_FAIL_DOWNLOAD

    # A partially specified creature pack must fail before any installation.
    $partial = @($entries | Where-Object { $_.project -ne 'pehkui' })
    $package = New-CasePackage -Name 'missing-dependency' -Files $partial -HistoricalFiles @()
    $client = Join-Path $scratch 'missing-dependency-client'
    Assert-FailedInstall -Installer (Join-Path $package 'Install-HorrorClient.ps1') -Client $client -Case 'missing Pehkui accepted'
    Assert-True (-not (Test-Path -LiteralPath $client)) 'missing dependency modified client'

    # Pehkui can roll out alone; Mutant Monsters requires both Pehkui and Puzzles Lib.
    $pehkuiOnly = @($entries | Where-Object { $_.project -in @('pehkui', 'late-shader') })
    $package = New-CasePackage -Name 'pehkui-only' -Files $pehkuiOnly -HistoricalFiles @()
    $client = Join-Path $scratch 'pehkui-only-client'
    & (Join-Path $package 'Install-HorrorClient.ps1') -MinecraftDirectory $client -SkipForge | Out-Null
    $soloReceipt = Get-Content -LiteralPath (Join-Path $client 'horror-apocalypse-install.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True (@($soloReceipt.managed_files).Count -eq 2) 'Pehkui-only receipt has wrong file count'
    Assert-True (Test-Path -LiteralPath (Join-Path $client 'mods\pehkui.jar') -PathType Leaf) 'Pehkui-only install missing mod'

    $missingPuzzles = @($entries | Where-Object { $_.project -ne 'puzzles-lib' })
    $package = New-CasePackage -Name 'missing-puzzles' -Files $missingPuzzles -HistoricalFiles @()
    $client = Join-Path $scratch 'missing-puzzles-client'
    Assert-FailedInstall -Installer (Join-Path $package 'Install-HorrorClient.ps1') -Client $client -Case 'Mutant without Puzzles Lib accepted'
    Assert-True (-not (Test-Path -LiteralPath $client)) 'missing Puzzles Lib modified client'

    # The Pehkui-only path must still reject a foreign JAR claiming pehkui.
    $package = New-CasePackage -Name 'pehkui-duplicate' -Files $pehkuiOnly -HistoricalFiles @()
    $client = Join-Path $scratch 'pehkui-duplicate-client'
    New-Item -ItemType Directory -Path (Join-Path $client 'mods') -Force | Out-Null
    $foreignPehkui = Join-Path $client 'mods\foreign-pehkui.jar'
    New-FakeModJar -Path $foreignPehkui -ModId 'pehkui' -SingleQuoted
    $foreignPehkuiHash = (Get-FileHash -LiteralPath $foreignPehkui -Algorithm SHA256).Hash
    Assert-FailedInstall -Installer (Join-Path $package 'Install-HorrorClient.ps1') -Client $client -Case 'Pehkui-only duplicate modId accepted'
    Assert-True ((Get-FileHash -LiteralPath $foreignPehkui -Algorithm SHA256).Hash -eq $foreignPehkuiHash) 'Pehkui foreign JAR changed'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $client 'mods\pehkui.jar'))) 'Pehkui installed alongside duplicate'

    # A verified pre-existing mod can change while the installer is updating
    # settings. Do not record a successful receipt for its stale hash.
    $package = New-CasePackage -Name 'existing-file-race' -Files $pehkuiOnly -HistoricalFiles @()
    $raceInstaller = Join-Path $package 'Install-HorrorClient.ps1'
    $raceSource = Get-Content -LiteralPath $raceInstaller -Raw -Encoding UTF8
    $tokens = $null; $errors = $null
    $raceAst = [Management.Automation.Language.Parser]::ParseInput($raceSource, [ref]$tokens, [ref]$errors)
    Assert-True ($errors.Count -eq 0) 'race fixture installer parse error'
    $updateFunction = $raceAst.Find({ param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Update-KeyValueFile'
    }, $true)
    Assert-True ($null -ne $updateFunction) 'race fixture update function not found'
    $fault = @'
function Update-KeyValueFile {
    param([string]$Path, [string]$Separator, [object]$Values)
    [IO.File]::WriteAllText((Join-Path $MinecraftDirectory 'mods\pehkui.jar'), 'changed by another process')
}
'@
    $raceSource = $raceSource.Substring(0, $updateFunction.Extent.StartOffset) + $fault +
        $raceSource.Substring($updateFunction.Extent.EndOffset)
    [IO.File]::WriteAllText($raceInstaller, $raceSource, (New-Object Text.UTF8Encoding($false)))
    $client = Join-Path $scratch 'existing-file-race-client'
    New-Item -ItemType Directory -Path (Join-Path $client 'mods') -Force | Out-Null
    $existingPehkui = Join-Path $client 'mods\pehkui.jar'
    Copy-Item -LiteralPath (Join-Path $fixtures 'pehkui.jar') -Destination $existingPehkui
    Assert-FailedInstall -Installer $raceInstaller -Client $client -Case 'changed pre-existing mod accepted in receipt'
    Assert-True ((Get-FileHash -LiteralPath $existingPehkui -Algorithm SHA256).Hash -ne $pehkuiOnly[0].hash) 'race fixture did not change old mod'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $client 'shaderpacks\late-shader.zip'))) 'failed update kept new shader'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $client 'horror-apocalypse-install.json'))) 'failed update wrote receipt'

    # A correctly named and hashed archive with the wrong Forge mod ID is not a valid dependency.
    $badFixtures = Join-Path $scratch 'bad-fixtures'
    New-Item -ItemType Directory -Path $badFixtures -Force | Out-Null
    Get-ChildItem -LiteralPath $fixtures -File | Copy-Item -Destination $badFixtures
    $badPehkui = Join-Path $badFixtures 'pehkui.jar'
    Remove-Item -LiteralPath $badPehkui -Force
    New-FakeModJar -Path $badPehkui -ModId 'wrongmod'
    $badEntries = @()
    foreach ($id in $modIds.Keys) {
        $badEntries += New-FileEntry -Source (Join-Path $badFixtures $modIds[$id]) -Project $id -Folder 'mods'
    }
    $badEntries += New-FileEntry -Source (Join-Path $badFixtures 'late-shader.zip') -Project 'late-shader' -Folder 'shaderpacks'
    $env:POSLE_FIXTURE_DIR = $badFixtures
    $package = New-CasePackage -Name 'wrong-mod-id' -Files $badEntries -HistoricalFiles @()
    $client = Join-Path $scratch 'wrong-mod-id-client'
    Assert-FailedInstall -Installer (Join-Path $package 'Install-HorrorClient.ps1') -Client $client -Case 'wrong Pehkui modId accepted'
    Assert-True (-not (Test-Path -LiteralPath $client)) 'wrong modId modified client'
    $env:POSLE_FIXTURE_DIR = $fixtures

    # A foreign JAR with one of the required mod IDs must be preserved and block update.
    $package = New-CasePackage -Name 'duplicate-mod' -Files $entries -HistoricalFiles @()
    $client = Join-Path $scratch 'duplicate-mod-client'
    New-Item -ItemType Directory -Path (Join-Path $client 'mods'), (Join-Path $client 'saves') -Force | Out-Null
    $foreign = Join-Path $client 'mods\foreign-mutant.jar'
    New-FakeModJar -Path $foreign -ModId 'mutantmonsters' -SingleQuoted
    $foreignHash = (Get-FileHash -LiteralPath $foreign -Algorithm SHA256).Hash
    [IO.File]::WriteAllText((Join-Path $client 'saves\world.txt'), 'preserve me')
    Assert-FailedInstall -Installer (Join-Path $package 'Install-HorrorClient.ps1') -Client $client -Case 'duplicate modId accepted'
    Assert-True ((Get-FileHash -LiteralPath $foreign -Algorithm SHA256).Hash -eq $foreignHash) 'foreign JAR changed'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $client 'mods\pehkui.jar'))) 'duplicate case installed new files'
    Assert-True (Test-Path -LiteralPath (Join-Path $client 'saves\world.txt')) 'save removed during conflict'

    # Valid set installs all four files and records ownership without touching saves.
    $package = New-CasePackage -Name 'successful-install' -Files $entries -HistoricalFiles @()
    $client = Join-Path $scratch 'successful-install-client'
    New-Item -ItemType Directory -Path (Join-Path $client 'saves') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $client 'saves\world.txt'), 'preserve me')
    & (Join-Path $package 'Install-HorrorClient.ps1') -MinecraftDirectory $client -SkipForge | Out-Null
    foreach ($entry in $entries) {
        $installed = Join-Path (Join-Path $client $entry.folder) $entry.filename
        Assert-True ((Get-FileHash -LiteralPath $installed -Algorithm SHA256).Hash -eq $entry.hash) "installed wrong file: $($entry.filename)"
    }
    $newReceipt = Get-Content -LiteralPath (Join-Path $client 'horror-apocalypse-install.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True (@($newReceipt.managed_files).Count -eq 4) 'successful install recorded wrong file count'
    Assert-True (@($newReceipt.managed_files | Where-Object { $_.created_by_posle -eq $true }).Count -eq 4) 'successful install lost ownership'
    Assert-True (Test-Path -LiteralPath (Join-Path $client 'saves\world.txt')) 'successful install removed save'

    # Fail after adding new files and removing an obsolete owned file: restore both.
    $oldSource = Join-Path $fixtures 'old.jar'
    New-FakeModJar -Path $oldSource -ModId 'oldmod'
    $oldEntry = New-FileEntry -Source $oldSource -Project 'oldmod' -Folder 'mods'
    $package = New-CasePackage -Name 'rollback' -Files $entries -HistoricalFiles @($oldEntry)
    $client = Join-Path $scratch 'rollback-client'
    New-Item -ItemType Directory -Path (Join-Path $client 'mods'), (Join-Path $client 'saves'),
        (Join-Path $client 'options.txt') -Force | Out-Null
    $oldPath = Join-Path $client 'mods\old.jar'
    Copy-Item -LiteralPath $oldSource -Destination $oldPath
    [IO.File]::WriteAllText((Join-Path $client 'saves\world.txt'), 'preserve me')
    $receipt = [ordered]@{ pack=$packName; pack_version='2026.10.11.4'; minecraft_version='1.20.1';
        forge_version='47.4.10'; minecraft_directory=$client; managed_files=@([ordered]@{
            folder='mods'; filename='old.jar'; hash_algorithm='SHA256'; hash=$oldEntry.hash;
            created_by_posle=$true
        }) }
    $receiptPath = Join-Path $client 'horror-apocalypse-install.json'
    $receipt | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $receiptPath -Encoding UTF8
    $receiptBefore = [IO.File]::ReadAllBytes($receiptPath)
    Assert-FailedInstall -Installer (Join-Path $package 'Install-HorrorClient.ps1') -Client $client -Case 'commit failure did not fail'
    Assert-True (Test-Path -LiteralPath $oldPath) 'rollback lost obsolete owned mod'
    Assert-True ((Get-FileHash -LiteralPath $oldPath -Algorithm SHA256).Hash -eq $oldEntry.hash) 'rollback restored wrong old mod'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $client 'mods\pehkui.jar'))) 'rollback retained new mod'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $client 'mods\puzzleslib.jar'))) 'rollback retained new dependency'
    Assert-True ([Linq.Enumerable]::SequenceEqual([byte[]]$receiptBefore, [byte[]][IO.File]::ReadAllBytes($receiptPath))) 'rollback changed old receipt'
    Assert-True (Test-Path -LiteralPath (Join-Path $client 'saves\world.txt')) 'rollback removed save'

    # If rollback itself cannot restore an old file, retain verified external backups.
    $package = New-CasePackage -Name 'rollback-forensic' -Files $entries -HistoricalFiles @($oldEntry)
    $forensicInstaller = Join-Path $package 'Install-HorrorClient.ps1'
    $forensicSource = Get-Content -LiteralPath $forensicInstaller -Raw -Encoding UTF8
    $tokens = $null; $errors = $null
    $forensicAst = [Management.Automation.Language.Parser]::ParseInput($forensicSource, [ref]$tokens, [ref]$errors)
    Assert-True ($errors.Count -eq 0) 'forensic fixture installer parse error'
    $updateFunction = $forensicAst.Find({ param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Update-KeyValueFile'
    }, $true)
    Assert-True ($null -ne $updateFunction) 'Update-KeyValueFile not found'
    $fault = @'
function Update-KeyValueFile {
    param([string]$Path, [string]$Separator, [object]$Values)
    New-Item -ItemType Directory -Path (Join-Path $MinecraftDirectory 'mods\old.jar') -Force | Out-Null
    throw 'Fixture fault after obsolete mod removal.'
}
'@
    $forensicSource = $forensicSource.Substring(0, $updateFunction.Extent.StartOffset) + $fault +
        $forensicSource.Substring($updateFunction.Extent.EndOffset)
    [IO.File]::WriteAllText($forensicInstaller, $forensicSource, (New-Object Text.UTF8Encoding($false)))
    $client = Join-Path $scratch 'rollback-forensic-client'
    New-Item -ItemType Directory -Path (Join-Path $client 'mods'), (Join-Path $client 'saves') -Force | Out-Null
    $oldPath = Join-Path $client 'mods\old.jar'
    Copy-Item -LiteralPath $oldSource -Destination $oldPath
    [IO.File]::WriteAllText((Join-Path $client 'saves\world.txt'), 'preserve me')
    $receipt.minecraft_directory = $client
    $receipt | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $client 'horror-apocalypse-install.json') -Encoding UTF8
    $errorMessage = $null
    try { & $forensicInstaller -MinecraftDirectory $client -SkipForge | Out-Null }
    catch { $errorMessage = $_.Exception.Message }
    Assert-True ([bool]$errorMessage) 'rollback forensic fault was not triggered'
    Assert-True ($errorMessage -match 'Rollback needs manual repair:') 'rollback failure was not reported'
    $backupMatch = [regex]::Match($errorMessage, 'Backups: (?<path>.+)$')
    Assert-True $backupMatch.Success 'rollback failure did not report backup path'
    $forensicStage = [IO.Path]::GetFullPath($backupMatch.Groups['path'].Value.Trim())
    Assert-True ($forensicStage.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $forensicStage).StartsWith('posle-client-stage-')) 'rollback reported unsafe backup path'
    $retiredBackup = Join-Path $forensicStage 'obsolete\mods\old.jar'
    Assert-True (Test-Path -LiteralPath $retiredBackup -PathType Leaf) 'rollback failure deleted forensic backup'
    Assert-True ((Get-FileHash -LiteralPath $retiredBackup -Algorithm SHA256).Hash -eq $oldEntry.hash) 'forensic backup hash mismatch'
    Assert-True (Test-Path -LiteralPath (Join-Path $client 'saves\world.txt')) 'forensic fault removed save'
    Remove-Item -LiteralPath $forensicStage -Recurse -Force

    Write-Output 'Client preflight and rollback tests passed (fixture downloads only).'
} finally {
    Remove-Item Env:POSLE_FAIL_DOWNLOAD -ErrorAction SilentlyContinue
    Remove-Item Env:POSLE_FIXTURE_DIR -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $scratch) {
        $resolved = [IO.Path]::GetFullPath($scratch)
        if (-not $resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or
            -not (Split-Path -Leaf $resolved).StartsWith('posle-preflight-')) {
            throw 'Refusing to remove scratch outside expected temp scope.'
        }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
