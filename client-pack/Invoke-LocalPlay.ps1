[CmdletBinding()]
param(
    [string]$PlayUri = 'posle://play',
    [string]$MinecraftDirectory = (Join-Path $env:APPDATA '.minecraft-horror-apocalypse'),
    [string]$TLauncherPropertiesPath = (Join-Path $env:APPDATA '.tlauncher\tlauncher-2.0.properties'),
    [string[]]$TLauncherCandidatePaths,
    [switch]$DryRun
)

# Local prototype only. No Windows protocol is registered by this file.
# The website must keep its existing download link until a supported launcher
# handoff is tested with a real TLauncher client and account.
$ErrorActionPreference = 'Stop'
if ($PlayUri -cnotin @('posle://play', 'posle://play/')) {
    throw 'Only posle://play or its canonical trailing-slash form is accepted.'
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
$forgeReadinessPath = Join-Path $PSScriptRoot 'Forge-ClientReadiness.ps1'
if (-not (Test-Path -LiteralPath $forgeReadinessPath -PathType Leaf)) {
    throw 'Forge-ClientReadiness.ps1 is missing beside this helper.'
}
. $forgeReadinessPath

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
$patchKind = [string]$manifest.local_animation_patch.kind
$patchRevision = [int]$manifest.local_animation_patch.revision
if ($manifest.pack_version -ceq '2026.10.11.7' -and
    ($patchKind -cne 'born-in-chaos-1.7.5' -or $patchRevision -ne 1)) {
    throw 'The v7 local animation patch has an unexpected identity or revision.'
}
$hasAnimationPatch = $patchKind -ceq 'born-in-chaos-1.7.5' -and $patchRevision -eq 1
if ($receipt.no_shader -isnot [bool] -or $receipt.no_resource_pack -isnot [bool] -or
    $receipt.shader_installed -isnot [bool] -or
    $receipt.shader_installed -ne (-not $receipt.no_shader)) {
    throw 'The installed client visual options differ from this release. Rerun Install-Client.cmd.'
}
$installedManifestCount = 0
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
    $optionalSkipped = ($item.folder -ceq 'resourcepacks' -and $receipt.no_resource_pack) -or
        ($item.folder -ceq 'shaderpacks' -and $receipt.no_shader)
    if ($matchingReceipt.Count -ne [int](-not $optionalSkipped)) {
        throw "The install receipt differs from the release manifest: $($item.filename)"
    }
    if ($optionalSkipped) { continue }
    $installedManifestCount++
    $path = Join-Path (Join-Path $MinecraftDirectory $item.folder) $item.filename
    if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or
        (Get-FileHash -LiteralPath $path -Algorithm $item.hash_algorithm).Hash -cne $item.hash.ToUpperInvariant()) {
        throw "A managed client file is missing or changed: $($item.filename)"
    }
}
$expectedReceiptCount = $installedManifestCount + [int]$hasAnimationPatch
if (@($receipt.managed_files).Count -ne $expectedReceiptCount) {
    throw 'The installed client file count differs from the release manifest.'
}

