param(
    [Parameter(Mandatory = $true)][string]$BornJarPath,
    [Parameter(Mandatory = $true)][string]$OutputZip,
    [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-fA-F]{128}$')][string]$ExpectedSha512
)

$ErrorActionPreference = 'Stop'
function Assert-NoReparsePoint {
    param([string]$Path)
    $current = [IO.Path]::GetFullPath($Path)
    while ($current) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Refusing to write the animation patch through a symlink or junction: $current"
            }
        }
        $parent = [IO.Path]::GetDirectoryName($current.TrimEnd('\', '/'))
        if (-not $parent -or $parent -eq $current) { break }
        $current = $parent
    }
}
$hashStream = [System.IO.File]::OpenRead($BornJarPath)
$sha512 = [System.Security.Cryptography.SHA512]::Create()
try { $actualHash = [System.BitConverter]::ToString($sha512.ComputeHash($hashStream)).Replace('-', '') }
finally {
    $sha512.Dispose()
    $hashStream.Dispose()
}
if ($actualHash -ne $ExpectedSha512) {
    throw 'Born in Chaos JAR does not match the pinned SHA-512 hash.'
}

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$patches = @(
    @{ Path = 'assets/born_in_chaos_v1/animations/babyskeleton.animation.json'; Count = 1 },
    @{ Path = 'assets/born_in_chaos_v1/animations/babyskeletondeamon.animation.json'; Count = 1 },
    @{ Path = 'assets/born_in_chaos_v1/animations/boneimp.animation.json'; Count = 1 },
    @{ Path = 'assets/born_in_chaos_v1/animations/scarletpersecutor.animation.json'; Count = 2 }
)

$outputFullPath = [System.IO.Path]::GetFullPath($OutputZip)
$destinationDirectory = [System.IO.Path]::GetDirectoryName($outputFullPath)
Assert-NoReparsePoint -Path $outputFullPath
[System.IO.Directory]::CreateDirectory($destinationDirectory) | Out-Null
Assert-NoReparsePoint -Path $outputFullPath
$temporaryZip = [System.IO.Path]::Combine($destinationDirectory, [System.IO.Path]::GetRandomFileName() + '.zip')
$utf8 = New-Object System.Text.UTF8Encoding($false)
$sourceZip = $null
$outputStream = $null
$patchZip = $null

try {
    $sourceZip = [System.IO.Compression.ZipFile]::OpenRead($BornJarPath)
    $outputStream = [System.IO.File]::Open($temporaryZip, [System.IO.FileMode]::CreateNew)
    $patchZip = New-Object System.IO.Compression.ZipArchive($outputStream, [System.IO.Compression.ZipArchiveMode]::Create, $true)

    $allEntries = @(@{ Path = 'pack.mcmeta'; Count = 0 }) + $patches
    foreach ($patch in $allEntries) {
        if ($patch.Path -eq 'pack.mcmeta') {
            $content = '{"pack":{"pack_format":15,"description":"Born in Chaos animation correction generated locally"}}'
        }
        else {
            $sourceEntry = $sourceZip.GetEntry($patch.Path)
            if ($null -eq $sourceEntry) { throw "Missing expected animation asset: $($patch.Path)" }
            $reader = New-Object System.IO.StreamReader($sourceEntry.Open(), $utf8, $true)
            try { $content = $reader.ReadToEnd() }
            finally { $reader.Dispose() }

            $matches = [regex]::Matches($content, '"-"')
            if ($matches.Count -ne $patch.Count) {
                throw "Unexpected malformed coordinate count in $($patch.Path): $($matches.Count)"
            }
            $content = [regex]::Replace($content, '"-"', '0')
            $null = $content | ConvertFrom-Json
        }

        $outputEntry = $patchZip.CreateEntry($patch.Path, [System.IO.Compression.CompressionLevel]::Optimal)
        # Stable ZIP metadata lets the installer recognize a correct existing
        # local pack without replacing it on every run.
        $outputEntry.LastWriteTime = [DateTimeOffset]::new(1980, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
        $writer = New-Object System.IO.StreamWriter($outputEntry.Open(), $utf8)
        try { $writer.Write($content) }
        finally { $writer.Dispose() }
    }
}
finally {
    if ($null -ne $patchZip) { $patchZip.Dispose() }
    if ($null -ne $outputStream) { $outputStream.Dispose() }
    if ($null -ne $sourceZip) { $sourceZip.Dispose() }
}

try {
    Assert-NoReparsePoint -Path $outputFullPath
    if (Test-Path -LiteralPath $outputFullPath) {
        $backupZip = [System.IO.Path]::Combine($destinationDirectory, [System.IO.Path]::GetRandomFileName() + '.bak')
        [System.IO.File]::Replace($temporaryZip, $outputFullPath, $backupZip)
        if (Test-Path -LiteralPath $backupZip) { Remove-Item -LiteralPath $backupZip -Force }
    }
    else {
        [System.IO.File]::Move($temporaryZip, $outputFullPath)
    }
}
finally {
    if (Test-Path -LiteralPath $temporaryZip) { Remove-Item -LiteralPath $temporaryZip -Force }
}

Write-Output "Created local animation patch: $outputFullPath"
