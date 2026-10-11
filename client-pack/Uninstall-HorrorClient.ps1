[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [string]$MinecraftDirectory = (Join-Path $env:APPDATA '.minecraft-horror-apocalypse')
)

$ErrorActionPreference = 'Stop'
$MinecraftDirectory = [IO.Path]::GetFullPath($MinecraftDirectory)
$receiptPath = Join-Path $MinecraftDirectory 'horror-apocalypse-install.json'
$allowedFolders = @('mods', 'shaderpacks', 'resourcepacks')

function Assert-NoReparsePoint {
    param([string]$Path)
    $current = [IO.Path]::GetFullPath($Path)
    while ($current) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Refusing to use a symlink or junction: $current"
            }
        }
        $parent = [IO.Path]::GetDirectoryName($current.TrimEnd('\', '/'))
        if (-not $parent -or $parent -eq $current) { break }
        $current = $parent
    }
}

function Test-ValidFileName {
    param([string]$Name)
    return (-not [string]::IsNullOrWhiteSpace($Name)) -and
        $Name -notin @('.', '..') -and
        $Name -notmatch '[\\/]' -and
        $Name.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -lt 0
}

function Test-MatchingHash {
    param([string]$Path, [string]$Algorithm, [string]$Expected)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    Assert-NoReparsePoint -Path $Path
    $actual = (Get-FileHash -LiteralPath $Path -Algorithm $Algorithm).Hash
    return $actual.Equals($Expected, [StringComparison]::OrdinalIgnoreCase)
}

if (-not (Test-Path -LiteralPath $MinecraftDirectory -PathType Container)) {
    Write-Host "The client directory does not exist: $MinecraftDirectory"
    return
}
Assert-NoReparsePoint -Path $MinecraftDirectory
if (-not (Test-Path -LiteralPath $receiptPath -PathType Leaf)) {
    Write-Host "No POSLE installation receipt found in $MinecraftDirectory. Nothing was removed."
    return
}
Assert-NoReparsePoint -Path $receiptPath