if ($hasAnimationPatch) {
    $patchName = 'BornInChaosAnimationFix-local.zip'
    $bornEntries = @($expectedFiles | Where-Object {
        $_.project -ceq 'born-in-chaos' -and $_.version -ceq '1.7.5' -and
        $_.folder -ceq 'mods' -and
        $_.filename -ceq 'born_in_chaos_[Forge]1.20.1_1.7.5.jar' -and
        $_.hash_algorithm -ceq 'SHA512' -and $_.hash -cmatch '^[A-Fa-f0-9]{128}$'
    })
    $generated = @($receipt.managed_files | Where-Object {
        $_.folder -ceq 'resourcepacks' -and $_.filename -ceq $patchName
    })
    if ($bornEntries.Count -ne 1 -or $generated.Count -ne 1 -or
        $receipt.animation_patch_revision -ne $patchRevision -or
        [string]$receipt.animation_patch_source_sha512 -ine [string]$bornEntries[0].hash -or
        $generated[0].hash_algorithm -cne 'SHA256' -or
        [string]$generated[0].hash -cnotmatch '^[A-Fa-f0-9]{64}$' -or
        $generated[0].generated_locally -cne $true -or
        $generated[0].created_by_posle -cne $true -or
        $generated[0].default_enabled -cne $true) {
        throw 'The generated animation patch receipt has an unexpected identity, source, or hash.'
    }
    $patchPath = Join-Path (Join-Path $MinecraftDirectory 'resourcepacks') $patchName
    $bornPath = Join-Path (Join-Path $MinecraftDirectory 'mods') $bornEntries[0].filename
    Assert-ForgeNoReparsePoint -Path $patchPath
    Assert-ForgeNoReparsePoint -Path $bornPath
    if (-not (Test-Path -LiteralPath $patchPath -PathType Leaf) -or
        (Get-FileHash -LiteralPath $patchPath -Algorithm SHA256).Hash -cne
            ([string]$generated[0].hash).ToUpperInvariant()) {
        throw 'The generated animation patch file does not match its installation receipt.'
    }

    # The generated ZIP can have different compressed bytes on another .NET
    # runtime. Verify its exact five logical entries against the pinned source
    # JAR instead of assuming a portable ZIP SHA-256.
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $patches = @(
        @{ Path = 'assets/born_in_chaos_v1/animations/babyskeleton.animation.json'; Count = 1 },
        @{ Path = 'assets/born_in_chaos_v1/animations/babyskeletondeamon.animation.json'; Count = 1 },
        @{ Path = 'assets/born_in_chaos_v1/animations/boneimp.animation.json'; Count = 1 },
        @{ Path = 'assets/born_in_chaos_v1/animations/scarletpersecutor.animation.json'; Count = 2 }
    )
    $sourceZip = [IO.Compression.ZipFile]::OpenRead($bornPath)
    try {
        $patchZip = [IO.Compression.ZipFile]::OpenRead($patchPath)
        try {
            if ($patchZip.Entries.Count -ne $patches.Count + 1) {
                throw 'The generated animation patch has an unexpected ZIP entry count.'
            }
            $utf8 = New-Object Text.UTF8Encoding($false)
            $metadata = $patchZip.GetEntry('pack.mcmeta')
            if (-not $metadata -or $metadata.Length -gt 4096) {
                throw 'The generated animation patch metadata is missing or oversized.'
            }
            $metadataReader = New-Object IO.StreamReader($metadata.Open(), $utf8, $true)
            try { $metadataText = $metadataReader.ReadToEnd() }
            finally { $metadataReader.Dispose() }
            if ($metadataText -cne '{"pack":{"pack_format":15,"description":"Born in Chaos animation correction generated locally"}}') {
                throw 'The generated animation patch metadata changed.'
            }
            foreach ($patch in $patches) {
                $sourceEntry = $sourceZip.GetEntry($patch.Path)
                $patchEntry = $patchZip.GetEntry($patch.Path)
                if (-not $sourceEntry -or -not $patchEntry -or $patchEntry.Length -gt 1MB) {
                    throw "The generated animation patch is missing or oversized: $($patch.Path)"
                }
                $sourceReader = New-Object IO.StreamReader($sourceEntry.Open(), $utf8, $true)
                try { $sourceText = $sourceReader.ReadToEnd() }
                finally { $sourceReader.Dispose() }
                if ([regex]::Matches($sourceText, '"-"').Count -ne $patch.Count) {
                    throw "The pinned Born in Chaos animation source changed: $($patch.Path)"
                }
                $expectedText = [regex]::Replace($sourceText, '"-"', '0')
                $patchReader = New-Object IO.StreamReader($patchEntry.Open(), $utf8, $true)
                try { $actualText = $patchReader.ReadToEnd() }
                finally { $patchReader.Dispose() }
                if ($actualText -cne $expectedText) {
                    throw "The generated animation patch content differs from the pinned source: $($patch.Path)"
                }
            }
        } finally { $patchZip.Dispose() }
    } finally { $sourceZip.Dispose() }

    # The ZIP can be intact while a player has disabled it in Minecraft's
    # resource-pack menu. Its animations then fall back to the broken source.
    $optionsPath = Join-Path $MinecraftDirectory 'options.txt'
    if (-not (Test-Path -LiteralPath $optionsPath -PathType Leaf)) {
        throw 'Minecraft options are missing; rerun Install-Client.cmd to enable the required animation patch.'
    }
    Assert-ForgeNoReparsePoint -Path $optionsPath
    $selectionLines = @(Get-Content -LiteralPath $optionsPath -Encoding UTF8 |
        Where-Object { $_.StartsWith('resourcePacks:', [StringComparison]::Ordinal) })
    if ($selectionLines.Count -ne 1) {
        throw 'Minecraft resource-pack selection is missing or ambiguous; rerun Install-Client.cmd.'
    }
    try { $selectedPacks = @(ConvertFrom-Json -InputObject $selectionLines[0].Substring('resourcePacks:'.Length)) }
    catch { throw 'Minecraft resource-pack selection is invalid; rerun Install-Client.cmd.' }
    if (@($selectedPacks | Where-Object { $_ -ceq "file/$patchName" }).Count -ne 1) {
        throw 'The required Born in Chaos animation patch is disabled; enable it in Minecraft or rerun Install-Client.cmd.'
    }
}

