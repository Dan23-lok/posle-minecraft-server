# Runs a freshly compiled protocol host from a disposable directory.
# No URI scheme is registered and no real launcher is started.
$ErrorActionPreference = 'Stop'
$source = Join-Path $PSScriptRoot '..\client-pack\POSLEProtocolHost.cs'
$scratch = Join-Path $env:TEMP ('posle protocol host-' + [Guid]::NewGuid().ToString('N'))
$scratch = [IO.Path]::GetFullPath($scratch)
$originalModulePath = $env:PSModulePath
New-Item -ItemType Directory -Path $scratch -Force | Out-Null
try {
    $hostExe = Join-Path $scratch 'POSLEProtocolHost.exe'
    $marker = Join-Path $scratch 'invoked.txt'
    $fakeHelper = Join-Path $scratch 'Invoke-LocalPlay.ps1'
    @'
param([string]$PlayUri)
$ErrorActionPreference = 'Stop'
if (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'delay.flag')) {
    Start-Sleep -Milliseconds 700
}
# The real helper uses a Windows PowerShell 5.1 module command. The host must
# find that built-in module even when its parent process came from PowerShell 7.
Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'client-modpack.json') -Algorithm SHA256 | Out-Null
Add-Content -LiteralPath (Join-Path $PSScriptRoot 'invoked.txt') -Value $PlayUri -Encoding UTF8
'@ | Set-Content -LiteralPath $fakeHelper -Encoding UTF8
    $originalHelperBytes = [IO.File]::ReadAllBytes($fakeHelper)
    $readiness = Join-Path $scratch 'Forge-ClientReadiness.ps1'
    $manifest = Join-Path $scratch 'client-modpack.json'
    'function Test-ForgeReady { return $true }' | Set-Content -LiteralPath $readiness -Encoding UTF8
    '{"pack":"fixture"}' | Set-Content -LiteralPath $manifest -Encoding UTF8
    $sourceText = Get-Content -LiteralPath $source -Raw -Encoding UTF8
    $sourceText = $sourceText.Replace('POSLE_HELPER_SHA256_PLACEHOLDER',
        (Get-FileHash -LiteralPath $fakeHelper -Algorithm SHA256).Hash)
    $sourceText = $sourceText.Replace('POSLE_READINESS_SHA256_PLACEHOLDER',
        (Get-FileHash -LiteralPath $readiness -Algorithm SHA256).Hash)
    $sourceText = $sourceText.Replace('POSLE_MANIFEST_SHA256_PLACEHOLDER',
        (Get-FileHash -LiteralPath $manifest -Algorithm SHA256).Hash)
    $compiledSource = Join-Path $scratch 'Host.cs'
    Set-Content -LiteralPath $compiledSource -Value $sourceText -Encoding UTF8
    Add-Type -Path $compiledSource -OutputAssembly $hostExe -OutputType ConsoleApplication -ErrorAction Stop

    # Emulate an activation inherited from a PowerShell 7 caller. Its module
    # path can put a PS7 Utility module ahead of the Windows PowerShell copy.
    $pwshCommand = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    if ($pwshCommand) {
        $pwshModules = Join-Path (Split-Path -Parent $pwshCommand.Source) 'Modules'
        if (Test-Path -LiteralPath (Join-Path $pwshModules 'Microsoft.PowerShell.Utility')) {
            $env:PSModulePath = $pwshModules + ';' + $originalModulePath
        }
    }

    # Windows PowerShell 5 turns native stderr into a PowerShell error record
    # when ErrorActionPreference is Stop; these rejected cases are expected.
    $ErrorActionPreference = 'Continue'
    foreach ($uri in @('posle://play?cmd=calc', 'posle://play/extra',
            'posle://evil/play', 'posle://play" -MinecraftDirectory C:\')) {
        & $hostExe $uri 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 2) { throw "Host accepted unsafe URI: $uri (exit $LASTEXITCODE)" }
        if (Test-Path -LiteralPath $marker) { throw "Host dispatched unsafe URI: $uri" }
    }
    $expectedCount = 0
    foreach ($uri in @('posle://play', 'posle://play/')) {
        Remove-Item -LiteralPath (Join-Path $scratch 'last-success-utc.txt') -Force -ErrorAction SilentlyContinue
        & $hostExe $uri 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Host rejected valid URI $uri (exit $LASTEXITCODE)" }
        $expectedCount++
        if (-not (Test-Path -LiteralPath $marker -PathType Leaf) -or
            @((Get-Content -LiteralPath $marker)).Count -ne $expectedCount -or
            @((Get-Content -LiteralPath $marker | Where-Object { $_ -cne 'posle://play' })).Count -ne 0) {
            throw 'Host did not dispatch the fixed canonical URI.'
        }
    }
    # Shell activation does not pass through the PowerShell native-command
    # invocation adapter. Launch the compiled host through raw .NET with the
    # PS7 module path that exposed the real Windows PowerShell 5.1 failure.
    if ($pwshCommand) {
        $pwshPath = & $pwshCommand.Source -NoLogo -NoProfile -Command '$env:PSModulePath'
        Remove-Item -LiteralPath (Join-Path $scratch 'last-success-utc.txt') -Force
        $rawStart = New-Object Diagnostics.ProcessStartInfo
        $rawStart.FileName = $hostExe
        $rawStart.Arguments = 'posle://play'
        $rawStart.WorkingDirectory = $scratch
        $rawStart.UseShellExecute = $false
        $rawStart.RedirectStandardOutput = $true
        $rawStart.RedirectStandardError = $true
        $rawStart.EnvironmentVariables['PSModulePath'] = [string]$pwshPath
        $raw = [Diagnostics.Process]::Start($rawStart)
        $raw.WaitForExit()
        $rawError = $raw.StandardError.ReadToEnd()
        if ($raw.ExitCode -ne 0 -or @((Get-Content -LiteralPath $marker)).Count -ne 3) {
            throw "Raw activation could not load built-in PowerShell modules: exit $($raw.ExitCode); $rawError"
        }
    }
    & $hostExe 'posle://play' 2>&1 | Out-Null
    $expectedCount = if ($pwshCommand) { 3 } else { 2 }
    if ($LASTEXITCODE -ne 0 -or @((Get-Content -LiteralPath $marker)).Count -ne $expectedCount) {
        throw 'Repeated URI activation launched the helper again.'
    }
    & $hostExe 'posle://play' 'posle://play/' 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 2 -or @((Get-Content -LiteralPath $marker)).Count -ne $expectedCount) {
        throw 'Host accepted an extra argument.'
    }
    'Set-Content -LiteralPath (Join-Path $PSScriptRoot "invoked.txt") -Value TAMPERED' |
        Set-Content -LiteralPath $fakeHelper -Encoding UTF8
    & $hostExe 'posle://play' 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 5 -or @((Get-Content -LiteralPath $marker)).Count -ne $expectedCount) {
        throw 'Host executed a helper changed after installation.'
    }
    [IO.File]::WriteAllBytes($fakeHelper, $originalHelperBytes)
    foreach ($pinnedFile in @($readiness, $manifest)) {
        $originalBytes = [IO.File]::ReadAllBytes($pinnedFile)
        'changed' | Set-Content -LiteralPath $pinnedFile -Encoding UTF8
        & $hostExe 'posle://play' 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 5 -or @((Get-Content -LiteralPath $marker)).Count -ne $expectedCount) {
            throw "Host accepted modified dependency: $pinnedFile"
        }
        [IO.File]::WriteAllBytes($pinnedFile, $originalBytes)
    }
    Remove-Item -LiteralPath $marker -Force
    Remove-Item -LiteralPath (Join-Path $scratch 'last-success-utc.txt') -Force -ErrorAction SilentlyContinue
    New-Item -ItemType File -Path (Join-Path $scratch 'delay.flag') | Out-Null
    $first = Start-Process -FilePath $hostExe -ArgumentList 'posle://play' -PassThru -WindowStyle Hidden
    $second = Start-Process -FilePath $hostExe -ArgumentList 'posle://play' -PassThru -WindowStyle Hidden
    $first.WaitForExit()
    $second.WaitForExit()
    if ($first.ExitCode -ne 0 -or $second.ExitCode -ne 0 -or
        @((Get-Content -LiteralPath $marker)).Count -ne 1) {
        throw 'Concurrent URI activations both ran the helper or failed unexpectedly.'
    }
    # Independent installations must not suppress one another. This also
    # keeps isolated CI fixtures from sharing a machine-wide user mutex.
    $other = Join-Path $scratch 'other fixture'
    New-Item -ItemType Directory -Path $other | Out-Null
    foreach ($name in @('POSLEProtocolHost.exe', 'Invoke-LocalPlay.ps1',
            'Forge-ClientReadiness.ps1', 'client-modpack.json', 'delay.flag')) {
        Copy-Item -LiteralPath (Join-Path $scratch $name) -Destination $other
    }
    Remove-Item -LiteralPath $marker -Force
    Remove-Item -LiteralPath (Join-Path $scratch 'last-success-utc.txt') -Force
    $first = Start-Process -FilePath $hostExe -ArgumentList 'posle://play' -PassThru -WindowStyle Hidden
    $second = Start-Process -FilePath (Join-Path $other 'POSLEProtocolHost.exe') `
        -ArgumentList 'posle://play' -PassThru -WindowStyle Hidden
    $first.WaitForExit()
    $second.WaitForExit()
    if ($first.ExitCode -ne 0 -or $second.ExitCode -ne 0 -or
        @((Get-Content -LiteralPath $marker)).Count -ne 1 -or
        @((Get-Content -LiteralPath (Join-Path $other 'invoked.txt'))).Count -ne 1) {
        throw 'Independent handler installations interfered with each other.'
    }
    Write-Host 'PASS: fixed URI, runtime hash pinning, sequential/concurrent duplicate suppression; no registry or launcher changes.'
} finally {
    $env:PSModulePath = $originalModulePath
    $resolved = [IO.Path]::GetFullPath($scratch)
    if ($resolved.StartsWith([IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\',
            [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $resolved).StartsWith('posle protocol host-')) {
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
    }
}
