[CmdletBinding()]
param(
    [string]$MinecraftDirectory = (Join-Path $env:APPDATA '.minecraft-horror-apocalypse'),
    [ValidateSet('Auto', 'Low', 'Balanced', 'Cinematic')]
    [string]$GraphicsProfile = 'Auto',
    [switch]$NoShader,
    [switch]$NoResourcePack,
    [switch]$SkipForge,
    [switch]$LaunchTLauncher
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Add-Type -AssemblyName System.Net.Http
Add-Type -AssemblyName System.IO.Compression.FileSystem
$forgeReadinessPath = Join-Path $PSScriptRoot 'Forge-ClientReadiness.ps1'
if (-not (Test-Path -LiteralPath $forgeReadinessPath -PathType Leaf)) {
    throw 'Forge-ClientReadiness.ps1 is missing beside this script.'
}
. $forgeReadinessPath
$manifestPath = Join-Path $PSScriptRoot 'client-modpack.json'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw 'client-modpack.json is missing beside this script.'
}
$manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ($manifest.minecraft_version -ne '1.20.1' -or $manifest.forge_version -ne '47.4.10' -or $manifest.java_major -ne 17) {
    throw 'Unexpected Minecraft, Forge, or Java version in manifest.'
}
# SHA256 of bin/java.exe inside the pinned Corretto 17.0.20.12.1 archive.
$pinnedJavaExeSha256 = '1E1BE5FB92E33218323825B284C16377BDF10F7ED5CB4D30323F6B596EA45E5F'
if ($manifest.java_runtime.java_exe_sha256 -cne $pinnedJavaExeSha256) {
    throw 'Unexpected portable Java executable hash pin in manifest.'
}
$MinecraftDirectory = [System.IO.Path]::GetFullPath($MinecraftDirectory)
$receiptPath = Join-Path $MinecraftDirectory 'horror-apocalypse-install.json'
$allowedHosts = @('cdn.modrinth.com', 'www.curseforge.com', 'edge.forgecdn.net', 'mediafilez.forgecdn.net',
    'maven.minecraftforge.net', 'corretto.aws')
$allowedFolders = @('mods', 'shaderpacks', 'resourcepacks')
$historicalPath = Join-Path $PSScriptRoot 'historical\client-modpack-2026.10.11.4.json'
if (-not (Test-Path -LiteralPath $historicalPath -PathType Leaf)) {
    throw 'The pinned historical client manifest is missing beside this script.'
}
$historicalManifest = Get-Content -LiteralPath $historicalPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ($historicalManifest.pack -ne $manifest.pack -or
    $historicalManifest.pack_version -ne '2026.10.11.4') {
    throw 'The pinned historical client manifest has an unexpected identity.'
}

function Test-ValidFileName {
    param([string]$Name)
    return (-not [string]::IsNullOrWhiteSpace($Name)) -and
        $Name -notin @('.', '..') -and
        $Name -notmatch '[\\/]' -and
        $Name.IndexOfAny([System.IO.Path]::GetInvalidFileNameChars()) -lt 0
}

