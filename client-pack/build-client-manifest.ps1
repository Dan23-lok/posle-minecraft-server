param(
    [string]$ServerManifestPath,
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

if ([string]::IsNullOrWhiteSpace($ServerManifestPath)) {
    $ServerManifestPath = Join-Path $PSScriptRoot '..\server\mods-lock.json'
}
$ServerManifestPath = [System.IO.Path]::GetFullPath($ServerManifestPath)
if (-not (Test-Path -LiteralPath $ServerManifestPath -PathType Leaf)) {
    throw "Server lock not found: $ServerManifestPath. Pass -ServerManifestPath with a readable JSON file."
}
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $PSScriptRoot 'client-modpack.json'
}
$OutputPath = [System.IO.Path]::GetFullPath($OutputPath)
$headers = @{ 'User-Agent' = 'CodexMinecraftServerSetup/1.0' }
$serverLock = Get-Content -LiteralPath $ServerManifestPath -Raw | ConvertFrom-Json
if ($serverLock.schema_version -ne 1 -or -not $serverLock.mods) {
    throw "Unexpected server lock format: $ServerManifestPath"
}
$selectedServerProjects = [ordered]@{
    'Timeless and Classics Zero' = 'timeless-and-classics-zero'
    'The Hordes' = 'the-hordes'
    'Atlas Lib' = 'G6VHtQr4'
    'Born in Chaos' = 'born-in-chaos'
    'GeckoLib' = 'geckolib'
    "Spooki's Unique Mobs" = 'spookis-unique-mobs'
}

$mods = New-Object System.Collections.ArrayList
foreach ($name in $selectedServerProjects.Keys) {
    $matches = @($serverLock.mods | Where-Object { $_.name -ceq $name })
    if ($matches.Count -ne 1) { throw "Expected one server mod named: $name" }
    $entry = $matches[0]
    if ($entry.client_side -ne 'required' -or -not $entry.official_url -or -not $entry.download_url -or
            $entry.sha512 -notmatch '^[0-9a-fA-F]{128}$') {
        throw "Server mod has incomplete client download data: $name"
    }
    [void]$mods.Add([ordered]@{
        project = $selectedServerProjects[$name]
        version = $entry.version
        filename = $entry.filename
        url = $entry.download_url
        hash_algorithm = 'SHA512'
        hash = $entry.sha512.ToLowerInvariant()
        folder = 'mods'
        source_page = $entry.official_url
    })
}

$modrinthVersions = [ordered]@{
    'powered-flashlight' = '1tpZnh9i'
    'immersive-aircraft' = 'aDUlOdzA'
    'civilian-aviation' = 'ClkJoKdV'
    'not-enough-animations' = 'kGjMleOz'
    'dynamicrenderdistance' = 'A30fO8Re'
    'entityculling' = 'HUUJcFnt'
    'immediatelyfast' = 'rvsLEEZU'
    'modernfix' = 'lbZjFq4Z'
    'ferrite-core' = 'DG5Fn9Sz'
    'embeddium' = 'UTbfe5d1'
    'oculus' = 'iQ1SwGc3'
    'ambientsounds' = 'ApGAJplZ'
    'creativecore' = 'ChKayKur'
    'sound-physics-remastered' = 'x0sJ9PeR'
}
foreach ($project in $modrinthVersions.Keys) {
    $v = Invoke-RestMethod -Uri "https://api.modrinth.com/v2/version/$($modrinthVersions[$project])" -Headers $headers
    $files = @($v.files | Where-Object { $_.filename -notmatch 'SOURCE' })
    $file = @($files | Where-Object { $_.primary -eq $true })[0]
    if (-not $file) { $file = $files[0] }
    if (-not $file -or -not $file.hashes.sha512) { throw "Missing file/hash for $project" }
    [void]$mods.Add([ordered]@{
        project = $project
        version = $v.version_number
        filename = $file.filename
        url = $file.url
        hash_algorithm = 'SHA512'
        hash = $file.hashes.sha512.ToLowerInvariant()
        folder = 'mods'
        source_page = "https://modrinth.com/mod/$project"
    })
}

[void]$mods.Add([ordered]@{
    project = 'natural-disasters-cataclysm'
    version = '1.33.1'
    filename = 'naturaldisasters-forge-1.20.1-1.33.1.jar'
    url = 'https://www.curseforge.com/api/v1/mods/1651842/files/8644970/download'
    hash_algorithm = 'SHA256'
    hash = '27d0699cd6002a8d8dd25ec40e5bdec28e36336131afe1ec5a1b106894867371'
    folder = 'mods'
    source_page = 'https://www.curseforge.com/minecraft/mc-mods/natural-disasters-cataclysm'
})

