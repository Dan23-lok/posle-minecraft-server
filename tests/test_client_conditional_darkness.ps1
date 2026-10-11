$ErrorActionPreference = 'Stop'
$installer = Join-Path $PSScriptRoot '..\client-pack\Install-HorrorClient.ps1'
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($installer, [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) { throw 'Installer does not parse.' }
foreach ($name in @('Test-ValidFileName', 'Assert-NoReparsePoint',
        'Resolve-EffectiveShaderState', 'Test-SelectedClientFile')) {
    $functionAst = $ast.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
    }, $true)
    if (-not $functionAst) { throw "Missing function: $name" }
    . ([scriptblock]::Create($functionAst.Extent.Text))
}

$scratch = [IO.Path]::Combine([IO.Path]::GetTempPath(), 'posle-v11-shader-' + [Guid]::NewGuid().ToString('N'))
$config = Join-Path $scratch 'oculus.properties'
$shaderPacks = Join-Path $scratch 'shaderpacks'
try {
    [IO.Directory]::CreateDirectory($scratch) | Out-Null
    [IO.File]::WriteAllText($config, "shaderPack=DMS 1.0.3.zip`nenableShaders=true`n")
    if (-not (Resolve-EffectiveShaderState -OculusPath $config -ApplyPlannedSetting:$false -PlannedValue 'false' `
            -ShaderPackDirectory $shaderPacks -ManagedShaderNames @('DMS 1.0.3.zip'))) {
        throw 'Update did not preserve manually enabled shader.'
    }
    if (Resolve-EffectiveShaderState -OculusPath $config -ApplyPlannedSetting -PlannedValue 'false') {
        throw 'Explicit NoShader did not override enabled setting.'
    }
    $darkness = [pscustomobject]@{ folder='mods'; filename='darkness-1.20.1-1.0.2.jar'; install_when='shaders_disabled' }
    if (-not (Test-SelectedClientFile -Entry $darkness -ShadersEnabled:$false)) {
        throw 'Darkness must be installed for actual no-shader state.'
    }
    if (Test-SelectedClientFile -Entry $darkness -ShadersEnabled) {
        throw 'Darkness must be omitted for actual shader-enabled state.'
    }
    [IO.File]::WriteAllText($config, "enableShaders=maybe`n")
    $caught = $false
    try { Resolve-EffectiveShaderState -OculusPath $config -ApplyPlannedSetting:$false -PlannedValue 'false' `
        -ShaderPackDirectory $shaderPacks -ManagedShaderNames @('DMS 1.0.3.zip') | Out-Null }
    catch { $caught = $true }
    if (-not $caught) { throw 'Malformed Oculus state was silently inferred.' }
    $unknown = [pscustomobject]@{ folder='mods'; filename='unknown.jar'; install_when='surprise' }
    $caught = $false
    try { Test-SelectedClientFile -Entry $unknown -ShadersEnabled:$false | Out-Null }
    catch { $caught = $true }
    if (-not $caught) { throw 'Unknown manifest condition was silently accepted.' }
} finally {
    $parent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if ([IO.Directory]::Exists($scratch) -and [IO.Path]::GetFullPath($scratch).StartsWith($parent, [StringComparison]::OrdinalIgnoreCase)) {
        [IO.Directory]::Delete($scratch, $true)
    }
}
Write-Output 'Client conditional darkness policy passed.'