$versionId = '1.20.1-forge-47.4.10'
if (-not (Test-ForgeReady -ClientRoot $MinecraftDirectory -VersionId $versionId -StrictLauncherProfile)) {
    throw 'Forge 47.4.10 profile or libraries differ from the verified forms. Open TLauncher manually and update this client pack before using the website Play link.'
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
    throw 'TLauncher points at another game folder. Select the installed client folder in its settings.'
}
if ([string]$settings['login.version.game'] -cne $versionId) {
    throw 'TLauncher has not selected Forge 1.20.1-47.4.10. Choose it in the launcher first.'
}

if (-not $PSBoundParameters.ContainsKey('TLauncherCandidatePaths')) {
    # Keep this list in sync with Install-HorrorClient.ps1 -LaunchTLauncher.
    $TLauncherCandidatePaths = @(
        (Join-Path $env:APPDATA '.minecraft\TLauncher.exe'),
        (Join-Path $env:APPDATA '.tlauncher\TLauncher.exe'),
        (Join-Path $env:LOCALAPPDATA 'TLauncher\TLauncher.exe')
    )
}
$tlauncher = $null
foreach ($candidate in $TLauncherCandidatePaths) {
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
    $signature = Get-AuthenticodeSignature -LiteralPath $candidate
    if ($signature.Status -eq 'Valid' -and
        $signature.SignerCertificate.Subject -match '(^|, )O=TLauncher Inc\.(,|$)') {
        $tlauncher = $candidate
        break
    }
    Write-Warning "TLauncher candidate lacks the expected valid publisher signature: $candidate"
}
if (-not $tlauncher) {
    throw 'No signed TLauncher.exe was found in the candidate locations.'
}

Write-Host "Client pack verified: $($manifest.pack_version); Forge bootstrap $versionId; $expectedReceiptCount managed files."
Write-Host "Server: $($manifest.server_address)"
if ($DryRun) {
    Write-Host 'Dry run: TLauncher was not started and Windows protocol registration was not changed.'
    return
}

# TLauncher does not document a command-line API to choose this profile or
# press Play. The helper only opens the signed launcher after confirming that
# its current selection matches the installed pack.
Start-Process -FilePath $tlauncher -WorkingDirectory (Split-Path -Parent $tlauncher) -WindowStyle Normal
Write-Host 'TLauncher opened. Press Play in its window to start Forge, then join the saved server.'