function Test-MatchingHash {
    param([string]$Path, [string]$Algorithm, [string]$Expected)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    $actual = (Get-FileHash -LiteralPath $Path -Algorithm $Algorithm).Hash
    return $actual.Equals($Expected, [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-AllowedDownloadUri {
    param([Uri]$Uri, [string[]]$AllowedHosts)
    if (-not $Uri.IsAbsoluteUri -or $Uri.Scheme -ne 'https' -or
        $Uri.Host -notin $AllowedHosts -or $Uri.UserInfo -or -not $Uri.IsDefaultPort) {
        throw "Untrusted download URL: $Uri"
    }
    return $Uri
}

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

Assert-NoReparsePoint -Path $MinecraftDirectory
Assert-NoReparsePoint -Path $receiptPath
if (Test-Path -LiteralPath $receiptPath -PathType Container) {
    throw "The installation receipt path is a directory: $receiptPath"
}
$previousInstall = Test-Path -LiteralPath $receiptPath -PathType Leaf
$previousReceipt = if ($previousInstall) {
    try { Get-Content -LiteralPath $receiptPath -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { throw "The previous installation receipt is invalid: $receiptPath" }
} else { $null }

function Save-AllowedDownload {
    param([string]$Url, [string]$Destination, [string[]]$AllowedHosts,
        [System.Net.Http.HttpClient]$Client, [long]$MaxBytes = 128MB,
        [TimeSpan]$BodyTimeout = [TimeSpan]::FromMinutes(15))
    if ($MaxBytes -le 0 -or $BodyTimeout -le [TimeSpan]::Zero) {
        throw 'Invalid download size or body timeout.'
    }
    # Automatic redirects can leave the approved host. Inspect every hop,
    # including relative Location headers, before sending the next request.
    $ownsClient = $null -eq $Client
    if ($ownsClient) {
        $handler = [System.Net.Http.HttpClientHandler]::new()
        $handler.AllowAutoRedirect = $false
        $Client = [System.Net.Http.HttpClient]::new($handler)
        $Client.Timeout = [TimeSpan]::FromMinutes(15)
    }
    try {
        $current = Get-AllowedDownloadUri -Uri ([Uri]$Url) -AllowedHosts $AllowedHosts
        for ($hop = 0; $hop -le 8; $hop++) {
            $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, $current)
            $response = $null
            try {
                $response = $Client.SendAsync($request, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
                $status = [int]$response.StatusCode
                if ($status -ge 300 -and $status -lt 400) {
                    if ($hop -eq 8 -or -not $response.Headers.Location) {
                        throw 'Download has too many redirects or a redirect without Location.'
                    }
                    $next = [Uri]::new($current, $response.Headers.Location)
                    $current = Get-AllowedDownloadUri -Uri $next -AllowedHosts $AllowedHosts
                    continue
                }
                $response.EnsureSuccessStatusCode() | Out-Null
                if ($null -ne $response.Content.Headers.ContentLength -and
                    $response.Content.Headers.ContentLength -gt $MaxBytes) {
                    throw 'Download exceeds the size limit.'
                }
                $source = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
                try {
                    $target = [System.IO.File]::Open($Destination, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write)
                    try {
                        $buffer = New-Object byte[] 65536
                        $readTimeout = [Threading.Tasks.Task]::Delay($BodyTimeout)
                        $cancellation = New-Object Threading.CancellationTokenSource
                        try {
                            $total = [long]0
                            while ($true) {
                                $read = $source.ReadAsync($buffer, 0, $buffer.Length, $cancellation.Token)
                                $pending = [Threading.Tasks.Task[]]@($read, $readTimeout)
                                $completed = [Threading.Tasks.Task]::WhenAny($pending).GetAwaiter().GetResult()
                                if (-not [object]::ReferenceEquals($completed, $read)) {
                                    $cancellation.Cancel()
                                    throw 'Download body timeout.'
                                }
                                $count = $read.GetAwaiter().GetResult()
                                if ($count -eq 0) { break }
                                $total += $count
                                if ($total -gt $MaxBytes) { throw 'Download exceeds the size limit.' }
                                $target.Write($buffer, 0, $count)
                            }
                        } finally { $cancellation.Dispose() }
                    } finally { $target.Dispose() }
                } finally { $source.Dispose() }
                return
            } finally {
                if ($response) { $response.Dispose() }
                $request.Dispose()
            }
        }
        throw 'Download exceeded the redirect limit.'
    } finally {
        if ($ownsClient) {
            $Client.Dispose()
            $handler.Dispose()
        }
    }
}

function Get-VerifiedFile {
    param([string]$Url, [string]$Destination, [string]$Algorithm, [string]$Expected,
        [long]$MaxBytes = 128MB)
    if ($Algorithm -notin @('SHA256', 'SHA512')) { throw "Invalid hash algorithm: $Algorithm" }
    Get-AllowedDownloadUri -Uri ([Uri]$Url) -AllowedHosts $allowedHosts | Out-Null
    if (Test-MatchingHash -Path $Destination -Algorithm $Algorithm -Expected $Expected) {
        Write-Host "OK  $(Split-Path -Leaf $Destination)"
        return
    }
    if (Test-Path -LiteralPath $Destination -PathType Leaf) {
        throw "Existing file has a different hash: $Destination. Move it out and retry."
    }
    $parent = Split-Path -Parent $Destination
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $temporary = Join-Path $parent ([Guid]::NewGuid().ToString('N') + '.download')
    Write-Host "GET $(Split-Path -Leaf $Destination)"
    try {
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            try {
                Save-AllowedDownload -Url $Url -Destination $temporary -AllowedHosts $allowedHosts -MaxBytes $MaxBytes
                break
            } catch {
                if ($attempt -eq 3) { throw }
                Start-Sleep -Seconds (2 * $attempt)
            }
        }
        if (-not (Test-MatchingHash -Path $temporary -Algorithm $Algorithm -Expected $Expected)) {
            throw "Hash check failed for $(Split-Path -Leaf $Destination)"
        }
        Move-Item -LiteralPath $temporary -Destination $Destination
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
}

function Get-ClientHardware {
    try {
        $system = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        $processors = @(Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop)
        $gpus = @(Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop)
        $cores = ($processors | Measure-Object -Property NumberOfCores -Sum).Sum
        if (-not $system.TotalPhysicalMemory -or -not $cores) {
            throw 'Missing RAM or CPU core count'
        }
        return [pscustomobject]@{
            RamGb = [double]$system.TotalPhysicalMemory / 1GB
            CpuCores = [int]$cores
            GpuNames = (($gpus | ForEach-Object { $_.Name }) -join ' ')
        }
    } catch {
        Write-Warning 'Hardware detection was unavailable; using a conservative graphics plan.'
        return $null
    }
}

function Get-AutoGraphicsProfile {
    param($Hardware)
    if (-not $Hardware) { return 'Low' }
    $ramGb = [double]$Hardware.RamGb
    $cpuCores = [int]$Hardware.CpuCores
    $gpuNames = [string]$Hardware.GpuNames
    $discreteGpu = $gpuNames -match 'GeForce|Radeon RX|Intel Arc|NVIDIA RTX'
    $olderGpu = $gpuNames -match 'GeForce GTX ([6-9][0-9]{2}|10[0-5]0|16[0-5]0)\b' -or
        $gpuNames -match 'Radeon RX [4-5][0-9]{2}\b|Intel Arc A3[0-9]{2}\b'
    if ($ramGb -lt 12 -or $cpuCores -lt 4 -or -not $discreteGpu -or $olderGpu) {
        return 'Low'
    }
    $strongGpu = $gpuNames -match 'GeForce RTX (30[7-9]0|40[7-9]0|50[7-9]0|60[7-9]0)\b' -or
        $gpuNames -match 'Radeon RX (67|68|69|77|78|79|87|88|89)[0-9]{2}\b'
    if ($ramGb -ge 24 -and $cpuCores -ge 6 -and $strongGpu) {
        return 'Cinematic'
    }
    return 'Balanced'
}

function Resolve-GraphicsProfile {
    param(
        [ValidateSet('Auto', 'Low', 'Balanced', 'Cinematic')][string]$RequestedProfile,
        $PreviousReceipt,
        $Hardware,
        [switch]$ExplicitChoice
    )
    if ($RequestedProfile -ne 'Auto') { return $RequestedProfile }
    if (-not $ExplicitChoice.IsPresent -and $PreviousReceipt -and
        $PreviousReceipt.graphics_profile -in @('Low', 'Balanced', 'Cinematic')) {
        return $PreviousReceipt.graphics_profile
    }
    return Get-AutoGraphicsProfile -Hardware $Hardware
}

function Get-GraphicsPlan {
    param(
        [ValidateSet('Low', 'Balanced', 'Cinematic')][string]$Profile,
        $Hardware,
        [switch]$NoShader
    )
    $gpuNames = if ($Hardware) { [string]$Hardware.GpuNames } else { '' }
    # The bundled DMS shader is listed as a low-end shader by its author, but
    # adapter names cannot prove OpenGL compatibility or actual frame rate.
    $shaderGpu = $gpuNames -match 'GeForce GTX (9[0-9]{2}|10[0-9]{2}|16[0-9]{2})\b|GeForce RTX|NVIDIA RTX|Radeon RX [5-9][0-9]{3}\b|Intel Arc'
    $enableShader = (-not $NoShader.IsPresent) -and $Hardware -and
        ([double]$Hardware.RamGb -ge 12) -and ([int]$Hardware.CpuCores -ge 4) -and $shaderGpu
    $video = switch ($Profile) {
        'Low' { [ordered]@{ renderDistance='6'; simulationDistance='5'; graphicsMode='0'; particles='2'; entityShadows='false'; entityDistanceScaling='0.5'; mipmapLevels='2'; maxFps='60'; gamma='0.0' } }
        'Balanced' { [ordered]@{ renderDistance='8'; simulationDistance='6'; graphicsMode='1'; particles='1'; entityShadows='false'; entityDistanceScaling='0.75'; mipmapLevels='4'; maxFps='90'; gamma='0.0' } }
        'Cinematic' { [ordered]@{ renderDistance='8'; simulationDistance='6'; graphicsMode='1'; particles='0'; entityShadows='true'; entityDistanceScaling='1.0'; mipmapLevels='4'; maxFps='120'; gamma='0.0' } }
    }
    $shadowDistance = switch ($Profile) { 'Low' { '4' } 'Balanced' { '6' } 'Cinematic' { '8' } }
    return [pscustomobject]@{
        VideoSettings = $video
        OculusSettings = [ordered]@{
            shaderPack = 'DMS 1.0.3.zip'
            enableShaders = ([bool]$enableShader).ToString().ToLowerInvariant()
            maxShadowRenderDistance = $shadowDistance
        }
    }
}

function Update-KeyValueFile {
    param([string]$Path, [string]$Separator, [System.Collections.IDictionary]$Values)
    $existing = if (Test-Path -LiteralPath $Path -PathType Leaf) { @(Get-Content -LiteralPath $Path -Encoding UTF8) } else { @() }
    if ($existing.Count -gt 0) {
        $backup = "$Path.horror-backup"
        if (-not (Test-Path -LiteralPath $backup)) { Copy-Item -LiteralPath $Path -Destination $backup }
    }
    $written = @{}
    $result = New-Object 'System.Collections.Generic.List[string]'
    foreach ($line in $existing) {
        $position = $line.IndexOf($Separator)
        if ($position -gt 0) {
            $key = $line.Substring(0, $position)
            if ($Values.Contains($key)) {
                if (-not $written.ContainsKey($key)) { $result.Add("$key$Separator$($Values[$key])") }
                $written[$key] = $true
                continue
            }
        }
        $result.Add($line)
    }
    foreach ($key in $Values.Keys) {
        if (-not $written.ContainsKey($key)) { $result.Add("$key$Separator$($Values[$key])") }
    }
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    [System.IO.File]::WriteAllLines($Path, $result.ToArray(), (New-Object System.Text.UTF8Encoding($false)))
}

function Update-ResourcePackSelection {
    param([string]$Path, [string[]]$RemoveIds, [string[]]$AddIds)
    $existingLine = @()
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $existingLine = @(Get-Content -LiteralPath $Path -Encoding UTF8 | Where-Object { $_ -like 'resourcePacks:*' } | Select-Object -First 1)
    }
    $selected = New-Object 'System.Collections.Generic.List[string]'
    if ($existingLine.Count -eq 0) {
        $selected.Add('vanilla')
    } else {
        try {
            $parsed = ConvertFrom-Json -InputObject $existingLine[0].Substring('resourcePacks:'.Length)
        } catch {
            throw "Cannot read the existing resource pack selection in $Path. Back it up and repair it before updating."
        }
        foreach ($packId in @($parsed)) {
            if ($packId -isnot [string]) { throw "Unexpected resource pack entry in $Path" }
            if ($packId -notin $RemoveIds) { $selected.Add($packId) }
        }
    }
    foreach ($addId in $AddIds) {
        if ($addId -and -not $selected.Contains($addId)) { $selected.Add($addId) }
    }
    $value = ConvertTo-Json -InputObject $selected.ToArray() -Compress
    Update-KeyValueFile -Path $Path -Separator ':' -Values ([ordered]@{ resourcePacks = $value })
}

function Get-ForgeModIds {
    param([string]$Path)
    $archive = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $metadata = $archive.GetEntry('META-INF/mods.toml')
        if (-not $metadata) { return @() }
        if ($metadata.Length -gt 1MB) { throw "Mod metadata is too large: $Path" }
        $reader = New-Object IO.StreamReader($metadata.Open())
        try { $lines = $reader.ReadToEnd() -split "`r?`n" }
        finally { $reader.Dispose() }
        $inModSection = $false
        $ids = New-Object 'System.Collections.Generic.List[string]'
        foreach ($line in $lines) {
            if ($line -match '^\s*\[\[\s*mods\s*\]\]') {
                $inModSection = $true
                continue
            }
            if ($line -match '^\s*\[\[') {
                $inModSection = $false
                continue
            }
            if ($inModSection -and $line -match '^\s*modId\s*=\s*(["''])([^"'']+)\1') {
                $ids.Add($Matches[2])
            }
        }
        return @($ids.ToArray())
    } finally { $archive.Dispose() }
}

function Assert-CreatureModSet {
    param([object[]]$Candidates, [object[]]$ObsoleteFiles, [string]$ClientRoot)
    $projectIds = [ordered]@{
        pehkui = 'pehkui'
        'mutant-monsters' = 'mutantmonsters'
        'puzzles-lib' = 'puzzleslib'
    }
    $creatureEntries = @($Candidates | Where-Object { $_.Entry.project -in @($projectIds.Keys) })
    if ($creatureEntries.Count -eq 0) { return }
    foreach ($project in $projectIds.Keys) {
        $matches = @($creatureEntries | Where-Object { $_.Entry.project -ceq $project })
        if ($matches.Count -gt 0 -and ($matches.Count -ne 1 -or $matches[0].Entry.folder -ne 'mods')) {
            throw "Creature pack has an invalid client mod entry: $project"
        }
    }
    if (@($creatureEntries | Where-Object { $_.Entry.project -ceq 'mutant-monsters' }).Count -gt 0) {
        foreach ($dependency in @('pehkui', 'puzzles-lib')) {
            if (@($creatureEntries | Where-Object { $_.Entry.project -ceq $dependency }).Count -ne 1) {
                throw "Mutant Monsters needs exactly one client mod: $dependency"
            }
        }
    }
    $plannedPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $retiredPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $newIds = @{}
    foreach ($old in $ObsoleteFiles) { $retiredPaths.Add($old.Path) | Out-Null }
    foreach ($candidate in $Candidates) {
        $plannedPaths.Add($candidate.Destination) | Out-Null
        if ($candidate.Entry.folder -ne 'mods') { continue }
        try { $ids = @(Get-ForgeModIds -Path $candidate.Source) }
        catch { throw "Cannot inspect Forge metadata in $($candidate.Entry.filename): $($_.Exception.Message)" }
        if ($projectIds.Contains($candidate.Entry.project) -and
            $projectIds[$candidate.Entry.project] -notin $ids) {
            throw "Wrong Forge modId in $($candidate.Entry.filename): expected $($projectIds[$candidate.Entry.project])"
        }
        foreach ($id in $ids) {
            if ($newIds.ContainsKey($id)) { throw "Duplicate modId in client manifest: $id" }
            $newIds[$id] = $candidate.Entry.filename
        }
    }
    $modsDirectory = Join-Path $ClientRoot 'mods'
    if (-not (Test-Path -LiteralPath $modsDirectory -PathType Container)) { return }
    Assert-NoReparsePoint -Path $modsDirectory
    foreach ($existing in @(Get-ChildItem -LiteralPath $modsDirectory -Filter '*.jar' -File)) {
        if ($plannedPaths.Contains($existing.FullName) -or $retiredPaths.Contains($existing.FullName)) { continue }
        Assert-NoReparsePoint -Path $existing.FullName
        try { $ids = @(Get-ForgeModIds -Path $existing.FullName) }
        catch { throw "Cannot inspect existing mod JAR $($existing.Name): $($_.Exception.Message)" }
        foreach ($id in $ids) {
            if ($newIds.ContainsKey($id)) {
                throw "Existing JAR $($existing.Name) conflicts with $($newIds[$id]) (modId $id). Move the older JAR out manually."
            }
        }
    }
}

# Current and previously published manifests are the only file identities the
# installer may claim in a receipt or remove during an update.
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
        $knownFiles.Add("$($known.folder)`0$($known.filename)`0$($known.hash_algorithm)`0$($known.hash)") | Out-Null
    }
}
$previousOwnership = @{}
if ($previousReceipt) {
    if ($previousReceipt.pack -ne $manifest.pack -or
        $previousReceipt.minecraft_directory -isnot [string] -or
        -not [IO.Path]::IsPathRooted($previousReceipt.minecraft_directory) -or
        -not [IO.Path]::GetFullPath($previousReceipt.minecraft_directory).Equals(
            $MinecraftDirectory, [StringComparison]::OrdinalIgnoreCase) -or
        $null -eq $previousReceipt.managed_files) {
        throw 'The previous installation receipt has an unexpected identity.'
    }
    foreach ($old in @($previousReceipt.managed_files)) {
        if ($old.folder -notin $allowedFolders -or
            -not (Test-ValidFileName -Name $old.filename) -or
            $old.hash_algorithm -notin @('SHA256', 'SHA512') -or
            $old.hash -notmatch '^[0-9A-Fa-f]+$') {
            throw 'The previous installation receipt contains an unsafe file entry.'
        }
        $key = "$($old.folder)`0$($old.filename)`0$($old.hash_algorithm)`0$($old.hash)"
        if (-not $knownFiles.Contains($key) -or $previousOwnership.ContainsKey($key)) {
            throw 'The previous installation receipt has an unknown or duplicate file identity.'
        }
        $ownershipProperty = $old.PSObject.Properties['created_by_posle']
        if ($null -ne $ownershipProperty -and $ownershipProperty.Value -isnot [bool]) {
            throw 'The previous installation receipt has an invalid ownership flag.'
        }
        # The published v5 receipt lacks this field. Its ownership is unknown.
        $previousOwnership[$key] = ($old.created_by_posle -ceq $true)
    }
}

