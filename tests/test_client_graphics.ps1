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
    param([double]$RamGb, [int]$CpuCores, [string]$GpuNames,
        [double]$AvailableRamGb = -1, [long]$DisplayPixels = 0,
        [bool]$GpuSelectionUncertain = $false)
    return [pscustomobject]@{
        RamGb=$RamGb; CpuCores=$CpuCores; GpuNames=$GpuNames
        AvailableRamGb=$AvailableRamGb; DisplayPixels=$DisplayPixels
        GpuSelectionUncertain=$GpuSelectionUncertain
    }
}

# Exercise the real detection function with deterministic CIM responses. A
# missing optional adapter query must not discard known RAM/CPU information.
function Get-CimInstance {
    param([string]$ClassName, $ErrorAction)
    switch ($ClassName) {
        'Win32_ComputerSystem' { return [pscustomobject]@{ TotalPhysicalMemory=[long](16GB) } }
        'Win32_Processor' { return [pscustomobject]@{ NumberOfCores=8 } }
        'Win32_VideoController' {
            if ($script:fakeGpuFailure) { throw 'Video controller query unavailable' }
            if ($script:fakeGpuMode -eq 'integrated-active') {
                return @(
                    [pscustomobject]@{ Name='Intel UHD Graphics'; CurrentHorizontalResolution=1920; CurrentVerticalResolution=1080 },
                    [pscustomobject]@{ Name='NVIDIA GeForce RTX 4080'; CurrentHorizontalResolution=0; CurrentVerticalResolution=0 }
                )
            }
            if ($script:fakeGpuMode -eq 'both-active') {
                return @(
                    [pscustomobject]@{ Name='Intel UHD Graphics'; CurrentHorizontalResolution=1920; CurrentVerticalResolution=1080 },
                    [pscustomobject]@{ Name='NVIDIA GeForce RTX 4080'; CurrentHorizontalResolution=2560; CurrentVerticalResolution=1440 }
                )
            }
            return [pscustomobject]@{
                Name='NVIDIA GeForce RTX 3060'
                CurrentHorizontalResolution=3840
                CurrentVerticalResolution=2160
            }
        }
        'Win32_OperatingSystem' { return [pscustomobject]@{ FreePhysicalMemory=[long](2GB / 1KB) } }
        default { throw "Unexpected CIM class: $ClassName" }
    }
}
try {
    $detected = Get-ClientHardware
    Assert-Equal 16 $detected.RamGb 'CIM total RAM in GiB'
    Assert-Equal 8 $detected.CpuCores 'CIM physical cores'
    Assert-Equal 2 $detected.AvailableRamGb 'CIM free RAM in GiB'
    Assert-Equal (3840 * 2160) $detected.DisplayPixels 'CIM display pixels'
    $script:fakeGpuFailure = $true
    $noGpu = Get-ClientHardware
    Assert-Equal 16 $noGpu.RamGb 'GPU query failure keeps total RAM'
    Assert-Equal 8 $noGpu.CpuCores 'GPU query failure keeps CPU cores'
    Assert-Equal '' $noGpu.GpuNames 'GPU query failure uses unknown GPU'
    Assert-Equal 'Low' (Get-AutoGraphicsProfile -Hardware $noGpu) 'GPU query failure selects safe profile'
    $script:fakeGpuFailure = $false
    $script:fakeGpuMode = 'integrated-active'
    $integratedActive = Get-ClientHardware
    Assert-Equal 'Intel UHD Graphics' $integratedActive.GpuNames 'inactive RTX cannot determine render GPU'
    Assert-Equal 'Low' (Get-AutoGraphicsProfile -Hardware $integratedActive) 'integrated-active laptop chooses Low'
    Assert-Equal 'false' (Get-GraphicsPlan -Profile Low -Hardware $integratedActive).OculusSettings.enableShaders 'inactive RTX does not enable DMS'
    $script:fakeGpuMode = 'both-active'
    $mixedActive = Get-ClientHardware
    Assert-Equal $true $mixedActive.GpuSelectionUncertain 'two active adapters are ambiguous'
    Assert-Equal 'Low' (Get-AutoGraphicsProfile -Hardware $mixedActive) 'mixed active adapters choose Low'
    Assert-Equal 'false' (Get-GraphicsPlan -Profile Low -Hardware $mixedActive).OculusSettings.enableShaders 'mixed adapters do not enable DMS'
} finally {
    Remove-Item -Path Function:\Get-CimInstance -Force
    Remove-Variable -Name fakeGpuFailure -Scope Script -ErrorAction SilentlyContinue
    Remove-Variable -Name fakeGpuMode -Scope Script -ErrorAction SilentlyContinue
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
$memoryPressure = Hardware 32 8 'NVIDIA GeForce RTX 4080' 2.5
$fourKMid = Hardware 32 8 'NVIDIA GeForce RTX 3060' 20 (3840 * 2160)
$fourKHigh = Hardware 32 8 'NVIDIA GeForce RTX 4080' 20 (3840 * 2160)
Assert-Equal 'Low' (Get-AutoGraphicsProfile -Hardware $memoryPressure) 'low free memory caps auto quality'
Assert-Equal 'Low' (Get-AutoGraphicsProfile -Hardware $fourKMid) '4K on midrange GPU selects low'
Assert-Equal 'Balanced' (Get-AutoGraphicsProfile -Hardware $fourKHigh) '4K caps automatic cinematic profile'
Assert-Equal 'Cinematic' (Resolve-GraphicsProfile -RequestedProfile Cinematic -PreviousReceipt $null -Hardware $fourKHigh) 'player can override 4K auto cap'

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
$lowOnMemoryPressure = Get-GraphicsPlan -Profile Low -Hardware $memoryPressure
Assert-Equal 'false' $lowOnMemoryPressure.OculusSettings.enableShaders 'low free memory does not start shader'
$optInShader = Get-GraphicsPlan -Profile Low -Hardware $memoryPressure -AllowShaderUnderMemoryPressure
Assert-Equal 'true' $optInShader.OculusSettings.enableShaders 'explicit shader opt-in bypasses memory pressure only'
$unsafeOptIn = Get-GraphicsPlan -Profile Low -Hardware $basic -AllowShaderUnderMemoryPressure
Assert-Equal 'false' $unsafeOptIn.OculusSettings.enableShaders 'shader opt-in does not bypass GPU guard'

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
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot '..\client-pack\Forge-ClientReadiness.ps1') -Destination $scratchFull
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
    foreach ($profileChoice in @('Low', 'Cinematic')) {
        $profileClient = Join-Path $scratchFull ("clean-$profileChoice")
        $profileMod = Join-Path $profileClient 'mods\graphics-fixture.jar'
        New-Item -ItemType Directory -Path (Split-Path -Parent $profileMod) -Force | Out-Null
        Copy-Item -LiteralPath $fixtureMod -Destination $profileMod
        & $copiedInstaller -MinecraftDirectory $profileClient -SkipForge -GraphicsProfile $profileChoice | Out-Null
        $profileReceipt = Get-Content -LiteralPath (Join-Path $profileClient 'horror-apocalypse-install.json') `
            -Raw | ConvertFrom-Json
        Assert-Equal $profileChoice $profileReceipt.graphics_profile "clean $profileChoice receipt"
        $profileOptions = Get-Content -LiteralPath (Join-Path $profileClient 'options.txt')
        $profilePlan = Get-GraphicsPlan -Profile $profileChoice -Hardware (Get-ClientHardware)
        Assert-Equal ("renderDistance:" + $profilePlan.VideoSettings.renderDistance) (
            @($profileOptions | Where-Object { $_ -like 'renderDistance:*' })[0]
        ) "clean $profileChoice render distance"
        Assert-Equal 'gamma:0.0' (
            @($profileOptions | Where-Object { $_ -like 'gamma:*' })[0]
        ) "clean $profileChoice dark gamma"
        Assert-Equal ("enableShaders=" + $profilePlan.OculusSettings.enableShaders) (
            @(Get-Content -LiteralPath (Join-Path $profileClient 'config\oculus.properties') |
                Where-Object { $_ -like 'enableShaders=*' })[0]
        ) "clean $profileChoice Oculus setting"
        if ($profileChoice -eq 'Low') {
            & $copiedInstaller -MinecraftDirectory $profileClient -SkipForge `
                -AllowShaderUnderMemoryPressure | Out-Null
            $overrideReceipt = Get-Content -LiteralPath (Join-Path $profileClient 'horror-apocalypse-install.json') `
                -Raw | ConvertFrom-Json
            Assert-Equal $true $overrideReceipt.allow_shader_under_memory_pressure 'shader opt-in recorded'
            & $copiedInstaller -MinecraftDirectory $profileClient -SkipForge | Out-Null
            $overrideReceipt = Get-Content -LiteralPath (Join-Path $profileClient 'horror-apocalypse-install.json') `
                -Raw | ConvertFrom-Json
            Assert-Equal $true $overrideReceipt.allow_shader_under_memory_pressure 'shader opt-in retained on rerun'
            $testManifest.pack_version = 'optin-update'
            $testManifest | ConvertTo-Json -Depth 4 |
                Set-Content -LiteralPath (Join-Path $scratchFull 'client-modpack.json') -Encoding UTF8
            & $copiedInstaller -MinecraftDirectory $profileClient -SkipForge | Out-Null
            $overrideReceipt = Get-Content -LiteralPath (Join-Path $profileClient 'horror-apocalypse-install.json') `
                -Raw | ConvertFrom-Json
            Assert-Equal $true $overrideReceipt.allow_shader_under_memory_pressure 'shader opt-in retained on pack update'
            & $copiedInstaller -MinecraftDirectory $profileClient -SkipForge -NoShader | Out-Null
            $overrideReceipt = Get-Content -LiteralPath (Join-Path $profileClient 'horror-apocalypse-install.json') `
                -Raw | ConvertFrom-Json
            Assert-Equal $false $overrideReceipt.allow_shader_under_memory_pressure 'NoShader clears shader opt-in'
            $testManifest.pack_version = 'same-version'
            $testManifest | ConvertTo-Json -Depth 4 |
                Set-Content -LiteralPath (Join-Path $scratchFull 'client-modpack.json') -Encoding UTF8
        }
    }
    # Clean install with a known GPU but only 2 GiB free: verify the policy
    # reaches the written client config, rather than only testing pure logic.
    $lowMemoryClient = Join-Path $scratchFull 'clean-low-memory'
    $lowMemoryMod = Join-Path $lowMemoryClient 'mods\graphics-fixture.jar'
    New-Item -ItemType Directory -Path (Split-Path -Parent $lowMemoryMod) -Force | Out-Null
    Copy-Item -LiteralPath $fixtureMod -Destination $lowMemoryMod
    function Get-CimInstance {
        param([string]$ClassName, $ErrorAction)
        switch ($ClassName) {
            'Win32_ComputerSystem' { return [pscustomobject]@{ TotalPhysicalMemory=[long](16GB) } }
            'Win32_Processor' { return [pscustomobject]@{ NumberOfCores=8 } }
            'Win32_VideoController' { return [pscustomobject]@{
                Name='NVIDIA GeForce RTX 3060'; CurrentHorizontalResolution=1920; CurrentVerticalResolution=1080
            } }
            'Win32_OperatingSystem' { return [pscustomobject]@{ FreePhysicalMemory=[long](2GB / 1KB) } }
            default { throw "Unexpected CIM class: $ClassName" }
        }
    }
    try {
        & $copiedInstaller -MinecraftDirectory $lowMemoryClient -SkipForge | Out-Null
    } finally {
        Remove-Item -Path Function:\Get-CimInstance -Force
    }
    $lowMemoryReceipt = Get-Content -LiteralPath (Join-Path $lowMemoryClient 'horror-apocalypse-install.json') `
        -Raw | ConvertFrom-Json
    Assert-Equal 'Low' $lowMemoryReceipt.graphics_profile 'clean low-memory install selected Low'
    Assert-Equal 'enableShaders=false' (
        @(Get-Content -LiteralPath (Join-Path $lowMemoryClient 'config\oculus.properties') |
            Where-Object { $_ -like 'enableShaders=*' })[0]
    ) 'clean low-memory install disabled DMS'
    Assert-Equal 'gamma:0.0' (
        @(Get-Content -LiteralPath (Join-Path $lowMemoryClient 'options.txt') |
            Where-Object { $_ -like 'gamma:*' })[0]
    ) 'clean low-memory install keeps darkest vanilla gamma'
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
    # Simulate a v9 receipt: the new policy cannot infer whether the old tier
    # or Oculus setting was chosen manually, so both stay unchanged until an
    # explicit -GraphicsProfile Auto request.
    $legacyReceipt = Get-Content -LiteralPath $scratchReceipt -Raw | ConvertFrom-Json
    $legacyReceipt.PSObject.Properties.Remove('graphics_policy_revision')
    $legacyReceipt.PSObject.Properties.Remove('graphics_profile_source')
    $legacyReceipt.PSObject.Properties.Remove('allow_shader_under_memory_pressure')
    $legacyReceipt | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $scratchReceipt -Encoding UTF8
    [IO.File]::WriteAllText($oculusPath, "enableShaders=user-choice`n")
    & $copiedInstaller -MinecraftDirectory $scratchClient -SkipForge | Out-Null
    $migratedReceipt = Get-Content -LiteralPath $scratchReceipt -Raw | ConvertFrom-Json
    Assert-Equal 2 $migratedReceipt.graphics_policy_revision 'v9 graphics policy migrated'
    Assert-Equal 'legacy' $migratedReceipt.graphics_profile_source 'v9 selection provenance remains unknown'
    Assert-Equal 'renderDistance:11' (
        @(Get-Content -LiteralPath $clientOptions | Where-Object { $_ -like 'renderDistance:*' })[0]
    ) 'v9 migration preserves player render distance'
    Assert-Equal 'fov:0.7' (
        @(Get-Content -LiteralPath $clientOptions | Where-Object { $_ -like 'fov:*' })[0]
    ) 'v9 migration preserves player FOV'
    Assert-Equal 'enableShaders=user-choice' (
        @(Get-Content -LiteralPath $oculusPath | Where-Object { $_ -like 'enableShaders=*' })[0]
    ) 'v9 migration preserves manual Oculus choice'
    $policyBackups = @(Get-ChildItem -LiteralPath (Split-Path -Parent $oculusPath) `
        -Filter 'oculus.properties.before-posle-policy-v2-*.backup' -File)
    Assert-Equal 0 $policyBackups.Count 'v9 migration does not create an unnecessary backup'
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
