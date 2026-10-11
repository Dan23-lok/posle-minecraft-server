# Network QA: use the release installer against a disposable client directory.
# This is not part of the offline suite; it fetches official Modrinth CDN files.
$ErrorActionPreference = 'Stop'
$source = Join-Path $PSScriptRoot '..\client-pack'
$tempParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$scratch = Join-Path $tempParent ('posle-v11-download-' + [Guid]::NewGuid().ToString('N'))
try {
    $package = Join-Path $scratch 'package'
    $client = Join-Path $scratch 'client'
    [IO.Directory]::CreateDirectory($package) | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $package 'historical')) | Out-Null
    foreach ($name in @('Install-HorrorClient.ps1', 'Uninstall-HorrorClient.ps1',
            'Forge-ClientReadiness.ps1')) {
        Copy-Item -LiteralPath (Join-Path $source $name) -Destination $package
    }
    Copy-Item -LiteralPath (Join-Path $source 'historical\client-modpack-2026.10.11.4.json') `
        -Destination (Join-Path $package 'historical')
    $release = Get-Content -LiteralPath (Join-Path $source 'client-modpack.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $selected = @($release.files | Where-Object project -in @('dynamic-flashlight', 'true-darkness-biomes'))
    if ($selected.Count -ne 2) { throw 'Expected two pinned official flashlight/darkness files.' }
    $manifest = [ordered]@{
        pack=$release.pack; pack_version='qa-v11-official'; minecraft_version='1.20.1';
        forge_version='47.4.10'; java_major=17; server_address=$release.server_address;
        java_runtime=$release.java_runtime; files=$selected
    }
    $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $package 'client-modpack.json') -Encoding UTF8
    [IO.Directory]::CreateDirectory((Join-Path $client 'saves')) | Out-Null
    [IO.File]::WriteAllText((Join-Path $client 'saves\preserve.txt'), 'keep this save')
    & (Join-Path $package 'Install-HorrorClient.ps1') -MinecraftDirectory $client -SkipForge -NoShader | Out-Null
    $receipt = Get-Content -LiteralPath (Join-Path $client 'horror-apocalypse-install.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($receipt.shader_enabled -cne $false -or @($receipt.managed_files).Count -ne 2) {
        throw 'Official download receipt has wrong shader state or file count.'
    }
    foreach ($entry in $selected) {
        $path = Join-Path (Join-Path $client 'mods') $entry.filename
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing $($entry.filename)" }
        $hash = (Get-FileHash -LiteralPath $path -Algorithm $entry.hash_algorithm).Hash
        if ($hash -ine $entry.hash) { throw "Wrong official hash: $($entry.filename)" }
        $owned = @($receipt.managed_files | Where-Object filename -eq $entry.filename)
        if ($owned.Count -ne 1 -or $owned[0].created_by_posle -cne $true) {
            throw "Downloaded file ownership missing: $($entry.filename)"
        }
        Write-Output "$($entry.filename) SHA512 $hash"
    }
    & (Join-Path $package 'Uninstall-HorrorClient.ps1') -MinecraftDirectory $client -Confirm:$false | Out-Null
    foreach ($entry in $selected) {
        if (Test-Path -LiteralPath (Join-Path (Join-Path $client 'mods') $entry.filename)) {
            throw "Owned file survived uninstall: $($entry.filename)"
        }
    }
    if (-not (Test-Path -LiteralPath (Join-Path $client 'saves\preserve.txt'))) {
        throw 'Uninstall removed unrelated save.'
    }
    Write-Output 'Official v11 file download, hash, receipt, and uninstall QA passed.'
} finally {
    $absolute = [IO.Path]::GetFullPath($scratch)
    if ([IO.Directory]::Exists($absolute)) {
        if (-not $absolute.StartsWith($tempParent, [StringComparison]::OrdinalIgnoreCase) -or
            -not (Split-Path -Leaf $absolute).StartsWith('posle-v11-download-')) {
            throw 'Unsafe download QA cleanup path.'
        }
        [IO.Directory]::Delete($absolute, $true)
    }
}