Assert-NoReparsePoint -Path $MinecraftDirectory
if (@($manifest.files).Count -eq 0) { throw 'Client manifest has no files.' }
$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$stageRoot = [IO.Path]::GetFullPath((Join-Path $tempRoot ('posle-client-stage-' + [Guid]::NewGuid().ToString('N'))))
if (-not $stageRoot.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or
    -not (Split-Path -Leaf $stageRoot).StartsWith('posle-client-stage-')) {
    throw 'Unsafe client staging directory.'
}
New-Item -ItemType Directory -Path $stageRoot -Force | Out-Null
try {
$hardware = Get-ClientHardware
$resolvedProfile = Resolve-GraphicsProfile -RequestedProfile $GraphicsProfile -PreviousReceipt $previousReceipt `
    -Hardware $hardware -ExplicitChoice:($PSBoundParameters.ContainsKey('GraphicsProfile'))
Write-Host "Graphics profile: $resolvedProfile"
$managedFiles = New-Object 'System.Collections.Generic.List[object]'
$candidateFiles = New-Object 'System.Collections.Generic.List[object]'
$targetPaths = @{}
foreach ($entry in @($manifest.files)) {
    if ($entry.folder -notin $allowedFolders) { throw "Unexpected folder: $($entry.folder)" }
    if (-not (Test-ValidFileName -Name $entry.filename)) { throw "Invalid file name: $($entry.filename)" }
    if ($NoShader -and $entry.folder -eq 'shaderpacks') { continue }
    if ($NoResourcePack -and $entry.folder -eq 'resourcepacks') { continue }
    $destination = Join-Path (Join-Path $MinecraftDirectory $entry.folder) $entry.filename
    Assert-NoReparsePoint -Path $destination
    Get-AllowedDownloadUri -Uri ([Uri]$entry.url) -AllowedHosts $allowedHosts | Out-Null
    if (Test-Path -LiteralPath $destination -PathType Container) {
        throw "A directory occupies the required client file path: $destination"
    }
    $existedBefore = Test-Path -LiteralPath $destination -PathType Leaf
    if ($existedBefore) {
        if (-not (Test-MatchingHash -Path $destination -Algorithm $entry.hash_algorithm -Expected $entry.hash)) {
            throw "Existing file has a different hash: $destination. Move it out and retry."
        }
        $source = $destination
    } else {
        $source = Join-Path (Join-Path (Join-Path $stageRoot 'downloads') $entry.folder) $entry.filename
        Get-VerifiedFile -Url $entry.url -Destination $source -Algorithm $entry.hash_algorithm -Expected $entry.hash
        if (-not (Test-MatchingHash -Path $source -Algorithm $entry.hash_algorithm -Expected $entry.hash)) {
            throw "Staged download failed hash verification: $($entry.filename)"
        }
    }
    $relativePath = "$($entry.folder)/$($entry.filename)"
    if ($targetPaths.ContainsKey($relativePath)) { throw "Duplicate file in client manifest: $relativePath" }
    $targetPaths[$relativePath] = $true
    $candidateFiles.Add([pscustomobject]@{
        Entry = $entry; Destination = $destination; Source = $source
        ExistedBefore = $existedBefore; RelativePath = $relativePath
    })
    $managedFiles.Add([ordered]@{
        folder = $entry.folder
        filename = $entry.filename
        hash_algorithm = $entry.hash_algorithm
        hash = $entry.hash
        default_enabled = ($entry.folder -eq 'resourcepacks' -and $entry.default_enabled -eq $true)
        created_by_posle = ((-not $existedBefore) -or
            ($previousOwnership["$($entry.folder)`0$($entry.filename)`0$($entry.hash_algorithm)`0$($entry.hash)"] -eq $true))
    })
}

