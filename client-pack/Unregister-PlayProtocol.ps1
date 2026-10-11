[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [string]$InstallDirectory = (Join-Path $env:LOCALAPPDATA 'POSLE\PlayHandler'),
    [switch]$PrintPlan
)

# Removes only the per-user URI association that still points at the expected
# POSLE host. Client mods, saves, the launcher, and copied handler files stay.
$ErrorActionPreference = 'Stop'
$installDirectory = [IO.Path]::GetFullPath($InstallDirectory)
$localAppData = [IO.Path]::GetFullPath($env:LOCALAPPDATA).TrimEnd('\', '/')
if (-not $installDirectory.StartsWith($localAppData + '\',
        [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The play handler must be below the current user LOCALAPPDATA.'
}
$registryPath = 'HKEY_CURRENT_USER\Software\Classes\posle'
$registrySubkey = 'Software\Classes\posle'
$command = '"' + (Join-Path $installDirectory 'POSLEProtocolHost.exe') + '" "%1"'
$notifyPath = Join-Path $PSScriptRoot 'PlayProtocolShellNotify.ps1'
if ($PrintPlan) {
    [ordered]@{
        registry_path = $registryPath
        install_directory = $installDirectory
        command = $command
        action = 'Remove only the POSLE-managed per-user URI association; preserve all files.'
    } | ConvertTo-Json -Depth 3
    return
}

$userKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($registrySubkey)
if (-not $userKey) {
    Write-Host 'No per-user posle URI association exists.'
    return
}
try {
    $commandKey = $userKey.OpenSubKey('shell\open\command')
    $existingCommand = if ($commandKey) { [string]$commandKey.GetValue('') } else { '' }
    if ([string]$userKey.GetValue('POSLEManaged') -cne '1' -or
        [string]$userKey.GetValue('POSLEInstallDirectory') -cne $installDirectory -or
        [string]$userKey.GetValue('') -cne 'POSLE Minecraft Play' -or
        [string]$userKey.GetValue('URL Protocol') -cne '' -or
        $existingCommand -cne $command) {
        throw 'The posle URI association is not the expected POSLE registration; no key was removed.'
    }
    # DeleteSubKeyTree is safe only while every value and child key is ours.
    $rootValues = @($userKey.GetValueNames() | Sort-Object)
    $expectedValues = @('', 'POSLEInstallDirectory', 'POSLEManaged', 'URL Protocol' | Sort-Object)
    if (($rootValues -join "`0") -cne ($expectedValues -join "`0") -or
        (@($userKey.GetSubKeyNames()) -join "`0") -cne 'shell') {
        throw 'The URI key has additional values or child keys; no key was removed.'
    }
    $shellKey = $userKey.OpenSubKey('shell')
    $openKey = if ($shellKey) { $shellKey.OpenSubKey('open') } else { $null }
    if (-not $shellKey -or -not $openKey -or -not $commandKey -or
        @($shellKey.GetValueNames()).Count -ne 0 -or
        (@($shellKey.GetSubKeyNames()) -join "`0") -cne 'open' -or
        @($openKey.GetValueNames()).Count -ne 0 -or
        (@($openKey.GetSubKeyNames()) -join "`0") -cne 'command' -or
        (@($commandKey.GetValueNames()) -join "`0") -cne '' -or
        @($commandKey.GetSubKeyNames()).Count -ne 0) {
        throw 'The URI command tree has additional data; no key was removed.'
    }
    $openKey.Close()
    $shellKey.Close()
    $commandKey.Close()
} finally { $userKey.Close() }

if (-not $PSCmdlet.ShouldProcess($registryPath, 'Remove the POSLE play protocol for this Windows user')) {
    return
}
if (-not (Test-Path -LiteralPath $notifyPath -PathType Leaf)) {
    throw 'PlayProtocolShellNotify.ps1 is missing beside this script.'
}
[Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($registrySubkey, $false)
try {
    . $notifyPath
    Notify-PlayProtocolAssociationChanged
} catch {
    Write-Warning "The URI association was removed, but Windows shell notification failed: $_"
}
Write-Host 'Unregistered posle://play for this Windows user. Client files and handler files were preserved.'
