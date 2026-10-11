$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.IO.Compression
$clientPack = Join-Path $PSScriptRoot '..\client-pack'
$actual = Get-Content -LiteralPath (Join-Path $clientPack 'client-modpack.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$scratch = [IO.Path]::GetFullPath((Join-Path $tempRoot ('posle-java-repair-' + [Guid]::NewGuid().ToString('N'))))
if (-not $scratch.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or
    -not (Split-Path -Leaf $scratch).StartsWith('posle-java-repair-')) { throw 'Unsafe fixture root.' }

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Write-Bytes {
    param([string]$Path, [byte[]]$Bytes)
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    [IO.File]::WriteAllBytes($Path, $Bytes)
}

function New-ReadyForgeProfile {
    param([string]$ClientRoot)
    $versionId = '1.20.1-forge-47.4.10'
    $versionFolder = Join-Path $ClientRoot "versions\$versionId"
    $clientJar = Join-Path $versionFolder "$versionId.jar"
    Write-Bytes -Path $clientJar -Bytes ([Text.Encoding]::ASCII.GetBytes('base Minecraft client'))
    $libraryRel = 'net/minecraftforge/fmlloader/1.20.1-47.4.10/fmlloader-1.20.1-47.4.10.jar'
    $library = Join-Path (Join-Path $ClientRoot 'libraries') ($libraryRel.Replace('/', '\'))
    Write-Bytes -Path $library -Bytes ([Text.Encoding]::ASCII.GetBytes('Forge loader fixture'))
    [ordered]@{
        id = $versionId; mainClass = 'cpw.mods.bootstraplauncher.BootstrapLauncher'
        javaVersion = [ordered]@{ majorVersion = 17 }
        downloads = [ordered]@{ client = [ordered]@{
            sha1 = (Get-FileHash -LiteralPath $clientJar -Algorithm SHA1).Hash
            size = (Get-Item -LiteralPath $clientJar).Length
        } }
        arguments = [ordered]@{ game = @(
            [ordered]@{ values = @('--launchTarget', 'forgeclient') },
            [ordered]@{ values = @('--fml.forgeVersion', '47.4.10') },
            [ordered]@{ values = @('--fml.mcVersion', '1.20.1') }
        ) }
        libraries = @([ordered]@{
            name = 'net.minecraftforge:fmlloader:1.20.1-47.4.10'
            artifact = [ordered]@{ path = $libraryRel
                sha1 = (Get-FileHash -LiteralPath $library -Algorithm SHA1).Hash
                size = (Get-Item -LiteralPath $library).Length }
        })
    } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $versionFolder "$versionId.json") -Encoding UTF8
    $forgeJar = Join-Path $ClientRoot 'libraries\net\minecraftforge\forge\1.20.1-47.4.10\forge-1.20.1-47.4.10-client.jar'
    New-Item -ItemType Directory -Path (Split-Path -Parent $forgeJar) -Force | Out-Null
    $zip = [IO.Compression.ZipFile]::Open($forgeJar, [IO.Compression.ZipArchiveMode]::Create)
    try {
        $entry = $zip.CreateEntry('fixture.class')
        $writer = New-Object IO.StreamWriter($entry.Open())
        try { $writer.Write('class fixture') } finally { $writer.Dispose() }
    } finally { $zip.Dispose() }
}

try {
    $package = Join-Path $scratch 'package'
    New-Item -ItemType Directory -Path (Join-Path $package 'historical') -Force | Out-Null
    $javaBytes = [Text.Encoding]::ASCII.GetBytes('official pinned Java fixture')
    $javaFile = Join-Path $scratch 'java-fixture.exe'
    Write-Bytes -Path $javaFile -Bytes $javaBytes
    $javaSha = (Get-FileHash -LiteralPath $javaFile -Algorithm SHA256).Hash
    $javaArchive = Join-Path $scratch 'corretto-fixture.zip'
    $zip = [IO.Compression.ZipFile]::Open($javaArchive, [IO.Compression.ZipArchiveMode]::Create)
    try {
        $entry = $zip.CreateEntry($actual.java_runtime.directory + '/bin/java.exe')
        $writer = $entry.Open()
        try { $writer.Write($javaBytes, 0, $javaBytes.Length) } finally { $writer.Dispose() }
    } finally { $zip.Dispose() }
    $javaArchiveSha = (Get-FileHash -LiteralPath $javaArchive -Algorithm SHA256).Hash
    $forgeFixture = Join-Path $scratch 'forge-installer-fixture.jar'
    Write-Bytes -Path $forgeFixture -Bytes ([Text.Encoding]::ASCII.GetBytes('Forge installer fixture'))
    $forgeSha = (Get-FileHash -LiteralPath $forgeFixture -Algorithm SHA256).Hash
    $modBytes = [Text.Encoding]::ASCII.GetBytes('mod fixture')
    $modFile = Join-Path $scratch 'mod.jar'
    Write-Bytes -Path $modFile -Bytes $modBytes
    $manifest = [ordered]@{
        pack = $actual.pack; pack_version = 'java-repair-fixture'
        minecraft_version = '1.20.1'; forge_version = '47.4.10'; java_major = 17
        server_address = 'example.invalid'
        java_runtime = [ordered]@{
            url = 'https://corretto.aws/fixture.zip'; sha256 = $javaArchiveSha
            directory = $actual.java_runtime.directory; java_exe_sha256 = $javaSha
        }
        forge_installer = [ordered]@{ url = 'https://maven.minecraftforge.net/fixture.jar'; sha256 = $forgeSha }
        files = @([ordered]@{ project = 'fixture'; folder = 'mods'; filename = 'mod.jar'
            url = 'https://cdn.modrinth.com/fixture.jar'; hash_algorithm = 'SHA256'
            hash = (Get-FileHash -LiteralPath $modFile -Algorithm SHA256).Hash })
    }
    $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $package 'client-modpack.json') -Encoding UTF8
    [ordered]@{ pack = $actual.pack; pack_version = '2026.10.11.4'; files = @() } |
        ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $package 'historical\client-modpack-2026.10.11.4.json') -Encoding UTF8

    $source = Get-Content -LiteralPath (Join-Path $clientPack 'Install-HorrorClient.ps1') -Raw -Encoding UTF8
    $source = $source.Replace('1E1BE5FB92E33218323825B284C16377BDF10F7ED5CB4D30323F6B596EA45E5F', $javaSha)
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$errors)
    Assert-True ($errors.Count -eq 0) 'installer parse failed'
    $downloadFunction = $ast.Find({ param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-VerifiedFile'
    }, $true)
    Assert-True ($null -ne $downloadFunction) 'Get-VerifiedFile missing'
    $stub = @'
