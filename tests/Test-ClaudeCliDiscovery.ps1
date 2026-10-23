param([string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path)
$ErrorActionPreference = 'Stop'
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot 'Invoke-ClaudeOAuthRefresh.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Refresh helper must parse.' }
$fn = $ast.Find({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-ClaudeCliPath'}, $true)
. ([scriptblock]::Create($fn.Extent.Text))
$temp = Join-Path ([IO.Path]::GetTempPath()) ('aiug-cli-test-' + [guid]::NewGuid())
try {
    $native = Join-Path $temp 'native/claude.exe'
    $root = Join-Path $temp 'desktop'
    New-Item -ItemType Directory -Path (Split-Path $native) -Force | Out-Null
    New-Item -ItemType File -Path $native | Out-Null
    if ((Get-ClaudeCliPath -Root $root -NativePath $native) -ne $native) { throw 'Missing Desktop directory must fall back to native CLI.' }
    New-Item -ItemType Directory -Path $root | Out-Null
    if ((Get-ClaudeCliPath -Root $root -NativePath $native) -ne $native) { throw 'Empty Desktop directory must fall back to native CLI.' }
    $older = Join-Path $root '1/claude.exe'
    $newer = Join-Path $root '2/claude.exe'
    foreach ($file in @($older, $newer)) {
        New-Item -ItemType Directory -Path (Split-Path $file) -Force | Out-Null
        New-Item -ItemType File -Path $file | Out-Null
    }
    (Get-Item $older).LastWriteTimeUtc = [datetime]::UtcNow.AddDays(-2)
    (Get-Item $newer).LastWriteTimeUtc = [datetime]::UtcNow.AddDays(-1)
    if ((Get-ClaudeCliPath -Root $root -NativePath $native) -ne $newer) { throw 'Desktop discovery must retain newest-file selection.' }
    $missing = Join-Path $temp 'missing'
    $failed = $false
    try { Get-ClaudeCliPath -Root $missing -NativePath (Join-Path $missing 'claude.exe') | Out-Null }
    catch { $failed = $_.Exception.Message -eq 'claude_cli_not_found' }
    if (-not $failed) { throw 'Missing installations must return a clear discovery error.' }
    Write-Host 'Claude CLI discovery tests passed'
} finally {
    if ([IO.Path]::GetFullPath($temp).StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()), [StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $temp -Recurse -Force }
}