# The earliest migration had no ownership field or pinned manifest. Its file
# may have been present before POSLE, so require the player to resolve it.
$oldFlashier = Join-Path (Join-Path $MinecraftDirectory 'mods') 'Flashier Flashlights 1.2.0.jar'
if (Test-Path -LiteralPath $oldFlashier) {
    throw "Legacy Flashier Flashlights ownership cannot be verified: $oldFlashier. Move it out manually before joining the updated server."
}

# Validate every obsolete file before changing any managed content. Unknown
# ownership and player modifications remain untouched.
$obsoleteFiles = New-Object 'System.Collections.Generic.List[object]'
foreach ($old in @($previousReceipt.managed_files | Where-Object { $null -ne $_ })) {
    $relativePath = "$($old.folder)/$($old.filename)"
    if ($targetPaths.ContainsKey($relativePath)) { continue }
    $oldPath = Join-Path (Join-Path $MinecraftDirectory $old.folder) $old.filename
    if (-not (Test-Path -LiteralPath $oldPath -PathType Leaf)) { continue }
    Assert-NoReparsePoint -Path $oldPath
    if ($old.created_by_posle -cne $true) {
        Write-Warning "Preserved pre-existing or legacy unknown-ownership file: $relativePath"
        continue
    }
    if (-not (Test-MatchingHash -Path $oldPath -Algorithm $old.hash_algorithm -Expected $old.hash)) {
        throw "An old managed file has changed: $oldPath. Move it out before updating."
    }
    $obsoleteFiles.Add([pscustomobject]@{ Entry = $old; Path = $oldPath; RelativePath = $relativePath })
}
Assert-CreatureModSet -Candidates $candidateFiles.ToArray() -ObsoleteFiles $obsoleteFiles.ToArray() -ClientRoot $MinecraftDirectory

