# Exercise uninstall's Website Play lifecycle without touching live HKCU.
$ErrorActionPreference = 'Stop'
$root = Join-Path $env:TEMP ('posle-uninstall-play-test-' + [Guid]::NewGuid().ToString('N'))
$root = [IO.Path]::GetFullPath($root)
$tempBase = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\', '/') + '\'
if (-not $root.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Refusing to create the uninstall test outside TEMP.'
}
$source = Join-Path $PSScriptRoot '..\client-pack'
$fixture = Join-Path $root 'installer'
$appData = Join-Path $root 'AppData'
$defaultClient = Join-Path $appData '.minecraft-horror-apocalypse'
$customClient = Join-Path $root 'custom-client'
$marker = Join-Path $root 'unregistered.txt'
$oldAppData = $env:APPDATA

function New-EmptyReceipt {
    param([string]$Client, [object]$Manifest)
    New-Item -ItemType Directory -Path $Client -Force | Out-Null
    [ordered]@{
        pack = $Manifest.pack
        pack_version = $Manifest.pack_version
        minecraft_version = $Manifest.minecraft_version
        forge_version = $Manifest.forge_version
        minecraft_directory = [IO.Path]::GetFullPath($Client)
        managed_files = @()
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $Client 'horror-apocalypse-install.json') -Encoding UTF8
}

try {
    New-Item -ItemType Directory -Path (Join-Path $fixture 'historical') -Force | Out-Null
    foreach ($name in @('Uninstall-HorrorClient.ps1', 'client-modpack.json')) {
        Copy-Item -LiteralPath (Join-Path $source $name) -Destination (Join-Path $fixture $name)
    }
    Copy-Item -LiteralPath (Join-Path $source 'historical\client-modpack-2026.10.11.4.json') `
        -Destination (Join-Path $fixture 'historical\client-modpack-2026.10.11.4.json')
    @'
[CmdletBinding(SupportsShouldProcess = $true)]
param()
Set-Content -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) 'unregistered.txt') -Value 'called'
'@ | Set-Content -LiteralPath (Join-Path $fixture 'Unregister-PlayProtocol.ps1') -Encoding UTF8
    $manifest = Get-Content -LiteralPath (Join-Path $fixture 'client-modpack.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    New-EmptyReceipt -Client $defaultClient -Manifest $manifest
    New-Item -ItemType Directory -Path (Join-Path $defaultClient 'saves') | Out-Null
    Set-Content -LiteralPath (Join-Path $defaultClient 'saves\keep.txt') -Value 'player data'
    $env:APPDATA = $appData
    $uninstall = Join-Path $fixture 'Uninstall-HorrorClient.ps1'
    & $uninstall -UnregisterWebsitePlay -WhatIf | Out-Null
    if (-not (Test-Path -LiteralPath (Join-Path $defaultClient 'horror-apocalypse-install.json')) -or
        (Test-Path -LiteralPath $marker)) { throw 'WhatIf changed the client or URI association.' }
    & $uninstall -UnregisterWebsitePlay -Confirm:$false | Out-Null
    if ((Test-Path -LiteralPath (Join-Path $defaultClient 'horror-apocalypse-install.json')) -or
        -not (Test-Path -LiteralPath $marker) -or
        -not (Test-Path -LiteralPath (Join-Path $defaultClient 'saves\keep.txt'))) {
        throw 'Default client uninstall did not invoke unregister while preserving saves.'
    }
    Remove-Item -LiteralPath $marker -Force
    & $uninstall -UnregisterWebsitePlay -Confirm:$false | Out-Null
    if (-not (Test-Path -LiteralPath $marker)) {
        throw 'Uninstall with a missing receipt did not remove the stale Website Play association.'
    }
    Remove-Item -LiteralPath $marker -Force
    New-EmptyReceipt -Client $customClient -Manifest $manifest
    & $uninstall -MinecraftDirectory $customClient -UnregisterWebsitePlay -Confirm:$false | Out-Null
    if ((Test-Path -LiteralPath $marker) -or
        (Test-Path -LiteralPath (Join-Path $customClient 'horror-apocalypse-install.json'))) {
        throw 'Custom client uninstall touched Website Play or left its empty receipt.'
    }
    Write-Host 'PASS: WhatIf skips unregister; default uninstall calls owned unregister; custom uninstall leaves association; saves remain.'
} finally {
    $env:APPDATA = $oldAppData
    if (Test-Path -LiteralPath $root) {
        if (-not $root.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase) -or
            -not (Split-Path -Leaf $root).StartsWith('posle-uninstall-play-test-')) {
            throw 'Refusing to remove the unexpected uninstall test directory.'
        }
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}
