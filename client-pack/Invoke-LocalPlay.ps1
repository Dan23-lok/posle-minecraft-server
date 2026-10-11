[CmdletBinding()]
param(
    [string]$PlayUri = 'posle://play',
    [string]$MinecraftDirectory = (Join-Path $env:APPDATA '.minecraft-horror-apocalypse'),
    [string]$TLauncherPropertiesPath = (Join-Path $env:APPDATA '.tlauncher\tlauncher-2.0.properties'),
    [string]$TLauncherExe = (Join-Path $env:APPDATA '.minecraft\TLauncher.exe'),
    [switch]$DryRun
)

# Local prototype only. No Windows protocol is registered by this file.
# The website must keep its existing download link until a supported launcher
# handoff is tested with a real TLauncher client and account.
$ErrorActionPreference = 'Stop'
if ($PlayUri -cne 'posle://play') {
    throw 'Only the fixed posle://play action is accepted.'
}

$manifestPath = Join-Path $PSScriptRoot 'client-modpack.json'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw 'The client manifest is missing beside this helper.'
}
$manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ($manifest.minecraft_version -cne '1.20.1' -or $manifest.forge_version -cne '47.4.10' -or
    $manifest.server_address -cne 'cairo-worrisome.tun.ply.gg') {
    throw 'The client manifest is incompatible with this prototype.'
}

$MinecraftDirectory = [IO.Path]::GetFullPath($MinecraftDirectory)
$receiptPath = Join-Path $MinecraftDirectory 'horror-apocalypse-install.json'
if (-not (Test-Path -LiteralPath $receiptPath -PathType Leaf)) {
    throw 'The client pack is not installed. Run Install-Client.cmd first.'
}
$receipt = Get-Content -LiteralPath $receiptPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ($receipt.pack -cne $manifest.pack -or $receipt.pack_version -cne $manifest.pack_version -or
    $receipt.minecraft_version -cne $manifest.minecraft_version -or
    $receipt.forge_version -cne $manifest.forge_version -or
    [IO.Path]::GetFullPath([string]$receipt.minecraft_directory).TrimEnd('\') -cne $MinecraftDirectory.TrimEnd('\')) {
    throw 'Installed client does not match this release. Run the current installer before playing.'
}

$expectedFiles = @($manifest.files)
if (@($receipt.managed_files).Count -ne $expectedFiles.Count) {
    throw 'The installed client file count differs from the release manifest.'
}
foreach ($item in $expectedFiles) {
    if ($item.folder -cnotin @('mods', 'resourcepacks', 'shaderpacks') -or
        [string]::IsNullOrWhiteSpace($item.filename) -or
        $item.filename -match '[\\/]' -or $item.filename -in @('.', '..') -or
        $item.filename.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0 -or
        $item.hash_algorithm -cnotin @('SHA256', 'SHA512') -or
        ($item.hash_algorithm -ceq 'SHA256' -and $item.hash -cnotmatch '^[A-Fa-f0-9]{64}$') -or
        ($item.hash_algorithm -ceq 'SHA512' -and $item.hash -cnotmatch '^[A-Fa-f0-9]{128}$')) {
        throw 'The release manifest contains an unsafe or invalid file entry.'
    }
    $matchingReceipt = @($receipt.managed_files | Where-Object {
        $_.folder -ceq $item.folder -and $_.filename -ceq $item.filename -and
        $_.hash_algorithm -ceq $item.hash_algorithm -and $_.hash -ceq $item.hash
    })
    if ($matchingReceipt.Count -ne 1) {
        throw "The install receipt differs from the release manifest: $($item.filename)"
    }
    $path = Join-Path (Join-Path $MinecraftDirectory $item.folder) $item.filename
    if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or
        (Get-FileHash -LiteralPath $path -Algorithm $item.hash_algorithm).Hash -cne $item.hash.ToUpperInvariant()) {
        throw "A managed client file is missing or changed: $($item.filename)"
    }
}