$forgeVersionId = '1.20.1-forge-47.4.10'
$forgeReady = Test-ForgeReady -ClientRoot $MinecraftDirectory -VersionId $forgeVersionId
$runtimeDirectory = Join-Path $MinecraftDirectory 'runtime'
$javaPath = Join-Path (Join-Path $runtimeDirectory $manifest.java_runtime.directory) 'bin\java.exe'
Assert-NoReparsePoint -Path $javaPath
$javaReady = Test-MatchingHash -Path $javaPath -Algorithm 'SHA256' -Expected $pinnedJavaExeSha256
if (-not $SkipForge -and (-not $forgeReady -or -not $javaReady)) {
    if (-not $javaReady) {
        $javaArchive = Join-Path $stageRoot 'amazon-corretto-17-windows-x64-jdk.zip'
        Get-VerifiedFile -Url $manifest.java_runtime.url -Destination $javaArchive -Algorithm 'SHA256' -Expected $manifest.java_runtime.sha256 -MaxBytes 256MB
        if (-not (Test-MatchingHash -Path $javaArchive -Algorithm 'SHA256' -Expected $manifest.java_runtime.sha256)) {
            throw 'Portable Java archive failed hash verification.'
        }
    }
    if (-not $forgeReady) {
        $installer = Join-Path $stageRoot 'forge-1.20.1-47.4.10-installer.jar'
        Get-VerifiedFile -Url $manifest.forge_installer.url -Destination $installer -Algorithm 'SHA256' -Expected $manifest.forge_installer.sha256
        if (-not (Test-MatchingHash -Path $installer -Algorithm 'SHA256' -Expected $manifest.forge_installer.sha256)) {
            throw 'Forge installer failed hash verification.'
        }
    }

    # Repair the dedicated runtime after pack preflight. The archive and the
    # extracted java.exe are pinned, including on a rerun with valid Forge.
    Assert-NoReparsePoint -Path $MinecraftDirectory
    New-Item -ItemType Directory -Path $MinecraftDirectory -Force | Out-Null
    if (-not $javaReady) {
        Assert-NoReparsePoint -Path $runtimeDirectory
        Assert-NoReparsePoint -Path $javaPath
        Write-Host 'Installing or repairing portable Java 17...'
        New-Item -ItemType Directory -Path $runtimeDirectory -Force | Out-Null
        Expand-Archive -LiteralPath $javaArchive -DestinationPath $runtimeDirectory -Force
        if (-not (Test-Path -LiteralPath $javaPath -PathType Leaf)) { throw 'Portable Java 17 archive has an unexpected layout.' }
    }
    Assert-NoReparsePoint -Path $javaPath
    if (-not (Test-MatchingHash -Path $javaPath -Algorithm 'SHA256' -Expected $pinnedJavaExeSha256)) {
        throw 'Portable Java executable hash mismatch.'
    }
    if (-not $forgeReady) {
        # The official Forge installer writes into these subdirectories and
        # files; never let a junction redirect it into another game folder.
        foreach ($path in @(
            (Join-Path $MinecraftDirectory 'versions'),
            (Join-Path $MinecraftDirectory 'libraries'),
            (Join-Path $MinecraftDirectory 'assets'),
            (Join-Path $MinecraftDirectory 'launcher_profiles.json'),
            (Join-Path $MinecraftDirectory 'forge-client-install.log')
        )) { Assert-NoReparsePoint -Path $path }
        $profilesPath = Join-Path $MinecraftDirectory 'launcher_profiles.json'
        if (-not (Test-Path -LiteralPath $profilesPath -PathType Leaf)) {
            [System.IO.File]::WriteAllText($profilesPath, '{"profiles":{},"settings":{}}', (New-Object System.Text.UTF8Encoding($false)))
        }
        $logPath = Join-Path $MinecraftDirectory 'forge-client-install.log'
        Write-Host 'Installing official Forge 47.4.10 client (this can take a few minutes)...'
        Push-Location $MinecraftDirectory
        try {
            & $javaPath -jar $installer --installClient $MinecraftDirectory *> $logPath
            $forgeExitCode = $LASTEXITCODE
        } finally {
            Pop-Location
        }
        if ($forgeExitCode -ne 0 -or -not (Test-ForgeReady -ClientRoot $MinecraftDirectory -VersionId $forgeVersionId)) {
            Get-Content -LiteralPath $logPath -Tail 20 | ForEach-Object { Write-Host $_ }
            throw "Forge client installation failed (exit code $forgeExitCode). See $logPath"
        }
        $forgeReady = $true
    }
}

