$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Net.Http

$installer = Join-Path $PSScriptRoot '..\client-pack\Install-HorrorClient.ps1'
$tokens = $null; $parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($installer, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -ne 0) { throw 'Installer parse error.' }
foreach ($name in @('Get-AllowedDownloadUri', 'Save-AllowedDownload')) {
    $function = $ast.Find({ param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
    }, $true)
    if (-not $function) { throw "Missing installer function: $name" }
    . ([scriptblock]::Create($function.Extent.Text))
}

Add-Type -ReferencedAssemblies @('System.Net.Http', 'System.Net.Primitives') -TypeDefinition @'
using System;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;

public sealed class PosleBodyStream : Stream {
    private readonly byte[] data;
    private int position;
    private readonly bool stall;
    public PosleBodyStream(byte[] data, bool stall) { this.data = data; this.stall = stall; }
    public override bool CanRead { get { return true; } }
    public override bool CanSeek { get { return false; } }
    public override bool CanWrite { get { return false; } }
    public override long Length { get { throw new NotSupportedException(); } }
    public override long Position { get { throw new NotSupportedException(); } set { throw new NotSupportedException(); } }
    public override void Flush() { }
    public override long Seek(long offset, SeekOrigin origin) { throw new NotSupportedException(); }
    public override void SetLength(long value) { throw new NotSupportedException(); }
    public override void Write(byte[] buffer, int offset, int count) { throw new NotSupportedException(); }
    public override int Read(byte[] buffer, int offset, int count) {
        if (stall) { throw new InvalidOperationException("Use ReadAsync for stalled stream."); }
        int copied = Math.Min(count, data.Length - position);
        Array.Copy(data, position, buffer, offset, copied);
        position += copied;
        return copied;
    }
    public override async Task<int> ReadAsync(byte[] buffer, int offset, int count, CancellationToken token) {
        if (stall) { await Task.Delay(Timeout.Infinite, token); return 0; }
        return Read(buffer, offset, count);
    }
}

public sealed class PosleBodyHandler : HttpMessageHandler {
    private readonly Stream body;
    public PosleBodyHandler(Stream body) { this.body = body; }
    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token) {
        return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) {
            Content = new StreamContent(body)
        });
    }
}
'@

function Assert-True {
    param([bool]$Condition, [string]$Case)
    if (-not $Condition) { throw $Case }
}

$allowedHosts = @('cdn.modrinth.com')
$uri = 'https://cdn.modrinth.com/fixture.jar'

$oversize = [PosleBodyStream]::new([byte[]](1,2,3,4,5,6,7,8), $false)
$handler = [PosleBodyHandler]::new($oversize)
$client = [Net.Http.HttpClient]::new($handler)
$destination = [IO.Path]::GetTempFileName()
try {
    $message = $null
    try {
        Save-AllowedDownload -Url $uri -Destination $destination -AllowedHosts $allowedHosts `
            -Client $client -MaxBytes 4 -BodyTimeout ([TimeSpan]::FromSeconds(1))
    } catch { $message = $_.Exception.Message }
    Assert-True ($message -match 'size limit') 'oversize response was not rejected by byte limit'
    Assert-True ((Get-Item -LiteralPath $destination).Length -le 4) 'oversize response wrote beyond byte limit'
} finally {
    $client.Dispose(); $handler.Dispose(); $oversize.Dispose()
    if ([IO.File]::Exists($destination)) { [IO.File]::Delete($destination) }
}

$stalled = [PosleBodyStream]::new([byte[]]@(), $true)
$handler = [PosleBodyHandler]::new($stalled)
$client = [Net.Http.HttpClient]::new($handler)
$destination = [IO.Path]::GetTempFileName()
try {
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $message = $null
    try {
        Save-AllowedDownload -Url $uri -Destination $destination -AllowedHosts $allowedHosts `
            -Client $client -MaxBytes 4 -BodyTimeout ([TimeSpan]::FromMilliseconds(200))
    } catch { $message = $_.Exception.Message }
    $timer.Stop()
    Assert-True ($message -match 'timeout') 'stalled response was not stopped by body timeout'
    Assert-True ($timer.Elapsed.TotalSeconds -lt 2) 'stalled response took too long to stop'
} finally {
    $client.Dispose(); $handler.Dispose(); $stalled.Dispose()
    if ([IO.File]::Exists($destination)) { [IO.File]::Delete($destination) }
}

Write-Output 'Client streaming download bounds tests passed.'
