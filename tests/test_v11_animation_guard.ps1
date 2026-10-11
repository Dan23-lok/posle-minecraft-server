$ErrorActionPreference = 'Stop'
$source = Join-Path $PSScriptRoot '..\client-pack'
$tempParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$scratch = Join-Path $tempParent ('posle-v11-animation-guard-' + [Guid]::NewGuid().ToString('N'))
try {
    $package = Join-Path $scratch 'package'
    $client = Join-Path $scratch 'client'
    [IO.Directory]::CreateDirectory((Join-Path $package 'historical')) | Out-Null
    [IO.Directory]::CreateDirectory($client) | Out-Null
    foreach ($name in @('Install-HorrorClient.ps1','Invoke-LocalPlay.ps1',
            'Uninstall-HorrorClient.ps1','Forge-ClientReadiness.ps1')) {
        Copy-Item -LiteralPath (Join-Path $source $name) -Destination $package
    }
    Copy-Item -LiteralPath (Join-Path $source 'historical\client-modpack-2026.10.11.4.json') `
        -Destination (Join-Path $package 'historical')
    $release = Get-Content -LiteralPath (Join-Path $source 'client-modpack.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $manifest = [ordered]@{
        pack=$release.pack; pack_version='2026.10.11.8'; minecraft_version='1.20.1'
        forge_version='47.4.10'; java_major=17; server_address=$release.server_address
        java_runtime=$release.java_runtime; files=@()
    }
    $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $package 'client-modpack.json') -Encoding UTF8
    $receipt = [ordered]@{
        pack=$release.pack; pack_version='2026.10.11.8'; minecraft_version='1.20.1'; forge_version='47.4.10'
        minecraft_directory=[IO.Path]::GetFullPath($client); managed_files=@()
    }
    $receipt | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $client 'horror-apocalypse-install.json') -Encoding UTF8
    foreach ($name in @('Install-HorrorClient.ps1','Invoke-LocalPlay.ps1','Uninstall-HorrorClient.ps1')) {
        $message = $null
        try {
            if ($name -eq 'Install-HorrorClient.ps1') {
                & (Join-Path $package $name) -MinecraftDirectory $client -SkipForge | Out-Null
            } elseif ($name -eq 'Invoke-LocalPlay.ps1') {
                & (Join-Path $package $name) -MinecraftDirectory $client -DryRun | Out-Null
            } else {
                & (Join-Path $package $name) -MinecraftDirectory $client -Confirm:$false | Out-Null
            }
        } catch { $message = $_.Exception.Message }
        if ($message -notmatch 'animation') {
            throw "$name did not reject missing v11 animation patch: $message"
        }
        if (-not (Test-Path -LiteralPath (Join-Path $client 'horror-apocalypse-install.json'))) {
            throw "$name removed the receipt before validating the patch."
        }
    }
} finally {
    $absolute = [IO.Path]::GetFullPath($scratch)
    if ([IO.Directory]::Exists($absolute)) {
        if (-not $absolute.StartsWith($tempParent, [StringComparison]::OrdinalIgnoreCase) -or
            -not (Split-Path -Leaf $absolute).StartsWith('posle-v11-animation-guard-')) {
            throw 'Unsafe animation guard fixture cleanup path.'
        }
        [IO.Directory]::Delete($absolute, $true)
    }
}
Write-Output 'v11 animation patch guard passed for installer, Play, and uninstall.'