# Keep a recoverable copy of every installer-managed setting before the first
# pack mutation. Backups live outside the client root and are hash checked.
Assert-NoReparsePoint -Path $MinecraftDirectory
New-Item -ItemType Directory -Path $MinecraftDirectory -Force | Out-Null
$settingsPaths = @(
    (Join-Path $MinecraftDirectory 'options.txt'),
    (Join-Path $MinecraftDirectory 'options.txt.horror-backup'),
    (Join-Path $MinecraftDirectory 'config\oculus.properties'),
    (Join-Path $MinecraftDirectory 'config\oculus.properties.horror-backup'),
    $receiptPath
)
$settingsBackups = New-Object 'System.Collections.Generic.List[object]'
for ($index = 0; $index -lt $settingsPaths.Count; $index++) {
    $path = $settingsPaths[$index]
    Assert-NoReparsePoint -Path $path
    $existed = Test-Path -LiteralPath $path -PathType Leaf
    $backup = Join-Path $stageRoot "settings-$index.backup"
    if ($existed) {
        Copy-Item -LiteralPath $path -Destination $backup
        $originalHash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        if (-not (Test-MatchingHash -Path $backup -Algorithm 'SHA256' -Expected $originalHash)) {
            throw "Could not back up client setting: $path"
        }
    }
    $settingsBackups.Add([pscustomobject]@{ Path = $path; Backup = $backup; Existed = $existed })
}
$createdFiles = New-Object 'System.Collections.Generic.List[object]'
$obsoleteBackups = New-Object 'System.Collections.Generic.List[object]'
$temporaryFiles = New-Object 'System.Collections.Generic.List[string]'
try {
    foreach ($candidate in $candidateFiles) {
        if ($candidate.ExistedBefore) { continue }
        $destination = $candidate.Destination
        $parent = Split-Path -Parent $destination
        Assert-NoReparsePoint -Path $destination
        if (Test-Path -LiteralPath $destination) { throw "Client file appeared during update: $destination" }
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
        $temporary = Join-Path $parent ('.posle-' + [Guid]::NewGuid().ToString('N') + '.tmp')
        $temporaryFiles.Add($temporary)
        Copy-Item -LiteralPath $candidate.Source -Destination $temporary
        if (-not (Test-MatchingHash -Path $temporary -Algorithm $candidate.Entry.hash_algorithm -Expected $candidate.Entry.hash)) {
            throw "Copy failed hash verification: $($candidate.Entry.filename)"
        }
        Assert-NoReparsePoint -Path $destination
        if (Test-Path -LiteralPath $destination) { throw "Client file appeared during update: $destination" }
        Move-Item -LiteralPath $temporary -Destination $destination
        $createdFiles.Add($candidate)
    }
    foreach ($obsolete in $obsoleteFiles) {
        $path = $obsolete.Path
        Assert-NoReparsePoint -Path $path
        if (-not (Test-MatchingHash -Path $path -Algorithm $obsolete.Entry.hash_algorithm -Expected $obsolete.Entry.hash)) {
            throw "Old managed file changed during update: $path"
        }
        $backup = Join-Path (Join-Path (Join-Path $stageRoot 'obsolete') $obsolete.Entry.folder) $obsolete.Entry.filename
        New-Item -ItemType Directory -Path (Split-Path -Parent $backup) -Force | Out-Null
        Copy-Item -LiteralPath $path -Destination $backup
        if (-not (Test-MatchingHash -Path $backup -Algorithm $obsolete.Entry.hash_algorithm -Expected $obsolete.Entry.hash)) {
            throw "Could not back up old managed file: $path"
        }
        Assert-NoReparsePoint -Path $path
        $obsoleteBackups.Add([pscustomobject]@{
            Path = $path; Backup = $backup; RelativePath = $obsolete.RelativePath; Entry = $obsolete.Entry
        })
        Remove-Item -LiteralPath $path -Force
        Write-Host "Removed obsolete pack file: $($obsolete.RelativePath)"
    }

$applyVideoProfile = (-not $previousInstall) -or $PSBoundParameters.ContainsKey('GraphicsProfile') -or
    $previousReceipt.pack_version -ne $manifest.pack_version
$applyOculus = $applyVideoProfile -or $NoShader.IsPresent -or
    ($previousReceipt.no_shader -eq $true -and -not $NoShader.IsPresent)
if ($applyVideoProfile -or $applyOculus) {
    $graphicsPlan = Get-GraphicsPlan -Profile $resolvedProfile -Hardware $hardware -NoShader:$NoShader
    if ($applyVideoProfile) {
        Update-KeyValueFile -Path (Join-Path $MinecraftDirectory 'options.txt') -Separator ':' -Values $graphicsPlan.VideoSettings
    }
    if ($applyOculus) {
        Update-KeyValueFile -Path (Join-Path $MinecraftDirectory 'config\oculus.properties') -Separator '=' -Values $graphicsPlan.OculusSettings
    }
}

$defaultResourcePacks = @($manifest.files | Where-Object {
    $_.folder -eq 'resourcepacks' -and $_.default_enabled -eq $true
})
$previousResourcePacks = @($previousReceipt.managed_files | Where-Object {
    $null -ne $_ -and $_.folder -eq 'resourcepacks'
})
$newDefaultResourcePack = $false
foreach ($pack in $defaultResourcePacks) {
    $currentName = $pack.filename
    if (@($previousResourcePacks | Where-Object {
        $_.filename -eq $currentName -and $_.default_enabled -eq $true
    }).Count -eq 0) {
        $newDefaultResourcePack = $true
        break
    }
}
$obsoleteResourcePacks = @($previousResourcePacks | Where-Object {
    -not $targetPaths.ContainsKey("resourcepacks/$($_.filename)")
})
$refreshResourcePacks = (-not $previousInstall) -or $PSBoundParameters.ContainsKey('GraphicsProfile') -or
    $NoResourcePack.IsPresent -or $newDefaultResourcePack -or $obsoleteResourcePacks.Count -gt 0
if ($refreshResourcePacks -and ($defaultResourcePacks.Count -gt 0 -or $previousResourcePacks.Count -gt 0)) {
    $removeIds = @($previousResourcePacks | Where-Object {
        $_.default_enabled -eq $true -or $NoResourcePack.IsPresent -or
            -not $targetPaths.ContainsKey("resourcepacks/$($_.filename)")
    } | ForEach-Object { "file/$($_.filename)" })
    $defaultIds = @($defaultResourcePacks | ForEach-Object { "file/$($_.filename)" })
    $removeIds += $defaultIds
    $addIds = if ($NoResourcePack.IsPresent) { @() } else { $defaultIds }
    Update-ResourcePackSelection -Path (Join-Path $MinecraftDirectory 'options.txt') -RemoveIds $removeIds -AddIds $addIds
}

# Existing files were checked during preflight; recheck them and newly copied
# files immediately before claiming a successful installation in the receipt.
foreach ($candidate in $candidateFiles) {
    Assert-NoReparsePoint -Path $candidate.Destination
    if (-not (Test-MatchingHash -Path $candidate.Destination -Algorithm $candidate.Entry.hash_algorithm -Expected $candidate.Entry.hash)) {
        throw "Client file changed during update: $($candidate.RelativePath)"
    }
}

$receipt = [ordered]@{
    pack = $manifest.pack
    pack_version = $manifest.pack_version
    minecraft_version = $manifest.minecraft_version
    forge_version = $manifest.forge_version
    installed_at = (Get-Date).ToString('o')
    minecraft_directory = $MinecraftDirectory
    graphics_profile = $resolvedProfile
    no_shader = $NoShader.IsPresent
    forge_installed = $forgeReady
    shader_installed = (Test-Path -LiteralPath (Join-Path $MinecraftDirectory 'shaderpacks\DMS 1.0.3.zip') -PathType Leaf)
    managed_files = @($managedFiles.ToArray())
}
$receiptTemporary = Join-Path $MinecraftDirectory ('.posle-receipt-' + [Guid]::NewGuid().ToString('N') + '.tmp')
$temporaryFiles.Add($receiptTemporary)
$receipt | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $receiptTemporary -Encoding UTF8
Assert-NoReparsePoint -Path $receiptPath
Move-Item -LiteralPath $receiptTemporary -Destination $receiptPath -Force
} catch {
    $originalError = $_
    $rollbackErrors = New-Object 'System.Collections.Generic.List[string]'
    foreach ($created in $createdFiles) {
        try {
            if (Test-Path -LiteralPath $created.Destination -PathType Leaf) {
                Assert-NoReparsePoint -Path $created.Destination
                if (-not (Test-MatchingHash -Path $created.Destination -Algorithm $created.Entry.hash_algorithm -Expected $created.Entry.hash)) {
                    throw 'New file changed during rollback; preserved it for manual recovery.'
                }
                Remove-Item -LiteralPath $created.Destination -Force
            }
        } catch { $rollbackErrors.Add("$($created.RelativePath): $($_.Exception.Message)") }
    }
    foreach ($retired in $obsoleteBackups) {
        try {
            Assert-NoReparsePoint -Path $retired.Path
            if (-not (Test-Path -LiteralPath $retired.Path)) {
                Copy-Item -LiteralPath $retired.Backup -Destination $retired.Path
            }
            if (-not (Test-MatchingHash -Path $retired.Path -Algorithm $retired.Entry.hash_algorithm -Expected $retired.Entry.hash)) {
                throw 'Restored old file failed hash verification.'
            }
        } catch { $rollbackErrors.Add("$($retired.RelativePath): $($_.Exception.Message)") }
    }
    foreach ($snapshot in $settingsBackups) {
        try {
            Assert-NoReparsePoint -Path $snapshot.Path
            if ($snapshot.Existed) {
                if (Test-Path -LiteralPath $snapshot.Path -PathType Container) { throw 'Setting path became a directory.' }
                Copy-Item -LiteralPath $snapshot.Backup -Destination $snapshot.Path -Force
            } elseif (Test-Path -LiteralPath $snapshot.Path -PathType Leaf) {
                Remove-Item -LiteralPath $snapshot.Path -Force
            }
        } catch { $rollbackErrors.Add("$(Split-Path -Leaf $snapshot.Path): $($_.Exception.Message)") }
    }
    foreach ($temporary in $temporaryFiles) {
        try {
            if (Test-Path -LiteralPath $temporary -PathType Leaf) {
                Assert-NoReparsePoint -Path $temporary
                Remove-Item -LiteralPath $temporary -Force
            }
        } catch { $rollbackErrors.Add("temporary file: $($_.Exception.Message)") }
    }
    if ($rollbackErrors.Count -gt 0) {
        $preserveStage = $true
        throw "Client update failed: $($originalError.Exception.Message). Rollback needs manual repair: $($rollbackErrors -join '; '). Backups: $stageRoot"
    }
    throw "Client update failed and managed files were rolled back: $($originalError.Exception.Message)"
}
Write-Host ''
Write-Host "Client pack files installed: $MinecraftDirectory"
if ($forgeReady) { Write-Host "Forge bootstrap files verified: $forgeVersionId" }
Write-Host 'In TLauncher, choose this game directory and the Forge 1.20.1 / 47.4.10 version.'
Write-Host 'On first launch, TLauncher may download vanilla version metadata and game assets.'
Write-Host 'The installer has not verified a game launch or server connection.'
Write-Host 'DynamicRenderDistance adjusts view distance in play; use F8 to set a maximum of 8 chunks.'
Write-Host "Server address: $($manifest.server_address)"

