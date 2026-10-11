[CmdletBinding()]
param(
    [string]$MinecraftDirectory = (Join-Path $env:APPDATA '.minecraft-horror-apocalypse'),
    [ValidateSet('Auto', 'Low', 'Balanced', 'Cinematic')]
    [string]$GraphicsProfile = 'Auto',
    [switch]$NoShader,
    [switch]$SkipForge,
    [switch]$LaunchTLauncher
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
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
$allowedHosts = @('cdn.modrinth.com', 'www.curseforge.com', 'maven.minecraftforge.net', 'corretto.aws')

function Test-MatchingHash {
    param([string]$Path, [string]$Algorithm, [string]$Expected)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    $actual = (Get-FileHash -LiteralPath $Path -Algorithm $Algorithm).Hash
    return $actual.Equals($Expected, [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-VerifiedFile {
    param([string]$Url, [string]$Destination, [string]$Algorithm, [string]$Expected)
    if ($Algorithm -notin @('SHA256', 'SHA512')) { throw "Invalid hash algorithm: $Algorithm" }
    $uri = [Uri]$Url
    if ($uri.Scheme -ne 'https' -or $uri.Host -notin $allowedHosts) { throw "Unexpected download host: $Url" }
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
                Invoke-WebRequest -Uri $Url -OutFile $temporary -MaximumRedirection 8 -UseBasicParsing
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

function Get-AutoGraphicsProfile {
    try {
        $system = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        $ramGb = [double]$system.TotalPhysicalMemory / 1GB
        $gpus = @(Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop |
            Where-Object { $_.Name -notmatch 'Microsoft Basic|Remote Display|Virtual Display' })
        $gpuNames = (($gpus | ForEach-Object { $_.Name }) -join ' ')
        if ($ramGb -lt 12 -or ($gpuNames -match 'Intel (HD|UHD)|Radeon (Vega|Graphics)' -and
                $gpuNames -notmatch 'GeForce|Radeon RX|Intel Arc')) { return 'Low' }
        if ($ramGb -ge 16 -and $gpuNames -match 'GeForce RTX|GeForce GTX (10[6-9]|16[5-9]|[2-9][0-9])|Radeon RX|Intel Arc') {
            return 'Cinematic'
        }
    } catch {
        Write-Warning 'Hardware detection was unavailable; using balanced settings.'
    }
    return 'Balanced'
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

$resolvedProfile = if ($GraphicsProfile -eq 'Auto') { Get-AutoGraphicsProfile } else { $GraphicsProfile }
Write-Host "Graphics profile: $resolvedProfile"
foreach ($entry in @($manifest.files)) {
    if ($NoShader -and $entry.folder -eq 'shaderpacks') { continue }
    if ($entry.folder -notin @('mods', 'shaderpacks')) { throw "Unexpected folder: $($entry.folder)" }
    if ($entry.filename -match '[\\/]') { throw "Invalid file name: $($entry.filename)" }
    $destination = Join-Path (Join-Path $MinecraftDirectory $entry.folder) $entry.filename
    Get-VerifiedFile -Url $entry.url -Destination $destination -Algorithm $entry.hash_algorithm -Expected $entry.hash
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

$shouldApplyGraphics = (-not $previousInstall) -or $PSBoundParameters.ContainsKey('GraphicsProfile') -or $NoShader.IsPresent
if ($shouldApplyGraphics) {
    $videoSettings = switch ($resolvedProfile) {
        'Low' { [ordered]@{ renderDistance='6'; simulationDistance='5'; graphicsMode='0'; particles='2'; entityShadows='false'; entityDistanceScaling='0.5'; mipmapLevels='2'; maxFps='60' } }
        'Balanced' { [ordered]@{ renderDistance='8'; simulationDistance='6'; graphicsMode='1'; particles='1'; entityShadows='false'; entityDistanceScaling='0.75'; mipmapLevels='4'; maxFps='90' } }
        'Cinematic' { [ordered]@{ renderDistance='8'; simulationDistance='6'; graphicsMode='1'; particles='0'; entityShadows='true'; entityDistanceScaling='1.0'; mipmapLevels='4'; maxFps='120' } }
    }
    Update-KeyValueFile -Path (Join-Path $MinecraftDirectory 'options.txt') -Separator ':' -Values $videoSettings
    $shaderEnabled = ($resolvedProfile -eq 'Cinematic') -and (-not $NoShader.IsPresent)
    $oculusSettings = [ordered]@{
        shaderPack = 'DMS 1.0.3.zip'
        enableShaders = $shaderEnabled.ToString().ToLowerInvariant()
        maxShadowRenderDistance = '8'
    }
    Update-KeyValueFile -Path (Join-Path $MinecraftDirectory 'config\oculus.properties') -Separator '=' -Values $oculusSettings
}

$receipt = [ordered]@{
    pack = $manifest.pack
    pack_version = $manifest.pack_version
    minecraft_version = $manifest.minecraft_version
    forge_version = $manifest.forge_version
    installed_at = (Get-Date).ToString('o')
    minecraft_directory = $MinecraftDirectory
    graphics_profile = $resolvedProfile
    forge_installed = $forgeReady
    shader_installed = (Test-Path -LiteralPath (Join-Path $MinecraftDirectory 'shaderpacks\DMS 1.0.3.zip') -PathType Leaf)
}
$receipt | ConvertTo-Json | Set-Content -LiteralPath $receiptPath -Encoding UTF8
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
    $tlauncher = @($candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })[0]
    if ($tlauncher) {
        Start-Process -FilePath $tlauncher -WindowStyle Normal
    } else {
        Write-Warning 'TLauncher.exe was not found. Open your Minecraft launcher manually.'
    }
}
