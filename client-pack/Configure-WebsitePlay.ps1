[CmdletBinding()]
param(
    [string]$MinecraftDirectory = (Join-Path $env:APPDATA '.minecraft-horror-apocalypse'),
    [ValidateSet('Ask', 'Enable', 'Skip')]
    [string]$Decision = 'Ask'
)

# Called only after the client installer has committed its receipt. The first
# registration requires an explicit choice; a verified existing registration
# can be refreshed after a pack update without asking again.
$ErrorActionPreference = 'Stop'
if ($Decision -ceq 'Skip') {
    Write-Host 'Website Play setup skipped. Use TLauncher manually; an older Play link may need a pack update.'
    return
}

$defaultClient = [IO.Path]::GetFullPath((Join-Path $env:APPDATA '.minecraft-horror-apocalypse')).TrimEnd('\', '/')
$selectedClient = [IO.Path]::GetFullPath($MinecraftDirectory).TrimEnd('\', '/')
if (-not [string]::Equals($selectedClient, $defaultClient, [StringComparison]::OrdinalIgnoreCase)) {
    Write-Warning 'Website Play currently supports only the default dedicated client folder. The client pack was installed, but no URI association was changed.'
    return
}

$manifestPath = Join-Path $PSScriptRoot 'client-modpack.json'
$receiptPath = Join-Path $selectedClient 'horror-apocalypse-install.json'
$registerPath = Join-Path $PSScriptRoot 'Register-PlayProtocol.ps1'
foreach ($file in @($manifestPath, $receiptPath, $registerPath)) {
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
        throw "Website Play setup requires an installed client and its registration files: $file"
    }
}
$manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$receipt = Get-Content -LiteralPath $receiptPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ($receipt.pack -cne $manifest.pack -or
    $receipt.pack_version -cne $manifest.pack_version -or
    $receipt.minecraft_version -cne $manifest.minecraft_version -or
    $receipt.forge_version -cne $manifest.forge_version -or
    $receipt.forge_installed -ne $true -or
    -not [string]::Equals(
        [IO.Path]::GetFullPath([string]$receipt.minecraft_directory).TrimEnd('\', '/'),
        $defaultClient, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The client install receipt does not match this release or Forge is not installed.'
}

$expectedInstall = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'POSLE\PlayHandler'))
$expectedCommand = '"' + (Join-Path $expectedInstall 'POSLEProtocolHost.exe') + '" "%1"'
$existing = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Classes\posle')
$owned = $false
if ($existing) {
    try {
        $commandKey = $existing.OpenSubKey('shell\open\command')
        try {
            $owned = [string]$existing.GetValue('POSLEManaged') -ceq '1' -and
                [string]$existing.GetValue('POSLEInstallDirectory') -ceq $expectedInstall -and
                $commandKey -and [string]$commandKey.GetValue('') -ceq $expectedCommand
        } finally { if ($commandKey) { $commandKey.Close() } }
    } finally { $existing.Close() }
    if (-not $owned) {
        Write-Warning 'Another or changed posle URI association is present. It was not modified; use TLauncher manually.'
        return
    }
}

if (-not $owned -and $Decision -ceq 'Ask') {
    $answer = Read-Host 'Enable the website Play link for this Windows user? [Y/N]'
    if ($answer -cnotmatch '^(?i:y|yes)$') {
        Write-Host 'Website Play setup declined. Use TLauncher manually.'
        return
    }
}

& $registerPath -Confirm:$false
Write-Host 'Website Play link enabled for this Windows user. It opens TLauncher; press Play in TLauncher to start Minecraft.'