if ($LaunchTLauncher) {
    $candidates = @(
        (Join-Path $env:APPDATA '.minecraft\TLauncher.exe'),
        (Join-Path $env:APPDATA '.tlauncher\TLauncher.exe'),
        (Join-Path $env:LOCALAPPDATA 'TLauncher\TLauncher.exe')
    )
    $tlauncher = $null
    foreach ($candidate in $candidates) {
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
        $signature = Get-AuthenticodeSignature -LiteralPath $candidate
        if ($signature.Status -eq 'Valid' -and
            $signature.SignerCertificate.Subject -match '(^|, )O=TLauncher Inc\.(,|$)') {
            $tlauncher = $candidate
            break
        }
        Write-Warning "TLauncher candidate was not started because its publisher signature could not be verified: $candidate"
    }
    if ($tlauncher) {
        Start-Process -FilePath $tlauncher -WorkingDirectory (Split-Path -Parent $tlauncher) -WindowStyle Normal
        Write-Host 'TLauncher opened. Select the game directory shown above and Forge 1.20.1 / 47.4.10 in its window.'
    } else {
        Write-Warning 'A signed TLauncher.exe was not found. Open your Minecraft launcher manually.'
    }
}
} finally {
    if (-not $preserveStage -and (Test-Path -LiteralPath $stageRoot)) {
        $resolvedStage = [IO.Path]::GetFullPath($stageRoot)
        if (-not $resolvedStage.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or
            -not (Split-Path -Leaf $resolvedStage).StartsWith('posle-client-stage-')) {
            throw 'Refusing to remove staging outside the expected temp scope.'
        }
        Assert-NoReparsePoint -Path $resolvedStage
        Remove-Item -LiteralPath $resolvedStage -Recurse -Force
    }
}