$versionId = '1.20.1-forge-47.4.10'
$versionJson = Join-Path $MinecraftDirectory "versions\$versionId\$versionId.json"
$versionJar = Join-Path $MinecraftDirectory "versions\$versionId\$versionId.jar"
$forgeJar = Join-Path $MinecraftDirectory 'libraries\net\minecraftforge\forge\1.20.1-47.4.10\forge-1.20.1-47.4.10-client.jar'
foreach ($file in @($versionJson, $versionJar, $forgeJar)) {
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
        throw "Forge 47.4.10 is incomplete: $file"
    }
}
$profile = Get-Content -LiteralPath $versionJson -Raw -Encoding UTF8 | ConvertFrom-Json
$gameArguments = @($profile.arguments.game | ForEach-Object { $_.values })
$forgeIndex = [Array]::IndexOf([object[]]$gameArguments, '--fml.forgeVersion')
$minecraftIndex = [Array]::IndexOf([object[]]$gameArguments, '--fml.mcVersion')
if ($profile.id -cne $versionId -or $profile.javaVersion.majorVersion -ne 17 -or
    $profile.mainClass -cne 'cpw.mods.bootstraplauncher.BootstrapLauncher' -or
    $forgeIndex -lt 0 -or $forgeIndex + 1 -ge $gameArguments.Count -or
    $gameArguments[$forgeIndex + 1] -cne '47.4.10' -or
    $minecraftIndex -lt 0 -or $minecraftIndex + 1 -ge $gameArguments.Count -or
    $gameArguments[$minecraftIndex + 1] -cne '1.20.1') {
    throw 'Forge version metadata is not the expected Minecraft 1.20.1 profile.'
}

if (-not (Test-Path -LiteralPath $TLauncherPropertiesPath -PathType Leaf)) {
    throw 'TLauncher settings are missing. Select the client game folder and Forge 47.4.10 in TLauncher.'
}
$settings = @{}
foreach ($line in (Get-Content -LiteralPath $TLauncherPropertiesPath -Encoding UTF8)) {
    if ($line -match '^([^#!][^=]*?)=(.*)$') { $settings[$Matches[1]] = $Matches[2] }
}
$configuredDirectory = [string]$settings['minecraft.gamedir']
$configuredDirectory = $configuredDirectory.Replace('\\', '\').Replace('\:', ':')
if ([string]::IsNullOrWhiteSpace($configuredDirectory) -or
    [IO.Path]::GetFullPath($configuredDirectory).TrimEnd('\') -cne $MinecraftDirectory.TrimEnd('\')) {
    throw 'TLauncher points at another game folder. Select the installed ПОСЛЕ folder in its settings.'
}
if ([string]$settings['login.version.game'] -cne $versionId) {
    throw 'TLauncher has not selected Forge 1.20.1-47.4.10. Choose it in the launcher first.'
}

if (-not (Test-Path -LiteralPath $TLauncherExe -PathType Leaf)) {
    throw 'TLauncher.exe was not found. Open your installed TLauncher manually.'
}
$signature = Get-AuthenticodeSignature -LiteralPath $TLauncherExe
if ($signature.Status -ne 'Valid' -or
    $signature.SignerCertificate.Subject -notmatch '(^|, )O=TLauncher Inc\.(,|$)') {
    throw 'The TLauncher executable does not have the expected valid publisher signature.'
}

Write-Host "Client pack verified: $($manifest.pack_version); Forge $versionId; $($expectedFiles.Count) managed files."
Write-Host "Server: $($manifest.server_address)"
if ($DryRun) {
    Write-Host 'Dry run: TLauncher was not started and Windows protocol registration was not changed.'
    return
}

# TLauncher does not document a command-line API to choose this profile or
# press Play. The helper only opens the signed launcher after confirming that
# its current selection matches the installed pack.
Start-Process -FilePath $TLauncherExe -WorkingDirectory (Split-Path -Parent $TLauncherExe) -WindowStyle Normal
Write-Host 'TLauncher opened. Press Play in its window to start Forge, then join the saved server.'
