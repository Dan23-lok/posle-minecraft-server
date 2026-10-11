$ErrorActionPreference = 'Stop'

$installer = Join-Path $PSScriptRoot '..\client-pack\Install-HorrorClient.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $installer, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw "Installer has PowerShell syntax errors." }

# Load only function definitions. The installer itself must not run or touch the
# player's client while these offline tests execute.
foreach ($name in @('Get-ClientHardware', 'Get-AutoGraphicsProfile',
        'Resolve-GraphicsProfile',
        'Get-GraphicsPlan', 'Get-AllowedDownloadUri',
        'Save-AllowedDownload', 'Update-KeyValueFile',
        'Update-ResourcePackSelection')) {
    $functionAst = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq $name
    }, $true)
    if (-not $functionAst) { throw "Missing installer function: $name" }
    . ([scriptblock]::Create($functionAst.Extent.Text))
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Case)
    if ($Expected -cne $Actual) {
        throw "$Case : expected '$Expected', got '$Actual'"
    }
}

function Hardware {
    param([double]$RamGb, [int]$CpuCores, [string]$GpuNames)
    return [pscustomobject]@{ RamGb=$RamGb; CpuCores=$CpuCores; GpuNames=$GpuNames }
}

$rtx = Hardware 32 8 'NVIDIA GeForce RTX 4080'
$mid = Hardware 16 6 'NVIDIA GeForce RTX 3060'
$weakCpu = Hardware 32 2 'NVIDIA GeForce RTX 4080'
$weakRam = Hardware 8 8 'NVIDIA GeForce RTX 4080'
$basic = Hardware 16 8 'Microsoft Basic Display Adapter'
$oldGpu = Hardware 16 6 'NVIDIA GeForce GTX 970'
$newerRadeon = Hardware 16 6 'AMD Radeon RX 5700 XT'

Assert-Equal 'Cinematic' (Get-AutoGraphicsProfile -Hardware $rtx) 'high-end CPU/GPU/RAM'
Assert-Equal 'Balanced' (Get-AutoGraphicsProfile -Hardware $mid) 'midrange CPU/GPU/RAM'
Assert-Equal 'Low' (Get-AutoGraphicsProfile -Hardware $weakCpu) 'two-core CPU caps quality'
Assert-Equal 'Low' (Get-AutoGraphicsProfile -Hardware $weakRam) 'eight GB RAM caps quality'
Assert-Equal 'Low' (Get-AutoGraphicsProfile -Hardware $basic) 'software adapter caps quality'
Assert-Equal 'Low' (Get-AutoGraphicsProfile -Hardware $oldGpu) 'older GPU caps quality'
Assert-Equal 'Balanced' (Get-AutoGraphicsProfile -Hardware $newerRadeon) 'four-digit Radeon is not mistaken for RX 570'
Assert-Equal 'Low' (Get-AutoGraphicsProfile -Hardware $null) 'missing hardware info is safe'

$previous = [pscustomobject]@{ graphics_profile='Cinematic' }
Assert-Equal 'Cinematic' (Resolve-GraphicsProfile -RequestedProfile Auto -PreviousReceipt $previous -Hardware $weakRam) 'implicit rerun preserves chosen profile'
Assert-Equal 'Low' (Resolve-GraphicsProfile -RequestedProfile Auto -PreviousReceipt $previous -Hardware $weakRam -ExplicitChoice) 'explicit Auto recalculates on new PC'
Assert-Equal 'Balanced' (Resolve-GraphicsProfile -RequestedProfile Balanced -PreviousReceipt $previous -Hardware $weakRam) 'explicit tier overrides prior choice'

$lowWithGpu = Get-GraphicsPlan -Profile Low -Hardware $weakCpu
Assert-Equal 'false' $lowWithGpu.OculusSettings.enableShaders 'two-core CPU skips DMS'
Assert-Equal '4' $lowWithGpu.OculusSettings.maxShadowRenderDistance 'Low short shadow range'
Assert-Equal '0.0' $lowWithGpu.VideoSettings.gamma 'Low retains dark nights'
Assert-Equal '6' $lowWithGpu.VideoSettings.renderDistance 'Low bounded render distance'