$manifestPath = Join-Path $PSScriptRoot 'client-modpack.json'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw 'client-modpack.json is missing beside this script.'
}
$manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$historicalPath = Join-Path $PSScriptRoot 'historical\client-modpack-2026.10.11.4.json'
if (-not (Test-Path -LiteralPath $historicalPath -PathType Leaf)) {
    throw 'The pinned historical client manifest is missing.'
}
$historicalManifest = Get-Content -LiteralPath $historicalPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ($historicalManifest.pack -ne $manifest.pack -or
    $historicalManifest.pack_version -ne '2026.10.11.4') {
    throw 'The pinned historical client manifest has an unexpected identity.'
}
$animationPatchName = 'BornInChaosAnimationFix-local.zip'
$animationPatchEnabled = $null -ne $manifest.local_animation_patch
if ($animationPatchEnabled -and ($manifest.local_animation_patch.kind -cne 'born-in-chaos-1.7.5' -or
    $manifest.local_animation_patch.revision -ne 1)) {
    throw 'The local animation patch has an unexpected manifest identity.'
}
if ($manifest.pack_version -ceq '2026.10.11.7' -and -not $animationPatchEnabled) {
    throw 'The published v7 pack requires the local animation correction.'
}
$knownBornHashes = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
if ($animationPatchEnabled) {
$bornEntries = @($manifest.files | Where-Object {
    $_.project -eq 'born-in-chaos' -and $_.version -eq '1.7.5' -and
        $_.folder -eq 'mods' -and $_.filename -eq 'born_in_chaos_[Forge]1.20.1_1.7.5.jar' -and
        $_.hash_algorithm -eq 'SHA512'
})
if ($bornEntries.Count -ne 1) { throw 'The pinned Born in Chaos JAR identity is missing.' }
foreach ($knownManifest in @($manifest, $historicalManifest)) {
    foreach ($knownBorn in @($knownManifest.files | Where-Object {
        $_.project -eq 'born-in-chaos' -and $_.version -eq '1.7.5' -and
            $_.folder -eq 'mods' -and $_.filename -eq $bornEntries[0].filename -and
            $_.hash_algorithm -eq 'SHA512'
    })) { $knownBornHashes.Add($knownBorn.hash) | Out-Null }
}
}
$knownFiles = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($knownManifest in @($manifest, $historicalManifest)) {
    foreach ($known in @($knownManifest.files)) {
        if ($known.folder -notin $allowedFolders -or
            -not (Test-ValidFileName -Name $known.filename) -or
            $known.hash_algorithm -notin @('SHA256', 'SHA512') -or
            $known.hash -notmatch '^[0-9A-Fa-f]+$') {
            throw 'A pinned client manifest contains an unsafe file entry.'
        }
        $expectedLength = if ($known.hash_algorithm -eq 'SHA256') { 64 } else { 128 }
        if ($known.hash.Length -ne $expectedLength) {
            throw 'A pinned client manifest contains an invalid hash.'
        }
        $key = "$($known.folder)`0$($known.filename)`0$($known.hash_algorithm)`0$($known.hash)"
        $knownFiles.Add($key) | Out-Null
    }
}
try {
    $receipt = Get-Content -LiteralPath $receiptPath -Raw -Encoding UTF8 | ConvertFrom-Json
} catch {
    throw "The installation receipt cannot be read: $receiptPath"
}
if ($receipt.pack -ne $manifest.pack -or
    $receipt.minecraft_version -ne '1.20.1' -or
    $receipt.forge_version -ne '47.4.10') {
    throw 'The installation receipt does not identify this POSLE client pack.'
}
if ($receipt.minecraft_directory -isnot [string] -or
    -not [IO.Path]::IsPathRooted($receipt.minecraft_directory) -or
    -not [IO.Path]::GetFullPath($receipt.minecraft_directory).Equals(
        $MinecraftDirectory, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The installation receipt belongs to a different client directory.'
}
if ($null -eq $receipt.managed_files) {
    throw 'The installation receipt has no managed_files list.'
}

# Check the entire receipt and every path before the first deletion. A damaged
# receipt must never cause a partially completed removal.
$entries = @($receipt.managed_files)
if ($entries.Count -gt 1000) { throw 'The installation receipt has too many entries.' }
$seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($entry in $entries) {
    if ($entry.folder -isnot [string] -or $entry.folder -notin $allowedFolders -or
        $entry.filename -isnot [string] -or -not (Test-ValidFileName -Name $entry.filename) -or
        $entry.hash_algorithm -isnot [string] -or $entry.hash_algorithm -notin @('SHA256', 'SHA512') -or
        $entry.hash -isnot [string]) {
        throw 'The installation receipt contains an unsafe managed file entry.'
    }
    $expectedLength = if ($entry.hash_algorithm -eq 'SHA256') { 64 } else { 128 }
    if ($entry.hash.Length -ne $expectedLength -or $entry.hash -notmatch '^[0-9A-Fa-f]+$') {
        throw 'The installation receipt contains an invalid file hash.'
    }
    $relative = "$($entry.folder)/$($entry.filename)"
    if (-not $seen.Add($relative)) { throw "Duplicate managed file entry: $relative" }
    $key = "$($entry.folder)`0$($entry.filename)`0$($entry.hash_algorithm)`0$($entry.hash)"
    if ($animationPatchEnabled -and $relative -ceq "resourcepacks/$animationPatchName") {
        if ($entry.hash_algorithm -cne 'SHA256' -or $entry.generated_locally -cne $true -or
            $entry.created_by_posle -cne $true -or $receipt.animation_patch_revision -ne 1 -or
            -not $knownBornHashes.Contains([string]$receipt.animation_patch_source_sha512)) {
            throw 'The generated animation patch has an invalid receipt identity.'
        }
    } elseif (-not $knownFiles.Contains($key)) {
        throw "The receipt entry is absent from the pinned client manifests: $relative"
    }
    $ownershipProperty = $entry.PSObject.Properties['created_by_posle']
    if ($null -ne $ownershipProperty -and $ownershipProperty.Value -isnot [bool]) {
        throw "The receipt has an invalid ownership flag: $relative"
    }
    $folderPath = Join-Path $MinecraftDirectory $entry.folder
    Assert-NoReparsePoint -Path $folderPath
    $filePath = Join-Path $folderPath $entry.filename
    if (Test-Path -LiteralPath $filePath) { Assert-NoReparsePoint -Path $filePath }
}

if (-not $PSCmdlet.ShouldProcess($MinecraftDirectory,
        "Remove hash-matching receipt-listed POSLE files and update the receipt")) {
    return
}

$remaining = New-Object 'Collections.Generic.List[object]'
$removedCount = 0
foreach ($entry in $entries) {
    $relative = "$($entry.folder)/$($entry.filename)"
    $filePath = Join-Path (Join-Path $MinecraftDirectory $entry.folder) $entry.filename
    if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) { continue }
    Assert-NoReparsePoint -Path $filePath
    if ($entry.created_by_posle -cne $true) {
        Write-Warning "Preserved pre-existing or legacy unknown-ownership file: $relative"
        $remaining.Add($entry)
        continue
    }
    if (-not (Test-MatchingHash -Path $filePath -Algorithm $entry.hash_algorithm -Expected $entry.hash)) {
        Write-Warning "Preserved modified file: $relative"
        $remaining.Add($entry)
        continue
    }
    try {
        Assert-NoReparsePoint -Path $filePath
        Remove-Item -LiteralPath $filePath -Force -ErrorAction Stop
        $removedCount++
        Write-Host "Removed: $relative"
    } catch {
        Write-Warning "Could not remove $relative : $_"
        $remaining.Add($entry)
    }
}

if ($remaining.Count -eq 0) {
    Assert-NoReparsePoint -Path $receiptPath
    Remove-Item -LiteralPath $receiptPath -Force
    Write-Host "Removed $removedCount managed files and the installation receipt."
} else {
    $receipt.managed_files = @($remaining.ToArray())
    $temporary = Join-Path $MinecraftDirectory ('horror-apocalypse-install.' + [Guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $receipt | ConvertTo-Json -Depth 6 |
            Set-Content -LiteralPath $temporary -Encoding UTF8
        Assert-NoReparsePoint -Path $receiptPath
        Move-Item -LiteralPath $temporary -Destination $receiptPath -Force
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
    Write-Host "Removed $removedCount managed files; $($remaining.Count) modified or locked files remain recorded."
}
Write-Host 'Saves, options, other mods, Forge, Java, and the Minecraft instance directory were preserved.'