function Get-VerifiedFile {
    param([string]$Url, [string]$Destination, [string]$Algorithm, [string]$Expected, [long]$MaxBytes)
    switch ([IO.Path]::GetFileName($Destination)) {
        'amazon-corretto-17-windows-x64-jdk.zip' { $source = $env:POSLE_JAVA_REPAIR_ARCHIVE }
        'forge-1.20.1-47.4.10-installer.jar' { $source = $env:POSLE_FORGE_REPAIR_FIXTURE }
        default { throw 'Unexpected fixture download.' }
    }
    Copy-Item -LiteralPath $source -Destination $Destination
    if (-not (Test-MatchingHash -Path $Destination -Algorithm $Algorithm -Expected $Expected)) {
        throw 'Fake Java archive failed hash verification.'
    }
}
'@
    $source = $source.Substring(0, $downloadFunction.Extent.StartOffset) + $stub +
        $source.Substring($downloadFunction.Extent.EndOffset)
    $installer = Join-Path $package 'Install-HorrorClient.ps1'
    [IO.File]::WriteAllText($installer, $source, (New-Object Text.UTF8Encoding($false)))
    $readiness = Get-Content -LiteralPath (Join-Path $clientPack 'Forge-ClientReadiness.ps1') -Raw -Encoding UTF8
    $fixtureBase = [Text.Encoding]::ASCII.GetBytes('base Minecraft client')
    $fixtureSha = ([BitConverter]::ToString(([Security.Cryptography.SHA1]::Create()).ComputeHash($fixtureBase))).Replace('-', '').ToLowerInvariant()
    Assert-True ($readiness.Contains('0c3ec587af28e5a785c0b4a7b8a30f9a8f78f838') -and
        $readiness.Contains('23028853L')) 'Mojang fixture replacement anchors missing'
    $readiness = $readiness.Replace('0c3ec587af28e5a785c0b4a7b8a30f9a8f78f838', $fixtureSha)
    $readiness = $readiness.Replace('23028853L', "$($fixtureBase.Length)L")
    [IO.File]::WriteAllText((Join-Path $package 'Forge-ClientReadiness.ps1'), $readiness,
        (New-Object Text.UTF8Encoding($false)))
    $env:POSLE_JAVA_REPAIR_ARCHIVE = $javaArchive
    $env:POSLE_FORGE_REPAIR_FIXTURE = $forgeFixture

    foreach ($case in @('missing', 'corrupt', 'already-good')) {
        $client = Join-Path $scratch $case
        New-ReadyForgeProfile -ClientRoot $client
        Write-Bytes -Path (Join-Path $client 'mods\mod.jar') -Bytes $modBytes
        $target = Join-Path (Join-Path (Join-Path $client 'runtime') $actual.java_runtime.directory) 'bin\java.exe'
        if ($case -eq 'corrupt') { Write-Bytes -Path $target -Bytes ([Text.Encoding]::ASCII.GetBytes('tampered Java')) }
        if ($case -eq 'already-good') { Write-Bytes -Path $target -Bytes $javaBytes }
        & $installer -MinecraftDirectory $client | Out-Null
        Assert-True (Test-Path -LiteralPath $target -PathType Leaf) "$case Java was not installed"
        Assert-True ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -eq $javaSha) "$case Java was not repaired"
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $client 'forge-client-install.log'))) "$case needlessly reinstalled Forge"
    }
    $junctionClient = Join-Path $scratch 'forge-junction'
    New-Item -ItemType Directory -Path $junctionClient -Force | Out-Null
    Write-Bytes -Path (Join-Path $junctionClient 'mods\mod.jar') -Bytes $modBytes
    $javaTarget = Join-Path (Join-Path (Join-Path $junctionClient 'runtime') $actual.java_runtime.directory) 'bin\java.exe'
    Write-Bytes -Path $javaTarget -Bytes $javaBytes
    $outside = Join-Path $scratch 'outside-assets'
    New-Item -ItemType Directory -Path $outside -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $outside 'marker.txt'), 'preserve')
    New-Item -ItemType Junction -Path (Join-Path $junctionClient 'assets') -Target $outside | Out-Null
    $junctionError = $null
    try { & $installer -MinecraftDirectory $junctionClient | Out-Null }
    catch { $junctionError = $_.Exception.Message }
    Assert-True ($junctionError -match 'Refusing to use a symlink or junction') 'Forge installer accepted assets junction'
    Assert-True (([IO.File]::ReadAllText((Join-Path $outside 'marker.txt'))) -eq 'preserve') 'Forge junction changed foreign assets'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $junctionClient 'forge-client-install.log'))) 'Forge process started before junction rejection'
    Write-Output 'Portable Java repair tests passed.'
} finally {
    Remove-Item Env:POSLE_JAVA_REPAIR_ARCHIVE -ErrorAction SilentlyContinue
    Remove-Item Env:POSLE_FORGE_REPAIR_FIXTURE -ErrorAction SilentlyContinue
    $resolved = [IO.Path]::GetFullPath($scratch)
    if (-not $resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or
        -not (Split-Path -Leaf $resolved).StartsWith('posle-java-repair-')) {
        throw 'Refusing to clean outside Java repair fixture.'
    }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
