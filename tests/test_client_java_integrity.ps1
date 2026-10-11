$ErrorActionPreference = 'Stop'
$repoClient = Join-Path $PSScriptRoot '..\client-pack'
$manifest = Get-Content -LiteralPath (Join-Path $repoClient 'client-modpack.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$scratch = [IO.Path]::GetFullPath((Join-Path $tempRoot ('posle-java-integrity-' + [Guid]::NewGuid().ToString('N'))))
if (-not $scratch.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe temp directory.' }

function Assert-True {
    param([bool]$Condition, [string]$Case)
    if (-not $Condition) { throw $Case }
}

try {
    $package = Join-Path $scratch 'package'
    $client = Join-Path $scratch 'client'
    New-Item -ItemType Directory -Path (Join-Path $package 'historical'), (Join-Path $client 'mods') -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $repoClient 'historical\client-modpack-2026.10.11.4.json') -Destination (Join-Path $package 'historical')

    $mod = Join-Path $client 'mods\fixture.jar'
    [IO.File]::WriteAllText($mod, 'client fixture')
    $forgeSource = Join-Path $scratch 'forge-fixture.jar'
    [IO.File]::WriteAllText($forgeSource, 'forge fixture')
    $runtime = [ordered]@{
        url = $manifest.java_runtime.url
        sha256 = $manifest.java_runtime.sha256
        directory = $manifest.java_runtime.directory
        java_exe_sha256 = ('0' * 64)
    }
    $fixtureManifest = [ordered]@{
        pack = $manifest.pack
        pack_version = 'java-integrity-fixture'
        minecraft_version = '1.20.1'
        forge_version = '47.4.10'
        java_major = 17
        server_address = 'example.invalid'
        java_runtime = $runtime
        forge_installer = [ordered]@{ url = $manifest.forge_installer.url; sha256 = (Get-FileHash -LiteralPath $forgeSource -Algorithm SHA256).Hash }
        files = @([ordered]@{ project='fixture'; version='1'; folder='mods'; filename='fixture.jar';
            url='https://cdn.modrinth.com/fixture/fixture.jar'; hash_algorithm='SHA256';
            hash=(Get-FileHash -LiteralPath $mod -Algorithm SHA256).Hash })
    }
    $manifestCopy = Join-Path $package 'client-modpack.json'
    $fixtureManifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifestCopy -Encoding UTF8

    $source = Get-Content -LiteralPath (Join-Path $repoClient 'Install-HorrorClient.ps1') -Raw -Encoding UTF8
    $tokens = $null; $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$parseErrors)
    Assert-True ($parseErrors.Count -eq 0) 'installer parse error'
    $downloadFunction = $ast.Find({ param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-VerifiedFile'
    }, $true)
    Assert-True ($null -ne $downloadFunction) 'Get-VerifiedFile missing'
    $stub = @'
function Get-VerifiedFile {
    param([string]$Url, [string]$Destination, [string]$Algorithm, [string]$Expected, [long]$MaxBytes)
    if ([IO.Path]::GetFileName($Destination) -ne 'forge-1.20.1-47.4.10-installer.jar') {
        throw 'Unexpected fixture download.'
    }
    Copy-Item -LiteralPath $env:POSLE_FORGE_FIXTURE -Destination $Destination
    if (-not (Test-MatchingHash -Path $Destination -Algorithm $Algorithm -Expected $Expected)) {
        throw 'Forge fixture hash mismatch.'
    }
}
'@
    $source = $source.Substring(0, $downloadFunction.Extent.StartOffset) + $stub +
        $source.Substring($downloadFunction.Extent.EndOffset)
    $installerCopy = Join-Path $package 'Install-HorrorClient.ps1'
    [IO.File]::WriteAllText($installerCopy, $source, (New-Object Text.UTF8Encoding($false)))

    $fakeJava = Join-Path (Join-Path (Join-Path $client 'runtime') $manifest.java_runtime.directory) 'bin\java.exe'
    New-Item -ItemType Directory -Path (Split-Path -Parent $fakeJava) -Force | Out-Null
    [IO.File]::WriteAllText($fakeJava, 'not the pinned Corretto binary')
    $env:POSLE_FORGE_FIXTURE = $forgeSource

    $forgedPinError = $null
    try { & $installerCopy -MinecraftDirectory $client | Out-Null }
    catch { $forgedPinError = $_.Exception.Message }
    Assert-True ($forgedPinError -match 'Unexpected portable Java executable hash pin') 'forged Java hash pin was accepted'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $client 'launcher_profiles.json'))) 'forged Java hash pin reached Forge setup'

    Write-Output 'Client Java manifest pin test passed.'
} finally {
    Remove-Item Env:POSLE_FORGE_FIXTURE -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $scratch) {
        $resolved = [IO.Path]::GetFullPath($scratch)
        if (-not $resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or
            -not (Split-Path -Leaf $resolved).StartsWith('posle-java-integrity-')) {
            throw 'Refusing to clean outside expected temp scope.'
        }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
