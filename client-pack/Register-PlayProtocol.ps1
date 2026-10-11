[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [string]$InstallDirectory = (Join-Path $env:LOCALAPPDATA 'POSLE\PlayHandler'),
    [switch]$PrintPlan,
    [switch]$PrepareOnly
)

# Explicit, per-user opt-in. The website does not call this script. The target
# merely opens a verified TLauncher selection; it cannot press Play or sign in.
$ErrorActionPreference = 'Stop'
$installDirectory = [IO.Path]::GetFullPath($InstallDirectory)
$localAppData = [IO.Path]::GetFullPath($env:LOCALAPPDATA).TrimEnd('\', '/')
if (-not $installDirectory.StartsWith($localAppData + '\',
        [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The play handler must be installed below the current user LOCALAPPDATA.'
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

$names = @('POSLEProtocolHost.cs', 'Invoke-LocalPlay.ps1',
    'Forge-ClientReadiness.ps1', 'client-modpack.json')
$notifyPath = Join-Path $PSScriptRoot 'PlayProtocolShellNotify.ps1'
if (-not (Test-Path -LiteralPath $notifyPath -PathType Leaf)) {
    throw 'PlayProtocolShellNotify.ps1 is missing beside this script.'
}
Assert-NoReparsePoint -Path $notifyPath
$sourceFiles = foreach ($name in $names) {
    $path = Join-Path $PSScriptRoot $name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Missing play handler source: $name"
    }
    Assert-NoReparsePoint -Path $path
    [ordered]@{ name = $name; sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash }
}
$manifest = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'client-modpack.json') -Raw -Encoding UTF8 |
    ConvertFrom-Json
if ($manifest.minecraft_version -cne '1.20.1' -or
    $manifest.forge_version -cne '47.4.10' -or
    $manifest.server_address -cne 'cairo-worrisome.tun.ply.gg') {
    throw 'The client manifest does not match this local play handler.'
}

$registryPath = 'HKEY_CURRENT_USER\Software\Classes\posle'
$registrySubkey = 'Software\Classes\posle'
$hostPath = Join-Path $installDirectory 'POSLEProtocolHost.exe'
$command = '"' + $hostPath + '" "%1"'

function Assert-PlayProtocolAssociationShape {
    param([hashtable]$Snapshot, [string]$InstallDirectory, [string]$Command,
        [switch]$AllowIncomplete)
    $isEmpty = @($Snapshot.root_values).Count -eq 0 -and
        @($Snapshot.root_subkeys).Count -eq 0
    if (($Snapshot.marker -cne '1' -and -not ($AllowIncomplete -and $isEmpty)) -or
        ($Snapshot.install_directory -and $Snapshot.install_directory -cne $InstallDirectory) -or
        ($Snapshot.command -and $Snapshot.command -cne $Command) -or
        (-not $AllowIncomplete -and
            ($Snapshot.install_directory -cne $InstallDirectory -or
             $Snapshot.command -cne $Command))) {
        throw 'The posle URI association belongs to another installation or has changed.'
    }
    $expectedNames = @{
        root_values = @('', 'POSLEInstallDirectory', 'POSLEManaged', 'URL Protocol')
        root_subkeys = @('shell')
        shell_values = @()
        shell_subkeys = @('open')
        open_values = @()
        open_subkeys = @('command')
        command_values = @('')
        command_subkeys = @()
    }
    foreach ($field in $expectedNames.Keys) {
        $actual = @($Snapshot[$field] | Sort-Object)
        $expected = @($expectedNames[$field] | Sort-Object)
        $bad = if ($AllowIncomplete) {
            @($actual | Where-Object { $_ -cnotin $expected }).Count -ne 0 -or
                @($actual | Select-Object -Unique).Count -ne $actual.Count
        } else {
            $actual.Count -ne $expected.Count -or
                ($actual -join "`0") -cne ($expected -join "`0")
        }
        if ($bad) {
            throw "The posle URI association has additional or missing $field."
        }
    }
    if (($Snapshot.root_values -contains 'POSLEManaged' -and $Snapshot.marker -cne '1') -or
        ($Snapshot.root_values -contains 'POSLEInstallDirectory' -and
            $Snapshot.install_directory -cne $InstallDirectory) -or
        ($Snapshot.root_values -contains '' -and
            $Snapshot.root_label -cne 'POSLE Minecraft Play') -or
        ($Snapshot.root_values -contains 'URL Protocol' -and
            $Snapshot.url_protocol -cne '') -or
        ($Snapshot.command_values -contains '' -and
            $Snapshot.command -cne $Command)) {
        throw 'The posle URI association contains unexpected values.'
    }
    if (-not $isEmpty -and $Snapshot.root_values -notcontains 'POSLEManaged') {
        throw 'The partial posle URI association lacks its ownership marker.'
    }
}

function Set-PlayProtocolRegistryValues {
    param($UserKey, [string]$InstallDirectory, [string]$Command)
    # First mark ownership. An interrupted write can then be safely completed
    # on a later run; the command is written last, after all metadata exists.
    $UserKey.SetValue('POSLEManaged', '1', [Microsoft.Win32.RegistryValueKind]::String)
    $UserKey.SetValue('POSLEInstallDirectory', $InstallDirectory,
        [Microsoft.Win32.RegistryValueKind]::String)
    $UserKey.SetValue('', 'POSLE Minecraft Play', [Microsoft.Win32.RegistryValueKind]::String)
    $UserKey.SetValue('URL Protocol', '', [Microsoft.Win32.RegistryValueKind]::String)
    $commandKey = $UserKey.CreateSubKey('shell\open\command')
    try { $commandKey.SetValue('', $Command, [Microsoft.Win32.RegistryValueKind]::String) }
    finally { $commandKey.Close() }
}

if ($PrintPlan) {
    [ordered]@{
        registry_path = $registryPath
        install_directory = $installDirectory
        command = $command
        source_files = @($sourceFiles)
        action = 'Open signed TLauncher only after the local client passes checks; game launch is manual.'
    } | ConvertTo-Json -Depth 4
    return
}

Assert-NoReparsePoint -Path $installDirectory
Assert-NoReparsePoint -Path (Join-Path $installDirectory 'protocol-receipt.json')
if (-not $PrepareOnly) {
# File preparation does not create or modify a URI association. It can run in
# an isolated staging directory while this user already has a live handler.
$machineKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SOFTWARE\Classes\posle')
if ($machineKey) {
    $machineKey.Close()
    throw 'A machine-wide posle URI association already exists; refusing to override it.'
}
$existing = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($registrySubkey)
if ($existing) {
    try {
        $shellKey = $existing.OpenSubKey('shell')
        $openKey = if ($shellKey) { $shellKey.OpenSubKey('open') } else { $null }
        $existingCommandKey = if ($openKey) { $openKey.OpenSubKey('command') } else { $null }
        try {
            $snapshot = @{
                marker = [string]$existing.GetValue('POSLEManaged')
                install_directory = [string]$existing.GetValue('POSLEInstallDirectory')
                command = if ($existingCommandKey) { [string]$existingCommandKey.GetValue('') } else { '' }
                root_label = [string]$existing.GetValue('')
                url_protocol = [string]$existing.GetValue('URL Protocol')
                root_values = @($existing.GetValueNames())
                root_subkeys = @($existing.GetSubKeyNames())
                shell_values = if ($shellKey) { @($shellKey.GetValueNames()) } else { @() }
                shell_subkeys = if ($shellKey) { @($shellKey.GetSubKeyNames()) } else { @() }
                open_values = if ($openKey) { @($openKey.GetValueNames()) } else { @() }
                open_subkeys = if ($openKey) { @($openKey.GetSubKeyNames()) } else { @() }
                command_values = if ($existingCommandKey) { @($existingCommandKey.GetValueNames()) } else { @() }
                command_subkeys = if ($existingCommandKey) { @($existingCommandKey.GetSubKeyNames()) } else { @() }
            }
            Assert-PlayProtocolAssociationShape -Snapshot $snapshot -InstallDirectory $installDirectory `
                -Command $command -AllowIncomplete
        } finally {
            if ($existingCommandKey) { $existingCommandKey.Close() }
            if ($openKey) { $openKey.Close() }
            if ($shellKey) { $shellKey.Close() }
        }
    } finally { $existing.Close() }
}
}

$receiptPath = Join-Path $installDirectory 'protocol-receipt.json'
$hasExistingInstall = Test-Path -LiteralPath $installDirectory
$needsUpdate = $false
if ($hasExistingInstall) {
    if (-not (Test-Path -LiteralPath $installDirectory -PathType Container)) {
        throw 'The target handler path is not a directory.'
    }
    if (-not (Test-Path -LiteralPath $receiptPath -PathType Leaf)) {
        throw 'The target handler directory exists without a POSLE receipt.'
    }
    $receipt = Get-Content -LiteralPath $receiptPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($receipt.marker -cne 'POSLE-PLAY-1' -or
        $receipt.install_directory -cne $installDirectory -or
        @($receipt.source_files).Count -ne $sourceFiles.Count -or
        $receipt.host_sha256 -cnotmatch '^[A-F0-9]{64}$') {
        throw 'The existing play handler receipt is invalid.'
    }
    $allowedNames = @($names) + @('POSLEProtocolHost.exe', 'protocol-receipt.json',
        'last-success-utc.txt')
    foreach ($item in (Get-ChildItem -LiteralPath $installDirectory -Force)) {
        if ($item.PSIsContainer -or $item.Name -cnotin $allowedNames) {
            throw "The existing handler contains an unowned item: $($item.Name)"
        }
        Assert-NoReparsePoint -Path $item.FullName
    }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($old in @($receipt.source_files)) {
        if ($old.name -isnot [string] -or $old.name -cnotin $names -or
            -not $seen.Add($old.name) -or
            $old.sha256 -isnot [string] -or $old.sha256 -cnotmatch '^[A-F0-9]{64}$') {
            throw 'The existing play handler receipt has an invalid source entry.'
        }
        $file = Join-Path $installDirectory $old.name
        Assert-NoReparsePoint -Path $file
        if (-not (Test-Path -LiteralPath $file -PathType Leaf) -or
            (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -cne $old.sha256) {
            throw "The installed play handler file was changed: $($old.name)"
        }
        $current = @($sourceFiles | Where-Object { $_.name -ceq $old.name })
        if ($current.Count -ne 1) { throw 'The old handler receipt has an unknown source.' }
        if ($current[0].sha256 -cne $old.sha256) { $needsUpdate = $true }
    }
    if ($seen.Count -ne $names.Count) {
        throw 'The old handler receipt omitted a source file.'
    }
    $statePath = Join-Path $installDirectory 'last-success-utc.txt'
    if (Test-Path -LiteralPath $statePath) {
        Assert-NoReparsePoint -Path $statePath
        if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
            throw 'The play handler activation state is not a file.'
        }
    }
    Assert-NoReparsePoint -Path $hostPath
    if (-not (Test-Path -LiteralPath $hostPath -PathType Leaf) -or
        (Get-FileHash -LiteralPath $hostPath -Algorithm SHA256).Hash -cne $receipt.host_sha256) {
        throw 'The installed protocol executable has changed.'
    }
}

$operation = if ($PrepareOnly) {
    'Prepare the POSLE play handler files without registering a URI association'
} else {
    'Install and register the POSLE play protocol for this Windows user'
}
$operationTarget = if ($PrepareOnly) { $installDirectory } else { $registryPath }
if (-not $PSCmdlet.ShouldProcess($operationTarget, $operation)) {
    return
}

if (-not $hasExistingInstall -or $needsUpdate) {
    $parent = Split-Path -Parent $installDirectory
    Assert-NoReparsePoint -Path $parent
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $stage = Join-Path $parent ('PlayHandler-stage-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $stage | Out-Null
    try {
        foreach ($source in $sourceFiles) {
            Copy-Item -LiteralPath (Join-Path $PSScriptRoot $source.name) -Destination $stage -ErrorAction Stop
        }
        # Source files can change between the initial preflight and the copy.
        # Never publish a receipt or URI target for bytes we did not inspect.
        foreach ($source in $sourceFiles) {
            $staged = Join-Path $stage $source.name
            if ((Get-FileHash -LiteralPath $staged -Algorithm SHA256).Hash -cne $source.sha256) {
                throw "The source changed during protocol-host installation: $($source.name)"
            }
        }
        $helperHash = @($sourceFiles | Where-Object { $_.name -ceq 'Invoke-LocalPlay.ps1' })[0].sha256
        $readinessHash = @($sourceFiles | Where-Object { $_.name -ceq 'Forge-ClientReadiness.ps1' })[0].sha256
        $manifestHash = @($sourceFiles | Where-Object { $_.name -ceq 'client-modpack.json' })[0].sha256
        $compiledSource = Get-Content -LiteralPath (Join-Path $stage 'POSLEProtocolHost.cs') -Raw -Encoding UTF8
        $compiledSource = $compiledSource.Replace('POSLE_HELPER_SHA256_PLACEHOLDER', $helperHash)
        $compiledSource = $compiledSource.Replace('POSLE_READINESS_SHA256_PLACEHOLDER', $readinessHash)
        $compiledSource = $compiledSource.Replace('POSLE_MANIFEST_SHA256_PLACEHOLDER', $manifestHash)
        if ($compiledSource.Contains('POSLE_') -and
            $compiledSource -match 'POSLE_(HELPER|READINESS|MANIFEST)_SHA256_PLACEHOLDER') {
            throw 'The protocol-host source still contains a hash placeholder.'
        }
        $stageHost = Join-Path $stage 'POSLEProtocolHost.exe'
        Add-Type -TypeDefinition $compiledSource -OutputAssembly $stageHost `
            -OutputType ConsoleApplication -ErrorAction Stop
        $receipt = [ordered]@{
            marker = 'POSLE-PLAY-1'
            install_directory = $installDirectory
            source_files = @($sourceFiles)
            host_sha256 = (Get-FileHash -LiteralPath $stageHost -Algorithm SHA256).Hash
        }
        $receipt | ConvertTo-Json -Depth 5 |
            Set-Content -LiteralPath (Join-Path $stage 'protocol-receipt.json') -Encoding UTF8
        Assert-NoReparsePoint -Path $installDirectory
        if ($needsUpdate) {
            $backup = Join-Path $parent ((Split-Path -Leaf $installDirectory) +
                '-backup-' + [Guid]::NewGuid().ToString('N'))
            $backup = [IO.Path]::GetFullPath($backup)
            if (-not $backup.StartsWith($localAppData + '\',
                    [StringComparison]::OrdinalIgnoreCase) -or
                (Test-Path -LiteralPath $backup)) {
                throw 'The handler backup target is unsafe.'
            }
            Assert-NoReparsePoint -Path $backup
            Move-Item -LiteralPath $installDirectory -Destination $backup -ErrorAction Stop
            try {
                Move-Item -LiteralPath $stage -Destination $installDirectory -ErrorAction Stop
            } catch {
                if (-not (Test-Path -LiteralPath $installDirectory) -and
                    (Test-Path -LiteralPath $backup)) {
                    Move-Item -LiteralPath $backup -Destination $installDirectory -ErrorAction Stop
                }
                throw
            }
            Write-Host "Previous verified handler preserved: $backup"
        } else {
            Move-Item -LiteralPath $stage -Destination $installDirectory -ErrorAction Stop
        }
    } finally {
        if (Test-Path -LiteralPath $stage) {
            $resolved = [IO.Path]::GetFullPath($stage)
            if ($resolved.StartsWith($localAppData + '\', [StringComparison]::OrdinalIgnoreCase) -and
                (Split-Path -Leaf $resolved).StartsWith('PlayHandler-stage-')) {
                Remove-Item -LiteralPath $resolved -Recurse -Force
            }
        }
    }
}

if ($PrepareOnly) {
    Write-Host 'Prepared the POSLE play handler files. No URI association was registered.'
    return
}

$userKey = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($registrySubkey)
try {
    Set-PlayProtocolRegistryValues -UserKey $userKey -InstallDirectory $installDirectory -Command $command
} finally { $userKey.Close() }
try {
    . $notifyPath
    Notify-PlayProtocolAssociationChanged
} catch {
    Write-Warning "The URI registration succeeded, but Windows shell notification failed: $_"
}
Write-Host 'Registered posle://play for this Windows user. A browser may ask permission; treat every incoming URI as untrusted. TLauncher Play remains manual.'