$shader = Invoke-RestMethod -Uri 'https://api.modrinth.com/v2/version/SDF5S995' -Headers $headers
$shaderFile = @($shader.files | Where-Object { $_.primary -eq $true })[0]
if (-not $shaderFile) { $shaderFile = @($shader.files)[0] }
[void]$mods.Add([ordered]@{
    project = 'dms'
    version = $shader.version_number
    filename = $shaderFile.filename
    url = $shaderFile.url
    hash_algorithm = 'SHA512'
    hash = $shaderFile.hashes.sha512.ToLowerInvariant()
    folder = 'shaderpacks'
    source_page = 'https://modrinth.com/shader/dms'
})

# Client-only entity models/textures and original creator resource packs.
$visualVersions = [ordered]@{
    'entity-model-features' = @{ id = '6RQ5C1J6'; folder = 'mods'; kind = 'mod' }
    'entitytexturefeatures' = @{ id = 'VkWikkyj'; folder = 'mods'; kind = 'mod' }
    'fresh-animations' = @{ id = 'xN57JJts'; folder = 'resourcepacks'; kind = 'resourcepack' }
}
foreach ($project in $visualVersions.Keys) {
    $selection = $visualVersions[$project]
    $v = Invoke-RestMethod -Uri "https://api.modrinth.com/v2/version/$($selection.id)" -Headers $headers
    if ('1.20.1' -notin @($v.game_versions)) { throw "Not a Minecraft 1.20.1 asset: $project" }
    if ($selection.folder -eq 'mods' -and 'forge' -notin @($v.loaders)) {
        throw "Not a Forge asset: $project"
    }
    $file = @($v.files | Where-Object { $_.primary -eq $true })[0]
    if (-not $file) { $file = @($v.files)[0] }
    if (-not $file -or -not $file.hashes.sha512) { throw "Missing file/hash for $project" }
    $entry = [ordered]@{
        project = $project
        version = $v.version_number
        filename = $file.filename
        url = $file.url
        hash_algorithm = 'SHA512'
        hash = $file.hashes.sha512.ToLowerInvariant()
        folder = $selection.folder
    }
    if ($selection.folder -eq 'resourcepacks') { $entry.default_enabled = $true }
    $entry.source_page = "https://modrinth.com/$($selection.kind)/$project/version/$($selection.id)"
    [void]$mods.Add($entry)
}

# All Rights Reserved: the installer fetches this file from the original
# CurseForge CDN; never bundle its contents in the installer release.
[void]$mods.Add([ordered]@{
    project = 'tissous-zombie-pack'
    version = '1.20.1-2.7'
    filename = 'TZP_1.20.1_2.7.zip'
    url = 'https://mediafilez.forgecdn.net/files/4750/306/TZP_1.20.1_2.7.zip'
    hash_algorithm = 'SHA512'
    hash = '494bd42e2e0ae1e49bc27723ab04333ba1a5d7941e230d91e09b9d1844f70e136441025c75ac9a6611d30c746ddc3ecf8a6e8606a0fd4eaf8a607c96c34e9006'
    folder = 'resourcepacks'
    default_enabled = $true
    source_page = 'https://www.curseforge.com/minecraft/texture-packs/tissous-zombie-pack-optifine-1-7x-1-20/files/4750306'
})

$manifest = [ordered]@{
    pack = ([char[]]@(0x041F, 0x041E, 0x0421, 0x041B, 0x0415) -join '')
    pack_version = '2026.10.11.5'
    minecraft_version = '1.20.1'
    forge_version = '47.4.10'
    java_major = 17
    server_address = 'cairo-worrisome.tun.ply.gg'
    forge_installer = [ordered]@{
        url = 'https://maven.minecraftforge.net/net/minecraftforge/forge/1.20.1-47.4.10/forge-1.20.1-47.4.10-installer.jar'
        sha256 = '1912760b4cb6b803d8a826de603c9076b1da71ec2765e9a1f8c1ca78f65278e3'
    }
    java_runtime = [ordered]@{
        url = 'https://corretto.aws/downloads/resources/17.0.20.12.1/amazon-corretto-17.0.20.12.1-windows-x64-jdk.zip'
        sha256 = '1ac8d9dc48b170684ac6223113f524325bd842d14ed74dac28927f8165cffd3a'
        directory = 'jdk17.0.20_12'
    }
    files = @($mods)
}
$manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
Write-Output "Created $OutputPath with $($mods.Count) files"
