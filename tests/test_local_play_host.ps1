# Read-only host integration test. Requires an already installed POSLE client
# and a signed TLauncher; does not launch either the game or the launcher.
$ErrorActionPreference = 'Stop'
$helper = Join-Path $PSScriptRoot '..\client-pack\Invoke-LocalPlay.ps1'
$signedLauncher = @(
    (Join-Path $env:APPDATA '.minecraft\TLauncher.exe'),
    (Join-Path $env:APPDATA '.tlauncher\TLauncher.exe'),
    (Join-Path $env:LOCALAPPDATA 'TLauncher\TLauncher.exe')
) | Where-Object {
    if (-not (Test-Path -LiteralPath $_ -PathType Leaf)) { return $false }
    $signature = Get-AuthenticodeSignature -LiteralPath $_
    return $signature.Status -eq 'Valid' -and
        $signature.SignerCertificate.Subject -match '(^|, )O=TLauncher Inc\.(,|$)'
} | Select-Object -First 1
if (-not $signedLauncher) { throw 'A signed TLauncher is required for this host test.' }

function Assert-Accepted {
    param([string]$Uri, [string[]]$Candidates)
    $output = & $helper -PlayUri $Uri -TLauncherCandidatePaths $Candidates -DryRun 3>&1 6>&1 | Out-String
    if ($output -notmatch 'Client pack verified:' -or
        $output -notmatch 'Dry run: TLauncher was not started') {
        throw "Expected successful dry run for $Uri. Actual output: $output"
    }
}

function Assert-Rejected {
    param([string]$Uri)
    try {
        & $helper -PlayUri $Uri -DryRun | Out-Null
    } catch {
        if ($_.Exception.Message -match '^Only posle://play') { return }
        throw "Wrong rejection for $Uri`: $($_.Exception.Message)"
    }
    throw "Unsafe URI was accepted: $Uri"
}

Assert-Accepted -Uri 'posle://play' -Candidates @($signedLauncher)
Assert-Accepted -Uri 'posle://play/' -Candidates @($signedLauncher)
Assert-Accepted -Uri 'posle://play/' -Candidates @((Join-Path $env:TEMP 'missing-posle-launcher.exe'), $signedLauncher)
Assert-Accepted -Uri 'posle://play/' -Candidates @((Join-Path $env:TEMP 'missing-posle-launcher.exe'),
    (Join-Path $env:TEMP 'also-missing-posle-launcher.exe'), $signedLauncher)
Assert-Accepted -Uri 'posle://play/' -Candidates @($PSCommandPath, $signedLauncher)
foreach ($uri in @('posle://play/?cmd=calc', 'posle://play/#fragment', 'posle://play/extra',
        'posle://play/%2e', 'posle://evil/play', 'posle://play:123/')) {
    Assert-Rejected -Uri $uri
}
Write-Host 'PASS: two valid URI forms, fallback to candidates 2/3 and past an unsigned file, six unsafe URI rejections; no program launched.'
