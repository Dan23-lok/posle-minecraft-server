$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.IO.Compression

$clientPack = Join-Path $PSScriptRoot '..\client-pack'
$packName = (Get-Content -LiteralPath (Join-Path $clientPack 'client-modpack.json') -Raw -Encoding UTF8 |
    ConvertFrom-Json).pack
$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$scratch = [IO.Path]::GetFullPath((Join-Path $tempRoot ('posle-forge-ready-' + [Guid]::NewGuid().ToString('N'))))
if (-not $scratch.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or
    -not (Split-Path -Leaf $scratch).StartsWith('posle-forge-ready-')) {
    throw 'Unsafe Forge test directory.'
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Write-Bytes {
    param([string]$Path, [byte[]]$Bytes)
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    [IO.File]::WriteAllBytes($Path, $Bytes)
}

function New-ForgeFixture {
    param([string]$ClientRoot, [switch]$CorruptWindowsLibrary, [switch]$MissingMacLibrary,
        [switch]$Inherited)
    $versionId = '1.20.1-forge-47.4.10'
    $versionFolder = Join-Path $ClientRoot "versions\$versionId"
    New-Item -ItemType Directory -Path $versionFolder -Force | Out-Null
    $baseJar = if ($Inherited) { Join-Path $ClientRoot 'versions\1.20.1\1.20.1.jar' }
        else { Join-Path $versionFolder "$versionId.jar" }
    Write-Bytes -Path $baseJar -Bytes ([Text.Encoding]::ASCII.GetBytes('vanilla client fixture'))
    $baseSha1 = (Get-FileHash -LiteralPath $baseJar -Algorithm SHA1).Hash.ToLowerInvariant()
    $libraryPath = 'net/minecraftforge/fmlloader/1.20.1-47.4.10/fmlloader-1.20.1-47.4.10.jar'
    $requiredLibrary = Join-Path (Join-Path $ClientRoot 'libraries') ($libraryPath.Replace('/', '\'))
    Write-Bytes -Path $requiredLibrary -Bytes ([Text.Encoding]::ASCII.GetBytes('Windows Forge library fixture'))
    $librarySha1 = (Get-FileHash -LiteralPath $requiredLibrary -Algorithm SHA1).Hash.ToLowerInvariant()
    $librarySize = (Get-Item -LiteralPath $requiredLibrary).Length
    if ($CorruptWindowsLibrary) {
        Write-Bytes -Path $requiredLibrary -Bytes ([Text.Encoding]::ASCII.GetBytes('corrupted library'))
    }
    $macPath = 'example/native-macos/1/native-macos-1.jar'
    $macLibrary = Join-Path (Join-Path $ClientRoot 'libraries') ($macPath.Replace('/', '\'))
    Write-Bytes -Path $macLibrary -Bytes ([Text.Encoding]::ASCII.GetBytes('macOS fixture'))
    $macSha1 = (Get-FileHash -LiteralPath $macLibrary -Algorithm SHA1).Hash.ToLowerInvariant()
    $macSize = (Get-Item -LiteralPath $macLibrary).Length
    if ($MissingMacLibrary) { Remove-Item -LiteralPath $macLibrary -Force }

    $profile = [ordered]@{
        id = $versionId
        mainClass = 'cpw.mods.bootstraplauncher.BootstrapLauncher'
    }
    if ($Inherited) {
        $profile.inheritsFrom = '1.20.1'
        $profile.arguments = [ordered]@{ game = @('--launchTarget', 'forgeclient',
            '--fml.forgeVersion', '47.4.10', '--fml.mcVersion', '1.20.1') }
    } else {
        $profile.javaVersion = [ordered]@{ majorVersion = 17 }
        $profile.downloads = [ordered]@{ client = [ordered]@{
            sha1 = $baseSha1; size = (Get-Item -LiteralPath $baseJar).Length
        } }
        $profile.arguments = [ordered]@{ game = @(
            [ordered]@{ values = @('--launchTarget', 'forgeclient') },
            [ordered]@{ values = @('--fml.forgeVersion', '47.4.10') },
            [ordered]@{ values = @('--fml.mcVersion', '1.20.1') }
        ) }
    }
    $profile.libraries = @(
        [ordered]@{ name = 'net.minecraftforge:fmlloader:1.20.1-47.4.10'
            artifact = [ordered]@{ path = $libraryPath; sha1 = $librarySha1; size = $librarySize } },
        [ordered]@{ name = 'example:native-macos:1'
            artifact = [ordered]@{ path = $macPath; sha1 = $macSha1; size = $macSize }
            rules = @([ordered]@{ action = 'allow'; os = [ordered]@{ name = 'osx' } }) }
    )
    if ($Inherited) {
        foreach ($library in $profile.libraries) {
            $library.downloads = [ordered]@{ artifact = $library.artifact }
            $library.Remove('artifact')
        }
    }
    $profile | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $versionFolder "$versionId.json") -Encoding UTF8
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
    Copy-Item -LiteralPath (Join-Path $clientPack 'Install-HorrorClient.ps1') -Destination $package
    # Replace only the Mojang JAR pin in this disposable fixture package.
    # Production continues to require the official 23,028,853-byte JAR.
    $fakeBase = [Text.Encoding]::ASCII.GetBytes('vanilla client fixture')
    $fakeSha1 = ([BitConverter]::ToString(([Security.Cryptography.SHA1]::Create()).ComputeHash($fakeBase))).Replace('-', '').ToLowerInvariant()
    $readiness = Get-Content -LiteralPath (Join-Path $clientPack 'Forge-ClientReadiness.ps1') -Raw -Encoding UTF8
    Assert-True ($readiness.Contains('0c3ec587af28e5a785c0b4a7b8a30f9a8f78f838') -and
        $readiness.Contains('23028853L')) 'Mojang fixture replacement anchors missing'
    $readiness = $readiness.Replace('0c3ec587af28e5a785c0b4a7b8a30f9a8f78f838', $fakeSha1)
    $readiness = $readiness.Replace('23028853L', "$($fakeBase.Length)L")
    [IO.File]::WriteAllText((Join-Path $package 'Forge-ClientReadiness.ps1'), $readiness,
        (New-Object Text.UTF8Encoding($false)))
    $fixtureBytes = [Text.Encoding]::ASCII.GetBytes('unchanged fixture mod')
    $fixtureSource = Join-Path $scratch 'fixture.jar'
    Write-Bytes -Path $fixtureSource -Bytes $fixtureBytes
    $fixtureSha = (Get-FileHash -LiteralPath $fixtureSource -Algorithm SHA256).Hash.ToLowerInvariant()
    $manifest = [ordered]@{
        pack = $packName; pack_version = 'forge-readiness-fixture'
        minecraft_version = '1.20.1'; forge_version = '47.4.10'; java_major = 17
        server_address = 'example.invalid'
        java_runtime = [ordered]@{ java_exe_sha256 = '1E1BE5FB92E33218323825B284C16377BDF10F7ED5CB4D30323F6B596EA45E5F' }
        files = @([ordered]@{ project = 'fixture'; folder = 'mods'; filename = 'fixture.jar'
            url = 'https://cdn.modrinth.com/fixture.jar'; hash_algorithm = 'SHA256'; hash = $fixtureSha })
    }
    $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $package 'client-modpack.json') -Encoding UTF8
    [ordered]@{ pack = $packName; pack_version = '2026.10.11.4'; files = @() } |
        ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $package 'historical\client-modpack-2026.10.11.4.json') -Encoding UTF8

    foreach ($case in @('valid', 'inherited', 'corrupt-windows', 'missing-macos',
            'tampered-base', 'inherited-tampered-base', 'wrong-java', 'unsafe-library')) {
        $client = Join-Path $scratch $case
        New-ForgeFixture -ClientRoot $client -CorruptWindowsLibrary:($case -eq 'corrupt-windows') `
            -MissingMacLibrary:($case -eq 'missing-macos') `
            -Inherited:($case -in @('inherited', 'inherited-tampered-base'))
        $profilePath = Join-Path $client 'versions\1.20.1-forge-47.4.10\1.20.1-forge-47.4.10.json'
        if ($case -in @('tampered-base', 'inherited-tampered-base')) {
            $baseJar = if ($case -eq 'inherited-tampered-base') {
                Join-Path $client 'versions\1.20.1\1.20.1.jar'
            } else { Join-Path $client 'versions\1.20.1-forge-47.4.10\1.20.1-forge-47.4.10.jar' }
            Write-Bytes -Path $baseJar -Bytes ([Text.Encoding]::ASCII.GetBytes('Xanilla client fixture'))
        }
        if ($case -in @('wrong-java', 'unsafe-library')) {
            $profile = Get-Content -LiteralPath $profilePath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($case -eq 'wrong-java') { $profile.javaVersion.majorVersion = 21 }
            else { $profile.libraries[0].artifact.path = '../outside.jar' }
            $profile | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $profilePath -Encoding UTF8
        }
        Write-Bytes -Path (Join-Path $client 'mods\fixture.jar') -Bytes $fixtureBytes
        if ($case -eq 'unsafe-library') {
            $failure = $null
            try { & (Join-Path $package 'Install-HorrorClient.ps1') -MinecraftDirectory $client -SkipForge | Out-Null }
            catch { $failure = $_.Exception.Message }
            Assert-True ($failure -match 'Unsafe Forge library path') 'unsafe Forge path was not rejected'
            Assert-True (-not (Test-Path -LiteralPath (Join-Path $client 'horror-apocalypse-install.json'))) `
                'unsafe Forge path wrote an installation receipt'
            continue
        }
        & (Join-Path $package 'Install-HorrorClient.ps1') -MinecraftDirectory $client -SkipForge | Out-Null
        $receipt = Get-Content -LiteralPath (Join-Path $client 'horror-apocalypse-install.json') -Raw -Encoding UTF8 |
            ConvertFrom-Json
        $expected = $case -notin @('corrupt-windows', 'tampered-base', 'inherited-tampered-base', 'wrong-java')
        Assert-True ($receipt.forge_installed -eq $expected) "$case Forge readiness was recorded incorrectly"
    }
    $receiptClient = Join-Path $scratch 'receipt-directory'
    New-ForgeFixture -ClientRoot $receiptClient
    Write-Bytes -Path (Join-Path $receiptClient 'mods\fixture.jar') -Bytes $fixtureBytes
    $receiptDirectory = Join-Path $receiptClient 'horror-apocalypse-install.json'
    New-Item -ItemType Directory -Path $receiptDirectory -Force | Out-Null
    $receiptError = $null
    try { & (Join-Path $package 'Install-HorrorClient.ps1') -MinecraftDirectory $receiptClient -SkipForge | Out-Null }
    catch { $receiptError = $_.Exception.Message }
    Assert-True ($receiptError -match 'receipt path is a directory') 'a directory at receipt path was accepted'
    Assert-True (@(Get-ChildItem -LiteralPath $receiptDirectory -Force).Count -eq 0) 'installer wrote a receipt into a directory'
    Write-Output 'Forge profile readiness tests passed.'
} finally {
    $resolved = [IO.Path]::GetFullPath($scratch)
    if (-not $resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or
        -not (Split-Path -Leaf $resolved).StartsWith('posle-forge-ready-')) {
        throw 'Refusing to clean outside Forge test scope.'
    }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
