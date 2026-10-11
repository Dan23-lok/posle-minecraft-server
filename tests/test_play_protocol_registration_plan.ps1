# Plan-only checks. This test neither creates a URI association nor modifies
# the actual POSLE installation on this machine.
$ErrorActionPreference = 'Stop'
$register = Join-Path $PSScriptRoot '..\client-pack\Register-PlayProtocol.ps1'
$unregister = Join-Path $PSScriptRoot '..\client-pack\Unregister-PlayProtocol.ps1'
$notify = Join-Path $PSScriptRoot '..\client-pack\PlayProtocolShellNotify.ps1'
$originalLocalAppData = $env:LOCALAPPDATA
$scratch = [IO.Path]::GetFullPath((Join-Path $env:TEMP ('posle-protocol-plan-' + [Guid]::NewGuid().ToString('N'))))
try {
    $env:LOCALAPPDATA = $scratch
    . $notify
    if (-not (Notify-PlayProtocolAssociationChanged -CompileOnly)) {
        throw 'The Windows shell association notifier did not compile.'
    }
    $installDirectory = Join-Path $scratch 'POSLE\Play Handler'
    $beforeKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Classes\posle')
    $beforeCommand = if ($beforeKey) {
        $commandKey = $beforeKey.OpenSubKey('shell\open\command')
        if ($commandKey) { [string]$commandKey.GetValue('') } else { $null }
    } else { $null }
    if ($beforeKey) { $beforeKey.Close() }

    $registration = (& $register -InstallDirectory $installDirectory -PrintPlan | ConvertFrom-Json)
    if ($registration.registry_path -cne 'HKEY_CURRENT_USER\Software\Classes\posle' -or
        $registration.command -cne ('"' + (Join-Path $installDirectory 'POSLEProtocolHost.exe') + '" "%1"')) {
        throw 'Registration plan does not target only the per-user protocol host.'
    }
    if (@($registration.source_files).Count -ne 4) {
        throw 'Registration plan omitted one of the four pinned source inputs.'
    }
    . $register -InstallDirectory $installDirectory -PrintPlan | Out-Null
    $ownedSnapshot = @{
        marker = '1'; install_directory = $installDirectory; command = $registration.command
        root_label = 'POSLE Minecraft Play'; url_protocol = ''
        root_values = @('', 'POSLEInstallDirectory', 'POSLEManaged', 'URL Protocol')
        root_subkeys = @('shell'); shell_values = @(); shell_subkeys = @('open')
        open_values = @(); open_subkeys = @('command')
        command_values = @(''); command_subkeys = @()
    }
    Assert-PlayProtocolAssociationShape -Snapshot $ownedSnapshot -InstallDirectory $installDirectory `
        -Command $registration.command
    $tampered = $ownedSnapshot.Clone()
    $tampered.command_values = @('', 'DelegateExecute')
    try {
        Assert-PlayProtocolAssociationShape -Snapshot $tampered -InstallDirectory $installDirectory `
            -Command $registration.command
        throw 'Existing association with DelegateExecute was accepted.'
    } catch {
        if ($_.Exception.Message -match '^Existing association with') { throw }
    }
    $tampered = $ownedSnapshot.Clone()
    $tampered.root_subkeys = @('shell', 'extra-verb')
    try {
        Assert-PlayProtocolAssociationShape -Snapshot $tampered -InstallDirectory $installDirectory `
            -Command $registration.command
        throw 'Existing association with extra child key was accepted.'
    } catch {
        if ($_.Exception.Message -match '^Existing association with') { throw }
    }
    $partial = @{
        marker = '1'; install_directory = ''; command = ''
        root_values = @('POSLEManaged'); root_subkeys = @()
        shell_values = @(); shell_subkeys = @(); open_values = @(); open_subkeys = @()
        command_values = @(); command_subkeys = @()
    }
    Assert-PlayProtocolAssociationShape -Snapshot $partial -InstallDirectory $installDirectory `
        -Command $registration.command -AllowIncomplete
    $partialWithDelegate = $partial.Clone()
    $partialWithDelegate.command_values = @('DelegateExecute')
    try {
        Assert-PlayProtocolAssociationShape -Snapshot $partialWithDelegate -InstallDirectory $installDirectory `
            -Command $registration.command -AllowIncomplete
        throw 'Partial association with DelegateExecute was accepted.'
    } catch {
        if ($_.Exception.Message -match '^Partial association with') { throw }
    }
    $events = [Collections.Generic.List[string]]::new()
    $fakeCommand = [pscustomobject]@{ events = $events }
    $fakeCommand | Add-Member -MemberType ScriptMethod -Name SetValue -Value {
        param($name, $value, $kind) $this.events.Add('command:' + $name)
    }
    $fakeCommand | Add-Member -MemberType ScriptMethod -Name Close -Value { }
    $fakeRoot = [pscustomobject]@{ events = $events; child = $fakeCommand; failOn = 'URL Protocol' }
    $fakeRoot | Add-Member -MemberType ScriptMethod -Name SetValue -Value {
        param($name, $value, $kind)
        $this.events.Add('root:' + $name)
        if ($name -ceq $this.failOn) { throw 'Injected registry write failure' }
    }
    $fakeRoot | Add-Member -MemberType ScriptMethod -Name CreateSubKey -Value {
        param($path) $this.events.Add('subkey:' + $path); return $this.child
    }
    try {
        Set-PlayProtocolRegistryValues -UserKey $fakeRoot -InstallDirectory $installDirectory `
            -Command $registration.command
        throw 'Injected registry write failure was swallowed.'
    } catch {
        if ($_.Exception.Message -match '^Injected registry write failure was swallowed') { throw }
    }
    if ($events.Count -lt 3 -or $events[0] -cne 'root:POSLEManaged' -or
        $events[1] -cne 'root:POSLEInstallDirectory' -or
        @($events | Where-Object { $_ -like 'command:*' }).Count -ne 0) {
        throw 'The writer exposed a command before ownership or despite failed registration.'
    }
    $unregistration = (& $unregister -InstallDirectory $installDirectory -PrintPlan | ConvertFrom-Json)
    if ($unregistration.registry_path -cne $registration.registry_path -or
        $unregistration.command -cne $registration.command) {
        throw 'Unregistration plan does not match registration ownership.'
    }
    & $register -InstallDirectory $installDirectory -PrepareOnly -WhatIf | Out-Null
    if (Test-Path -LiteralPath $scratch) {
        throw 'A plan-only or WhatIf operation wrote to LOCALAPPDATA.'
    }
    & $register -InstallDirectory $installDirectory -PrepareOnly | Out-Null
    foreach ($name in @('POSLEProtocolHost.cs', 'Invoke-LocalPlay.ps1',
            'Forge-ClientReadiness.ps1', 'client-modpack.json',
            'POSLEProtocolHost.exe', 'protocol-receipt.json')) {
        if (-not (Test-Path -LiteralPath (Join-Path $installDirectory $name) -PathType Leaf)) {
            throw "Preparation omitted $name"
        }
    }
    $receipt = Get-Content -LiteralPath (Join-Path $installDirectory 'protocol-receipt.json') -Raw |
        ConvertFrom-Json
    if ($receipt.marker -cne 'POSLE-PLAY-1' -or
        $receipt.host_sha256 -cne (Get-FileHash -LiteralPath (Join-Path $installDirectory 'POSLEProtocolHost.exe') -Algorithm SHA256).Hash) {
        throw 'Prepared protocol host does not match its receipt.'
    }
    & $register -InstallDirectory $installDirectory -PrepareOnly | Out-Null
    $fixtureSource = Join-Path $scratch 'fixture-source'
    New-Item -ItemType Directory -Path $fixtureSource | Out-Null
    foreach ($name in @('Register-PlayProtocol.ps1', 'PlayProtocolShellNotify.ps1', 'POSLEProtocolHost.cs',
            'Forge-ClientReadiness.ps1', 'client-modpack.json')) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot ('..\client-pack\' + $name)) -Destination $fixtureSource
    }
    @'
param([string]$PlayUri)
Set-Content -LiteralPath (Join-Path $PSScriptRoot 'invoked.txt') -Value $PlayUri -Encoding UTF8
'@ | Set-Content -LiteralPath (Join-Path $fixtureSource 'Invoke-LocalPlay.ps1') -Encoding UTF8
    $fixtureInstall = Join-Path $scratch 'POSLE\Fixture Handler'
    & (Join-Path $fixtureSource 'Register-PlayProtocol.ps1') -InstallDirectory $fixtureInstall -PrepareOnly | Out-Null
    $fixtureHost = Join-Path $fixtureInstall 'POSLEProtocolHost.exe'
    $fixtureOriginalHelperBytes = [IO.File]::ReadAllBytes((Join-Path $fixtureInstall 'Invoke-LocalPlay.ps1'))
    $ErrorActionPreference = 'Continue'
    & $fixtureHost 'posle://play' 2>&1 | Out-Null
    $ErrorActionPreference = 'Stop'
    if ($LASTEXITCODE -ne 0 -or
        (Get-Content -LiteralPath (Join-Path $fixtureInstall 'invoked.txt') -Raw).Trim() -cne 'posle://play') {
        throw 'Prepared host did not dispatch the pinned harmless fixture.'
    }
    Remove-Item -LiteralPath (Join-Path $fixtureInstall 'invoked.txt') -Force
    'Write-Host tampered' | Set-Content -LiteralPath (Join-Path $fixtureInstall 'Invoke-LocalPlay.ps1') -Encoding UTF8
    $ErrorActionPreference = 'Continue'
    & $fixtureHost 'posle://play' 2>&1 | Out-Null
    $ErrorActionPreference = 'Stop'
    if ($LASTEXITCODE -ne 5 -or (Test-Path -LiteralPath (Join-Path $fixtureInstall 'invoked.txt'))) {
        throw 'Prepared host accepted post-install helper modification.'
    }
    try {
        & (Join-Path $fixtureSource 'Register-PlayProtocol.ps1') -InstallDirectory $fixtureInstall -PrepareOnly | Out-Null
        throw 'Preparation overwrote a tampered installed helper.'
    } catch {
        if ($_.Exception.Message -match '^Preparation overwrote') { throw }
    }
    [IO.File]::WriteAllBytes((Join-Path $fixtureInstall 'Invoke-LocalPlay.ps1'), $fixtureOriginalHelperBytes)
    Add-Content -LiteralPath (Join-Path $fixtureSource 'Invoke-LocalPlay.ps1') -Value '# New release' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $fixtureInstall 'foreign.txt') -Value 'leave me alone' -Encoding UTF8
    try {
        & (Join-Path $fixtureSource 'Register-PlayProtocol.ps1') -InstallDirectory $fixtureInstall -PrepareOnly | Out-Null
        throw 'Preparation moved a handler directory containing foreign files.'
    } catch {
        if ($_.Exception.Message -match '^Preparation moved') { throw }
    }
    Remove-Item -LiteralPath (Join-Path $fixtureInstall 'foreign.txt') -Force
    & (Join-Path $fixtureSource 'Register-PlayProtocol.ps1') -InstallDirectory $fixtureInstall -PrepareOnly | Out-Null
    $backups = @(Get-ChildItem -LiteralPath (Split-Path -Parent $fixtureInstall) -Directory |
        Where-Object { $_.Name -like 'Fixture Handler-backup-*' })
    if ($backups.Count -ne 1 -or
        (Get-FileHash -LiteralPath (Join-Path $backups[0].FullName 'Invoke-LocalPlay.ps1') -Algorithm SHA256).Hash -cne
            [BitConverter]::ToString(([Security.Cryptography.SHA256]::Create()).ComputeHash($fixtureOriginalHelperBytes)).Replace('-', '')) {
        throw 'Legitimate update did not preserve the old owned handler.'
    }
    $ErrorActionPreference = 'Continue'
    & $fixtureHost 'posle://play' 2>&1 | Out-Null
    $ErrorActionPreference = 'Stop'
    if ($LASTEXITCODE -ne 0 -or
        (Get-Content -LiteralPath (Join-Path $fixtureInstall 'invoked.txt') -Raw).Trim() -cne 'posle://play') {
        throw 'Updated handler did not dispatch the new pinned harmless fixture.'
    }
    $afterKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Classes\posle')
    $afterCommand = if ($afterKey) {
        $commandKey = $afterKey.OpenSubKey('shell\open\command')
        if ($commandKey) { [string]$commandKey.GetValue('') } else { $null }
    } else { $null }
    if ($afterKey) { $afterKey.Close() }
    if ($beforeCommand -cne $afterCommand) { throw 'A plan-only operation changed the URI command.' }

    try {
        & $register -InstallDirectory (Join-Path $env:TEMP 'outside-POSLE') -PrintPlan | Out-Null
        throw 'Registration accepted an installation root outside LOCALAPPDATA.'
    } catch {
        if ($_.Exception.Message -match '^Registration accepted') { throw }
    }
    Write-Host 'PASS: plans, WhatIf, isolated host preparation/idempotence, outside-root rejection; URI registry unchanged.'
} finally {
    $env:LOCALAPPDATA = $originalLocalAppData
    $resolved = [IO.Path]::GetFullPath($scratch)
    if ($resolved.StartsWith([IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\',
            [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $resolved).StartsWith('posle-protocol-plan-') -and
        (Test-Path -LiteralPath $resolved)) {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