$lowOnBasic = Get-GraphicsPlan -Profile Low -Hardware $basic
Assert-Equal 'false' $lowOnBasic.OculusSettings.enableShaders 'software adapter skips shader'
Assert-Equal '0.0' $lowOnBasic.VideoSettings.gamma 'no-shader fallback keeps lowest gamma'

$unknownGpu = Get-GraphicsPlan -Profile Cinematic -Hardware $null
Assert-Equal 'false' $unknownGpu.OculusSettings.enableShaders 'unknown hardware cannot force shader'

$balanced = Get-GraphicsPlan -Profile Balanced -Hardware $mid
Assert-Equal 'true' $balanced.OculusSettings.enableShaders 'Balanced uses DMS on modern GPU'
Assert-Equal '6' $balanced.OculusSettings.maxShadowRenderDistance 'Balanced shadow range'
Assert-Equal '8' $balanced.VideoSettings.renderDistance 'Balanced bounded render distance'

$cinematic = Get-GraphicsPlan -Profile Cinematic -Hardware $rtx
Assert-Equal 'true' $cinematic.OculusSettings.enableShaders 'Cinematic uses DMS'
Assert-Equal '8' $cinematic.OculusSettings.maxShadowRenderDistance 'Cinematic shadow range'

$noShader = Get-GraphicsPlan -Profile Cinematic -Hardware $rtx -NoShader
Assert-Equal 'false' $noShader.OculusSettings.enableShaders 'NoShader overrides profile'

$downloadHosts = @('cdn.modrinth.com', 'www.curseforge.com',
    'edge.forgecdn.net', 'mediafilez.forgecdn.net')
$allowed = Get-AllowedDownloadUri -Uri ([uri]'https://edge.forgecdn.net/some-mod.jar') -AllowedHosts $downloadHosts
Assert-Equal 'edge.forgecdn.net' $allowed.Host 'known HTTPS CDN hop allowed'
foreach ($rejected in @(
    'http://edge.forgecdn.net/some-mod.jar',
    'https://evil.example/some-mod.jar',
    'https://user:pass@edge.forgecdn.net/some-mod.jar',
    'https://edge.forgecdn.net:8443/some-mod.jar'
)) {
    $caught = $false
    try { Get-AllowedDownloadUri -Uri ([uri]$rejected) -AllowedHosts $downloadHosts | Out-Null }
    catch { $caught = $true }
    Assert-Equal $true $caught "untrusted download URL blocked: $rejected"
}

# Feed deterministic HTTP responses without network access. The downloader
# must reject an outside redirect before sending a second request.
Add-Type -ReferencedAssemblies @('System.Net.Http', 'System.Net.Primitives') -TypeDefinition @'
using System;
using System.Net;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;
public sealed class PosleRedirectTestHandler : HttpMessageHandler {
    public int Calls { get; private set; }
    public Uri Redirect { get; set; }
    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token) {
        Calls++;
        if (Calls == 1) {
            var redirect = new HttpResponseMessage(HttpStatusCode.Redirect);
            redirect.Headers.Location = Redirect;
            return Task.FromResult(redirect);
        }
        return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) {
            Content = new ByteArrayContent(new byte[] { 0x50, 0x4b })
        });
    }
}
'@

