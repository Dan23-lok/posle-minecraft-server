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
$manifestPath = Join-Path $PSScriptRoot 'client-modpack.json'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw 'client-modpack.json is missing beside this script.'
}
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
if ($manifest.minecraft_version -ne '1.20.1' -or $manifest.forge_version -ne '47.4.10' -or $manifest.java_major -ne 17) {
    throw 'Unexpected Minecraft, Forge, or Java version in manifest.'
}
$MinecraftDirectory = [System.IO.Path]::GetFullPath($MinecraftDirectory)
New-Item -ItemType Directory -Path $MinecraftDirectory -Force | Out-Null
$receiptPath = Join-Path $MinecraftDirectory 'horror-apocalypse-install.json'
$previousInstall = Test-Path -LiteralPath $receiptPath -PathType Leaf
$previousReceipt = if ($previousInstall) {
    try { Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json }
    catch { throw "The previous installation receipt is invalid: $receiptPath" }
} else { $null }
$allowedHosts = @('cdn.modrinth.com', 'www.curseforge.com', 'edge.forgecdn.net', 'mediafilez.forgecdn.net',
    'maven.minecraftforge.net', 'corretto.aws')
$allowedFolders = @('mods', 'shaderpacks', 'resourcepacks')

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

function Save-AllowedDownload {
    param([string]$Url, [string]$Destination, [string[]]$AllowedHosts,
        [System.Net.Http.HttpClient]$Client)
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
                $source = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
                try {
                    $target = [System.IO.File]::Open($Destination, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write)
                    try { $source.CopyTo($target) } finally { $target.Dispose() }
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
    param([string]$Url, [string]$Destination, [string]$Algorithm, [string]$Expected)
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
                Save-AllowedDownload -Url $Url -Destination $temporary -AllowedHosts $allowedHosts
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
    $existing = if (Test-Path -LiteralPath $Path -PathType Leaf) { @(Get-Content -LiteralPath $Path) } else { @() }
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
        $existingLine = @(Get-Content -LiteralPath $Path | Where-Object { $_ -like 'resourcePacks:*' } | Select-Object -First 1)
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

$hardware = Get-ClientHardware
$resolvedProfile = Resolve-GraphicsProfile -RequestedProfile $GraphicsProfile -PreviousReceipt $previousReceipt `
    -Hardware $hardware -ExplicitChoice:($PSBoundParameters.ContainsKey('GraphicsProfile'))
Write-Host "Graphics profile: $resolvedProfile"
$managedFiles = New-Object 'System.Collections.Generic.List[object]'
$targetPaths = @{}
foreach ($entry in @($manifest.files)) {
    if ($entry.folder -notin $allowedFolders) { throw "Unexpected folder: $($entry.folder)" }
    if (-not (Test-ValidFileName -Name $entry.filename)) { throw "Invalid file name: $($entry.filename)" }
    if ($NoShader -and $entry.folder -eq 'shaderpacks') { continue }
    if ($NoResourcePack -and $entry.folder -eq 'resourcepacks') { continue }
    $destination = Join-Path (Join-Path $MinecraftDirectory $entry.folder) $entry.filename
    Get-VerifiedFile -Url $entry.url -Destination $destination -Algorithm $entry.hash_algorithm -Expected $entry.hash
    $relativePath = "$($entry.folder)/$($entry.filename)"
    $targetPaths[$relativePath] = $true
    $managedFiles.Add([ordered]@{
        folder = $entry.folder
        filename = $entry.filename
        hash_algorithm = $entry.hash_algorithm
        hash = $entry.hash
        default_enabled = ($entry.folder -eq 'resourcepacks' -and $entry.default_enabled -eq $true)
    })
}

# Upgrade from the first release. Remove only the exact old mod file our installer installed.
$oldFlashier = Join-Path (Join-Path $MinecraftDirectory 'mods') 'Flashier Flashlights 1.2.0.jar'
$oldFlashierHash = '1065fc113fef88c992efc7dd100aafbc6fc7179722ebc88a8962e2093731be270b2695ac65fb0287864ebcd879a044aa33d341587c7565b16bd4427fbcdbdee4'
if (Test-MatchingHash -Path $oldFlashier -Algorithm 'SHA512' -Expected $oldFlashierHash) {
    Remove-Item -LiteralPath $oldFlashier -Force
    Write-Host 'Removed previous Flashier Flashlights version.'
} elseif (Test-Path -LiteralPath $oldFlashier -PathType Leaf) {
    throw "An unknown Flashier Flashlights file remains at $oldFlashier. Move it out before joining the updated server."
}

$forgeVersionId = '1.20.1-forge-47.4.10'
$forgeVersionPath = Join-Path $MinecraftDirectory "versions\$forgeVersionId\$forgeVersionId.json"
$forgeClientPath = Join-Path $MinecraftDirectory 'libraries\net\minecraftforge\forge\1.20.1-47.4.10\forge-1.20.1-47.4.10-client.jar'
$forgeReady = (Test-Path -LiteralPath $forgeVersionPath -PathType Leaf) -and (Test-Path -LiteralPath $forgeClientPath -PathType Leaf)
if (-not $SkipForge -and -not $forgeReady) {
    $cache = Join-Path $MinecraftDirectory '.installer-cache'
    $runtimeDirectory = Join-Path $MinecraftDirectory 'runtime'
    $javaPath = Join-Path (Join-Path $runtimeDirectory $manifest.java_runtime.directory) 'bin\java.exe'
    if (-not (Test-Path -LiteralPath $javaPath -PathType Leaf)) {
        $javaArchive = Join-Path $cache 'amazon-corretto-17-windows-x64-jdk.zip'
        Get-VerifiedFile -Url $manifest.java_runtime.url -Destination $javaArchive -Algorithm 'SHA256' -Expected $manifest.java_runtime.sha256
        Write-Host 'Extracting portable Java 17...'
        New-Item -ItemType Directory -Path $runtimeDirectory -Force | Out-Null
        Expand-Archive -LiteralPath $javaArchive -DestinationPath $runtimeDirectory -Force
        if (-not (Test-Path -LiteralPath $javaPath -PathType Leaf)) { throw 'Portable Java 17 archive has an unexpected layout.' }
    }
    $installer = Join-Path $cache 'forge-1.20.1-47.4.10-installer.jar'
    Get-VerifiedFile -Url $manifest.forge_installer.url -Destination $installer -Algorithm 'SHA256' -Expected $manifest.forge_installer.sha256
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
    if ($forgeExitCode -ne 0 -or -not (Test-Path -LiteralPath $forgeVersionPath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $forgeClientPath -PathType Leaf)) {
        Get-Content -LiteralPath $logPath -Tail 20 | ForEach-Object { Write-Host $_ }
        throw "Forge client installation failed (exit code $forgeExitCode). See $logPath"
    }
    $forgeReady = $true
}

# Remove only files that a previous version of this installer installed and that
# are no longer in the current manifest. Preserve every unrecognized file.
foreach ($old in @($previousReceipt.managed_files | Where-Object { $null -ne $_ })) {
    if ($old.folder -notin $allowedFolders -or -not (Test-ValidFileName -Name $old.filename) -or
        $old.hash_algorithm -notin @('SHA256', 'SHA512')) {
        throw 'The previous installation receipt contains an unsafe file entry.'
    }
    $relativePath = "$($old.folder)/$($old.filename)"
    if ($targetPaths.ContainsKey($relativePath)) { continue }
    $oldPath = Join-Path (Join-Path $MinecraftDirectory $old.folder) $old.filename
    if (-not (Test-Path -LiteralPath $oldPath -PathType Leaf)) { continue }
    if (-not (Test-MatchingHash -Path $oldPath -Algorithm $old.hash_algorithm -Expected $old.hash)) {
        throw "An old managed file has changed: $oldPath. Move it out before updating."
    }
    Remove-Item -LiteralPath $oldPath -Force
    Write-Host "Removed obsolete pack file: $relativePath"
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
$receipt | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $receiptPath -Encoding UTF8
Write-Host ''
Write-Host "Ready: $MinecraftDirectory"
if ($forgeReady) { Write-Host "Forge installed: $forgeVersionId" }
Write-Host 'In TLauncher, choose this game directory and the Forge 1.20.1 / 47.4.10 version.'
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
