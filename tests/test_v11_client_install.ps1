$ErrorActionPreference = 'Stop'
$sourceClient = Join-Path $PSScriptRoot '..\client-pack'
$tempParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$scratch = [IO.Path]::Combine($tempParent, 'posle-v11-install-' + [Guid]::NewGuid().ToString('N'))

function Assert-Equal($Expected, $Actual, [string]$Name) {
    if ($Expected -cne $Actual) { throw "$Name`: expected '$Expected', got '$Actual'" }
}
function Save-FixtureFile($Client, $Entry) {
    $path = Join-Path (Join-Path $Client $Entry.folder) $Entry.filename
    [IO.Directory]::CreateDirectory((Split-Path -Parent $path)) | Out-Null
    [IO.File]::WriteAllText($path, "$($Entry.project) fixture")
    return $path
}
function Get-Receipt($Client) {
    return (Get-Content -LiteralPath (Join-Path $Client 'horror-apocalypse-install.json') -Raw -Encoding UTF8 | ConvertFrom-Json)
}

try {
    [IO.Directory]::CreateDirectory($scratch) | Out-Null
    $package = Join-Path $scratch 'client-pack'
    [IO.Directory]::CreateDirectory($package) | Out-Null
    foreach ($name in @('Install-HorrorClient.ps1', 'Invoke-LocalPlay.ps1', 'Forge-ClientReadiness.ps1',
            'Uninstall-HorrorClient.ps1')) {
        Copy-Item -LiteralPath (Join-Path $sourceClient $name) -Destination $package
    }
    [IO.Directory]::CreateDirectory((Join-Path $package 'historical')) | Out-Null
    Copy-Item -LiteralPath (Join-Path $sourceClient 'historical\client-modpack-2026.10.11.4.json') `
        -Destination (Join-Path $package 'historical')
    $metadata = @(
        [ordered]@{ project='powered-flashlight'; folder='mods'; filename='powered.jar' },
        [ordered]@{ project='dynamic-flashlight'; folder='mods'; filename='flashlight.jar' },
        [ordered]@{ project='true-darkness-biomes'; folder='mods'; filename='darkness.jar'; install_when='shaders_disabled' },
        [ordered]@{ project='dms'; folder='shaderpacks'; filename='DMS 1.0.3.zip' }
    )
    $fixture = Join-Path $scratch 'fixture'
    $entries = @(
        foreach ($item in $metadata) {
            $path = Save-FixtureFile -Client $fixture -Entry $item
            $entry = [ordered]@{
                project=$item.project; version='fixture'; folder=$item.folder; filename=$item.filename
                url="https://cdn.modrinth.com/fixture/$($item.filename)"
                hash_algorithm='SHA256'; hash=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
            }
            if ($item.install_when) { $entry.install_when = $item.install_when }
            $entry
        }
    )
    $release = Get-Content -LiteralPath (Join-Path $sourceClient 'client-modpack.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $manifest = [ordered]@{
        pack=$release.pack; pack_version='fixture-v11'; minecraft_version='1.20.1'
        forge_version='47.4.10'; java_major=17; java_runtime=$release.java_runtime
        server_address='cairo-worrisome.tun.ply.gg'; files=$entries
    }
    $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $package 'client-modpack.json') -Encoding UTF8

    # Clean Low install: no shader, darkness selected, both flashlight mods selected.
    $low = Join-Path $scratch 'low'
    foreach ($entry in $metadata) { Save-FixtureFile -Client $low -Entry $entry | Out-Null }
    & (Join-Path $package 'Install-HorrorClient.ps1') -MinecraftDirectory $low -SkipForge -NoShader | Out-Null
    $receipt = Get-Receipt $low
    Assert-Equal $false $receipt.shader_enabled 'clean Low effective shader state'
    Assert-Equal 3 @($receipt.managed_files).Count 'clean Low managed file count'
    Assert-Equal 1 @($receipt.managed_files | Where-Object filename -eq 'darkness.jar').Count 'clean Low darkness selection'
    Assert-Equal 1 @($receipt.managed_files | Where-Object filename -eq 'flashlight.jar').Count 'clean Low dynamic flashlight selection'
    Assert-Equal 'enableShaders=false' @((Get-Content (Join-Path $low 'config\oculus.properties')) |
        Where-Object { $_ -like 'enableShaders=*' })[0] 'clean Low Oculus state'

    # v9-style receipt migration: preserve a player's custom render distance and
    # existing shader choice when adding the newly pinned mod files.
    $high = Join-Path $scratch 'high'
    foreach ($entry in $metadata) { Save-FixtureFile -Client $high -Entry $entry | Out-Null }
    [IO.Directory]::CreateDirectory((Join-Path $high 'config')) | Out-Null
    [IO.File]::WriteAllText((Join-Path $high 'options.txt'), "renderDistance:14`nfov:0.9`n")
    [IO.File]::WriteAllText((Join-Path $high 'config\oculus.properties'), "shaderPack=DMS 1.0.3.zip`nenableShaders=true`n")
    $oldManaged = @(
        foreach ($entry in @($entries | Where-Object { $_.filename -in @('powered.jar', 'DMS 1.0.3.zip') })) {
            [ordered]@{ folder=$entry.folder; filename=$entry.filename; hash_algorithm=$entry.hash_algorithm
                hash=$entry.hash; created_by_posle=$false; default_enabled=$false }
        }
    )
    $oldReceipt = [ordered]@{
        pack=$release.pack; pack_version='2026.10.11.7'; minecraft_version='1.20.1'; forge_version='47.4.10'
        minecraft_directory=[IO.Path]::GetFullPath($high); graphics_profile='Balanced'; graphics_policy_revision=2
        no_shader=$false; shader_installed=$true; no_resource_pack=$false; managed_files=$oldManaged
    }
    $oldReceipt | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $high 'horror-apocalypse-install.json') -Encoding UTF8
    & (Join-Path $package 'Install-HorrorClient.ps1') -MinecraftDirectory $high -SkipForge | Out-Null
    $receipt = Get-Receipt $high
    Assert-Equal $true $receipt.shader_enabled 'update uses existing enabled shader'
    Assert-Equal 3 @($receipt.managed_files).Count 'shader-on managed file count'
    Assert-Equal 0 @($receipt.managed_files | Where-Object filename -eq 'darkness.jar').Count 'shader-on skips darkness'
    Assert-Equal 'renderDistance:14' @((Get-Content (Join-Path $high 'options.txt')) |
        Where-Object { $_ -like 'renderDistance:*' })[0] 'update preserves player render distance'
    Assert-Equal 'enableShaders=true' @((Get-Content (Join-Path $high 'config\oculus.properties')) |
        Where-Object { $_ -like 'enableShaders=*' })[0] 'update preserves player shader choice'
    $playError = $null
    try {
        & (Join-Path $package 'Invoke-LocalPlay.ps1') -MinecraftDirectory $high -DryRun `
            -TLauncherPropertiesPath (Join-Path $scratch 'missing-tlauncher.properties') | Out-Null
    } catch { $playError = $_.Exception.Message }
    if ($playError -notlike 'Forge 47.4.10 profile or libraries differ*') {
        throw "Valid shader-on receipt failed before Forge readiness: $playError"
    }
    [IO.File]::WriteAllText((Join-Path $high 'config\oculus.properties'),
        "shaderPack=`nenableShaders=true`n")
    $shaderError = $null
    try { & (Join-Path $package 'Install-HorrorClient.ps1') -MinecraftDirectory $high -SkipForge | Out-Null }
    catch { $shaderError = $_.Exception.Message }
    if ($shaderError -notlike '*shader pack*') {
        throw "Installer accepted enabled Oculus without a selected shader pack: $shaderError"
    }
    $shaderError = $null
    try {
        & (Join-Path $package 'Invoke-LocalPlay.ps1') -MinecraftDirectory $high -DryRun `
            -TLauncherPropertiesPath (Join-Path $scratch 'missing-tlauncher.properties') | Out-Null
    } catch { $shaderError = $_.Exception.Message }
    if ($shaderError -notlike '*shader pack*') {
        throw "Play accepted enabled Oculus without a selected shader pack: $shaderError"
    }
    [IO.File]::WriteAllText((Join-Path $high 'config\oculus.properties'),
        "shaderPack=Absent.zip`nenableShaders=true`n")
    $shaderError = $null
    try { & (Join-Path $package 'Install-HorrorClient.ps1') -MinecraftDirectory $high -SkipForge | Out-Null }
    catch { $shaderError = $_.Exception.Message }
    if ($shaderError -notlike '*shader pack is missing*') {
        throw "Installer accepted an absent custom shader pack: $shaderError"
    }
    [IO.File]::WriteAllText((Join-Path $high 'shaderpacks\Custom.zip'), 'custom shader fixture')
    [IO.File]::WriteAllText((Join-Path $high 'config\oculus.properties'),
        "shaderPack=Custom.zip`nenableShaders=true`n")
    & (Join-Path $package 'Install-HorrorClient.ps1') -MinecraftDirectory $high -SkipForge | Out-Null
    $shaderError = $null
    try {
        & (Join-Path $package 'Invoke-LocalPlay.ps1') -MinecraftDirectory $high -DryRun `
            -TLauncherPropertiesPath (Join-Path $scratch 'missing-tlauncher.properties') | Out-Null
    } catch { $shaderError = $_.Exception.Message }
    if ($shaderError -notlike 'Forge 47.4.10 profile or libraries differ*') {
        throw "Installed custom shader was rejected before Forge readiness: $shaderError"
    }
    [IO.File]::WriteAllText((Join-Path $high 'config\oculus.properties'),
        "shaderPack=DMS 1.0.3.zip`nenableShaders=true`n")
    $receipt.shader_enabled = $false
    $receipt | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $high 'horror-apocalypse-install.json') -Encoding UTF8
    $playError = $null
    try {
        & (Join-Path $package 'Invoke-LocalPlay.ps1') -MinecraftDirectory $high -DryRun `
            -TLauncherPropertiesPath (Join-Path $scratch 'missing-tlauncher.properties') | Out-Null
    } catch { $playError = $_.Exception.Message }
    if ($playError -notlike '*visual*' -and $playError -notlike '*shader*') {
        throw "Tampered shader receipt was not rejected: $playError"
    }
    $receipt.shader_enabled = $true
    $receipt | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $high 'horror-apocalypse-install.json') -Encoding UTF8
    [IO.File]::WriteAllText((Join-Path $high 'config\oculus.properties'), "shaderPack=DMS 1.0.3.zip`nenableShaders=false`n")
    $playError = $null
    try {
        & (Join-Path $package 'Invoke-LocalPlay.ps1') -MinecraftDirectory $high -DryRun `
            -TLauncherPropertiesPath (Join-Path $scratch 'missing-tlauncher.properties') | Out-Null
    } catch { $playError = $_.Exception.Message }
    if ($playError -notlike '*shader state changed*') {
        throw "Changed Oculus setting was not rejected before launch: $playError"
    }
    [IO.File]::WriteAllText((Join-Path $high 'config\oculus.properties'), "shaderPack=DMS 1.0.3.zip`nenableShaders=true`n")

    # Toggling off shaders installs the dark-night client mod without rewriting
    # the unrelated custom options.
    & (Join-Path $package 'Install-HorrorClient.ps1') -MinecraftDirectory $high -SkipForge -NoShader | Out-Null
    $receipt = Get-Receipt $high
    Assert-Equal $false $receipt.shader_enabled 'NoShader records effective state'
    Assert-Equal 1 @($receipt.managed_files | Where-Object filename -eq 'darkness.jar').Count 'NoShader installs darkness'
    Assert-Equal 'renderDistance:14' @((Get-Content (Join-Path $high 'options.txt')) |
        Where-Object { $_ -like 'renderDistance:*' })[0] 'NoShader preserves player render distance'

    # Oculus accepts whitespace around '=', so an explicit graphics reset must
    # replace that same key rather than append a second ambiguous setting.
    [IO.File]::WriteAllText((Join-Path $high 'config\oculus.properties'),
        "shaderPack=DMS 1.0.3.zip`nenableShaders = false`n")
    & (Join-Path $package 'Install-HorrorClient.ps1') -MinecraftDirectory $high -SkipForge `
        -GraphicsProfile Auto | Out-Null
    $shaderLines = @(Get-Content (Join-Path $high 'config\oculus.properties') |
        Where-Object { $_ -match '^\s*enableShaders\s*=' })
    Assert-Equal 1 $shaderLines.Count 'explicit graphics reset leaves one Oculus shader key'
    $receipt = Get-Receipt $high
    Assert-Equal $receipt.shader_enabled (($shaderLines[0] -split '=', 2)[1].Trim() -eq 'true') `
        'explicit graphics reset matches receipt shader state'

    # Receipt-governed uninstall must keep a pre-existing copy of a mod.
    & (Join-Path $package 'Uninstall-HorrorClient.ps1') -MinecraftDirectory $high -Confirm:$false | Out-Null
    Assert-Equal $true (Test-Path -LiteralPath (Join-Path $high 'mods\darkness.jar')) 'uninstall keeps pre-existing mod'

    # A v9 player who opted out of shaders and optional resource packs must
    # keep both choices on an ordinary update, even when the machine can run DMS.
    $optout = Join-Path $scratch 'optout'
    foreach ($entry in $metadata) { Save-FixtureFile -Client $optout -Entry $entry | Out-Null }
    $visualMeta = [ordered]@{ project='visual-fixture'; folder='resourcepacks'; filename='visual.zip' }
    $visualPath = Save-FixtureFile -Client $optout -Entry $visualMeta
    $visualEntry = [ordered]@{
        project='visual-fixture'; version='fixture'; folder='resourcepacks'; filename='visual.zip'
        url='https://cdn.modrinth.com/fixture/visual.zip'; hash_algorithm='SHA256'
        hash=(Get-FileHash -LiteralPath $visualPath -Algorithm SHA256).Hash; default_enabled=$true
    }
    $manifest.files = @($entries) + @($visualEntry)
    $manifest.pack_version = 'fixture-v11-optouts'
    $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $package 'client-modpack.json') -Encoding UTF8
    [IO.Directory]::CreateDirectory((Join-Path $optout 'config')) | Out-Null
    [IO.File]::WriteAllText((Join-Path $optout 'config\oculus.properties'),
        "shaderPack=DMS 1.0.3.zip`nenableShaders=false`n")
    [IO.File]::WriteAllText((Join-Path $optout 'options.txt'), 'renderDistance:11' + "`n" +
        'resourcePacks:["vanilla"]' + "`n")
    $prior = [ordered]@{
        pack=$release.pack; pack_version='2026.10.11.7'; minecraft_version='1.20.1'; forge_version='47.4.10'
        minecraft_directory=[IO.Path]::GetFullPath($optout); graphics_profile='Low'; graphics_policy_revision=2
        no_shader=$true; shader_installed=$false; no_resource_pack=$true; managed_files=@($oldManaged[0])
    }
    $prior | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $optout 'horror-apocalypse-install.json') -Encoding UTF8
    & (Join-Path $package 'Install-HorrorClient.ps1') -MinecraftDirectory $optout -SkipForge | Out-Null
    $receipt = Get-Receipt $optout
    Assert-Equal $true $receipt.no_shader 'v9 shader opt-out survives ordinary update'
    Assert-Equal $true $receipt.no_resource_pack 'v9 resource opt-out survives ordinary update'
    Assert-Equal $false $receipt.shader_enabled 'v9 shader opt-out keeps Oculus off'
    Assert-Equal 0 @($receipt.managed_files | Where-Object folder -eq 'shaderpacks').Count 'v9 shader opt-out skips DMS'
    Assert-Equal 0 @($receipt.managed_files | Where-Object filename -eq 'visual.zip').Count 'v9 resource opt-out skips visual pack'
    Assert-Equal 1 @($receipt.managed_files | Where-Object filename -eq 'darkness.jar').Count 'v9 shader opt-out selects darkness'
    Assert-Equal 'resourcePacks:["vanilla"]' @((Get-Content (Join-Path $optout 'options.txt')) |
        Where-Object { $_ -like 'resourcePacks:*' })[0] 'v9 resource opt-out stays selected off'
    & (Join-Path $package 'Install-HorrorClient.ps1') -MinecraftDirectory $optout -SkipForge `
        -NoShader:$false -NoResourcePack:$false | Out-Null
    $receipt = Get-Receipt $optout
    Assert-Equal $false $receipt.no_shader 'explicit false clears shader opt-out'
    Assert-Equal $false $receipt.no_resource_pack 'explicit false clears resource opt-out'
    Assert-Equal 1 @($receipt.managed_files | Where-Object filename -eq 'visual.zip').Count 'explicit false restores visual pack'
} finally {
    if ([IO.Directory]::Exists($scratch)) {
        $absolute = [IO.Path]::GetFullPath($scratch)
        if (-not $absolute.StartsWith($tempParent, [StringComparison]::OrdinalIgnoreCase) -or
            -not (Split-Path -Leaf $absolute).StartsWith('posle-v11-install-')) {
            throw 'Unsafe fixture cleanup path.'
        }
        [IO.Directory]::Delete($absolute, $true)
    }
}
Write-Output 'v11 staged client integration passed.'