$blockedHandler = [PosleRedirectTestHandler]::new()
$blockedHandler.Redirect = [uri]'https://evil.example/asset.jar'
$blockedClient = [System.Net.Http.HttpClient]::new($blockedHandler)
$blockedDestination = [IO.Path]::GetTempFileName()
try {
    $caught = $false
    try {
        Save-AllowedDownload -Url 'https://www.curseforge.com/asset.jar' `
            -Destination $blockedDestination -AllowedHosts $downloadHosts -Client $blockedClient
    } catch { $caught = $true }
    Assert-Equal $true $caught 'outside redirect rejected by downloader'
    Assert-Equal 1 $blockedHandler.Calls 'outside redirect was not contacted'
} finally {
    $blockedClient.Dispose()
    $blockedHandler.Dispose()
    if ([IO.File]::Exists($blockedDestination)) { [IO.File]::Delete($blockedDestination) }
}

$allowedHandler = [PosleRedirectTestHandler]::new()
$allowedHandler.Redirect = [uri]'https://edge.forgecdn.net/asset.jar'
$allowedClient = [System.Net.Http.HttpClient]::new($allowedHandler)
$allowedDestination = [IO.Path]::GetTempFileName()
try {
    Save-AllowedDownload -Url 'https://www.curseforge.com/asset.jar' `
        -Destination $allowedDestination -AllowedHosts $downloadHosts -Client $allowedClient
    Assert-Equal 2 $allowedHandler.Calls 'approved redirect was followed'
    Assert-Equal '504B' ([BitConverter]::ToString([IO.File]::ReadAllBytes($allowedDestination)).Replace('-', '')) 'approved response saved'
} finally {
    $allowedClient.Dispose()
    $allowedHandler.Dispose()
    if ([IO.File]::Exists($allowedDestination)) { [IO.File]::Delete($allowedDestination) }
}

# A normal rerun after -NoShader must reapply Oculus settings even when the
# manifest version has not changed. Use a copied installer and an existing
# fixture file so this regression test cannot download files or alter a real game.
$scratchParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$scratch = Join-Path $scratchParent ('posle-graphics-' + [Guid]::NewGuid().ToString('N'))
$scratchFull = [IO.Path]::GetFullPath($scratch)
if (-not $scratchFull.StartsWith($scratchParent, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Graphics test scratch directory is outside the system temp directory.'
}
try {
    New-Item -ItemType Directory -Path $scratchFull -Force | Out-Null
    $copiedInstaller = Join-Path $scratchFull 'Install-HorrorClient.ps1'
    Copy-Item -LiteralPath $installer -Destination $copiedInstaller
    $historicalDirectory = Join-Path $scratchFull 'historical'
    New-Item -ItemType Directory -Path $historicalDirectory -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot '..\client-pack\historical\client-modpack-2026.10.11.4.json') `
        -Destination $historicalDirectory
    $scratchClient = Join-Path $scratchFull 'client'
    $fixtureMod = Join-Path $scratchClient 'mods\graphics-fixture.jar'
    New-Item -ItemType Directory -Path (Split-Path -Parent $fixtureMod) -Force | Out-Null
    [IO.File]::WriteAllText($fixtureMod, 'graphics fixture')
    $testManifest = [ordered]@{
        pack = (Get-Content -LiteralPath (Join-Path $historicalDirectory 'client-modpack-2026.10.11.4.json') `
            -Raw -Encoding UTF8 | ConvertFrom-Json).pack
        pack_version = 'same-version'
        minecraft_version = '1.20.1'
        forge_version = '47.4.10'
        java_major = 17
        java_runtime = (Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\client-pack\client-modpack.json') `
            -Raw -Encoding UTF8 | ConvertFrom-Json).java_runtime
        server_address = 'example.invalid'
        files = @([ordered]@{
            project='graphics-fixture'; version='test'; filename='graphics-fixture.jar'
            folder='mods'; url='https://cdn.modrinth.com/fixture/graphics-fixture.jar'
            hash_algorithm='SHA256'; hash=(Get-FileHash -LiteralPath $fixtureMod -Algorithm SHA256).Hash
        })
    }
    $testManifest | ConvertTo-Json -Depth 4 |
        Set-Content -LiteralPath (Join-Path $scratchFull 'client-modpack.json') -Encoding UTF8
    & $copiedInstaller -MinecraftDirectory $scratchClient -SkipForge -NoShader | Out-Null
    $oculusPath = Join-Path $scratchClient 'config\oculus.properties'
    $scratchReceipt = Join-Path $scratchClient 'horror-apocalypse-install.json'
    Assert-Equal $true ((Get-Content -LiteralPath $scratchReceipt -Raw | ConvertFrom-Json).no_shader) 'NoShader intent recorded'
    Assert-Equal 'enableShaders=false' (
        @(Get-Content -LiteralPath $oculusPath | Where-Object { $_ -like 'enableShaders=*' })[0]
    ) 'NoShader run disables Oculus'
    $clientOptions = Join-Path $scratchClient 'options.txt'
    Update-KeyValueFile -Path $clientOptions -Separator ':' -Values ([ordered]@{
        renderDistance = '13'
        fov = '0.7'
    })
    # The stale marker makes graphics reapplication observable on all GPUs.
    [IO.File]::WriteAllText($oculusPath, "enableShaders=stale`n")
    & $copiedInstaller -MinecraftDirectory $scratchClient -SkipForge | Out-Null
    $actual = @(Get-Content -LiteralPath $oculusPath | Where-Object { $_ -like 'enableShaders=*' })[0]
    if ($actual -notin @('enableShaders=true', 'enableShaders=false')) {
        throw "normal rerun after NoShader did not reapply Oculus settings: '$actual'"
    }
    $recoveredReceipt = Get-Content -LiteralPath $scratchReceipt -Raw | ConvertFrom-Json
    $expectedPlan = Get-GraphicsPlan -Profile $recoveredReceipt.graphics_profile -Hardware (Get-ClientHardware)
    Assert-Equal ("enableShaders=" + $expectedPlan.OculusSettings.enableShaders) $actual 'normal rerun restores intended shader state'
    Assert-Equal $false $recoveredReceipt.no_shader 'normal rerun clears NoShader intent'
    Assert-Equal 'renderDistance:13' (
        @(Get-Content -LiteralPath $clientOptions | Where-Object { $_ -like 'renderDistance:*' })[0]
    ) 'shader toggle preserves player render distance'
    Assert-Equal 'fov:0.7' (
        @(Get-Content -LiteralPath $clientOptions | Where-Object { $_ -like 'fov:*' })[0]
    ) 'shader toggle preserves player FOV'
    [IO.File]::WriteAllText($oculusPath, "enableShaders=user-choice`n")
    & $copiedInstaller -MinecraftDirectory $scratchClient -SkipForge | Out-Null
    Assert-Equal 'enableShaders=user-choice' (
        @(Get-Content -LiteralPath $oculusPath | Where-Object { $_ -like 'enableShaders=*' })[0]
    ) 'later same-version rerun preserves a manual graphics change'
    Update-KeyValueFile -Path $clientOptions -Separator ':' -Values ([ordered]@{ renderDistance = '11' })
    & $copiedInstaller -MinecraftDirectory $scratchClient -SkipForge -NoResourcePack | Out-Null
    Assert-Equal 'renderDistance:11' (
        @(Get-Content -LiteralPath $clientOptions | Where-Object { $_ -like 'renderDistance:*' })[0]
    ) 'resource-pack toggle preserves player render distance'
    Assert-Equal 'enableShaders=user-choice' (
        @(Get-Content -LiteralPath $oculusPath | Where-Object { $_ -like 'enableShaders=*' })[0]
    ) 'resource-pack toggle does not change Oculus'
    $testManifest.pack_version = 'updated-version'
    $testManifest | ConvertTo-Json -Depth 4 |
        Set-Content -LiteralPath (Join-Path $scratchFull 'client-modpack.json') -Encoding UTF8
    & $copiedInstaller -MinecraftDirectory $scratchClient -SkipForge | Out-Null
    Assert-Equal ("renderDistance:" + $expectedPlan.VideoSettings.renderDistance) (
        @(Get-Content -LiteralPath $clientOptions | Where-Object { $_ -like 'renderDistance:*' })[0]
    ) 'pack-version update reapplies owned video settings'
    Assert-Equal 'fov:0.7' (
        @(Get-Content -LiteralPath $clientOptions | Where-Object { $_ -like 'fov:*' })[0]
    ) 'pack-version update preserves unrelated player FOV'
    Assert-Equal 'updated-version' (
        (Get-Content -LiteralPath $scratchReceipt -Raw | ConvertFrom-Json).pack_version
    ) 'pack-version update recorded'
} finally {
    if (Test-Path -LiteralPath $scratchFull) {
        if (-not $scratchFull.StartsWith($scratchParent, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Refusing to remove scratch outside the system temp directory.'
        }
        Remove-Item -LiteralPath $scratchFull -Recurse -Force
    }
}

$optionsPath = [IO.Path]::GetTempFileName()
$backupPath = "$optionsPath.horror-backup"
try {
    $before = @(
        'renderDistance:32', 'gamma:0.8', 'fov:0.9',
        'resourcePacks:["vanilla","file/custom.zip"]', 'customOption:keep-me'
    )
    [IO.File]::WriteAllLines($optionsPath, $before)
    Update-KeyValueFile -Path $optionsPath -Separator ':' -Values $lowWithGpu.VideoSettings
    $after = [IO.File]::ReadAllLines($optionsPath)
    Assert-Equal 'renderDistance:6' ($after | Where-Object { $_ -like 'renderDistance:*' }) 'owned setting updated'
    Assert-Equal 'gamma:0.0' ($after | Where-Object { $_ -like 'gamma:*' }) 'dark gamma updated'
    Assert-Equal 'fov:0.9' ($after | Where-Object { $_ -like 'fov:*' }) 'unrelated FOV preserved'
    Assert-Equal 'resourcePacks:["vanilla","file/custom.zip"]' (
        $after | Where-Object { $_ -like 'resourcePacks:*' }) 'custom pack selection preserved'
    Assert-Equal 'customOption:keep-me' (
        $after | Where-Object { $_ -like 'customOption:*' }) 'unrelated option preserved'
    Assert-Equal ($before -join "`n") (([IO.File]::ReadAllLines($backupPath)) -join "`n") 'original options backed up'
} finally {
    if ([IO.File]::Exists($optionsPath)) { [IO.File]::Delete($optionsPath) }
    if ([IO.File]::Exists($backupPath)) { [IO.File]::Delete($backupPath) }
}

# UTF-8 without BOM is the format the installer writes. Keep non-ASCII player
# settings intact when it updates graphics and resource-pack selection.
$unicode = -join @([char]0x0442, [char]0x0443, [char]0x043C, [char]0x0430, [char]0x043D)
$utf8NoBom = New-Object Text.UTF8Encoding($false)
$optionsPath = [IO.Path]::GetTempFileName()
$oculusPath = [IO.Path]::GetTempFileName()
try {
    [IO.File]::WriteAllLines($optionsPath,
        @("customOption:$unicode", 'gamma:0.8', "resourcePacks:[`"vanilla`",`"file/$unicode.zip`"]"), $utf8NoBom)
    [IO.File]::WriteAllLines($oculusPath,
        @("customFog=$unicode", 'enableShaders=false'), $utf8NoBom)
    $beforeBytes = [IO.File]::ReadAllBytes($optionsPath)
    Assert-Equal $false ($beforeBytes[0] -eq 239 -and $beforeBytes[1] -eq 187 -and $beforeBytes[2] -eq 191) 'options fixture has no UTF-8 BOM'

    Update-KeyValueFile -Path $optionsPath -Separator ':' -Values ([ordered]@{ gamma = '0.0' })
    Update-KeyValueFile -Path $oculusPath -Separator '=' -Values ([ordered]@{ enableShaders = 'true' })
    $optionLines = [IO.File]::ReadAllLines($optionsPath, [Text.Encoding]::UTF8)
    $oculusLines = [IO.File]::ReadAllLines($oculusPath, [Text.Encoding]::UTF8)
    Assert-Equal "customOption:$unicode" @($optionLines | Where-Object { $_ -like 'customOption:*' })[0] 'UTF-8 player option preserved'
    Assert-Equal "customFog=$unicode" @($oculusLines | Where-Object { $_ -like 'customFog=*' })[0] 'UTF-8 Oculus option preserved'

    Update-ResourcePackSelection -Path $optionsPath -RemoveIds @() -AddIds @('file/new.zip')
    $resourceLine = @([IO.File]::ReadAllLines($optionsPath, [Text.Encoding]::UTF8) |
        Where-Object { $_ -like 'resourcePacks:*' })[0]
    $resourceIds = ConvertFrom-Json -InputObject $resourceLine.Substring('resourcePacks:'.Length)
    Assert-Equal $true ($resourceIds -contains "file/$unicode.zip") 'UTF-8 resource-pack selection preserved'
    Assert-Equal $true ($resourceIds -contains 'file/new.zip') 'new resource-pack selection added'
} finally {
    foreach ($path in @($optionsPath, $oculusPath, "$optionsPath.horror-backup", "$oculusPath.horror-backup")) {
        if ([IO.File]::Exists($path)) { [IO.File]::Delete($path) }
    }
}

Write-Output 'Client graphics tests passed.'
