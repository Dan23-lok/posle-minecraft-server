# The opt-out and unsupported custom-directory paths must not touch the real
# protocol association or ask a question during automated installations.
$ErrorActionPreference = 'Stop'
$configure = Join-Path $PSScriptRoot '..\client-pack\Configure-WebsitePlay.ps1'
$subkey = 'Software\Classes\posle'
function Get-AssociationCommand {
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($subkey)
    if (-not $key) { return $null }
    try {
        $command = $key.OpenSubKey('shell\open\command')
        try { if ($command) { return [string]$command.GetValue('') } }
        finally { if ($command) { $command.Close() } }
    } finally { $key.Close() }
    return $null
}
$before = Get-AssociationCommand
& $configure -Decision Skip | Out-Null
$custom = Join-Path $env:TEMP ('posle-test-client-' + [Guid]::NewGuid().ToString('N'))
& $configure -Decision Enable -MinecraftDirectory $custom 3>&1 | Out-Null
if ((Get-AssociationCommand) -cne $before -or (Test-Path -LiteralPath $custom)) {
    throw 'Skipping or using an unsupported client directory changed the URI association or files.'
}
Write-Host 'PASS: explicit skip and custom client folder leave the URI association unchanged.'
