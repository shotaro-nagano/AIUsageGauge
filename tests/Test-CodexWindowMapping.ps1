param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
)

$ErrorActionPreference = 'Stop'

function Assert-Equal {
    param(
        $Expected,
        $Actual,
        [string]$Message
    )

    if ($Expected -ne $Actual) {
        throw "$Message. Expected: $Expected; Actual: $Actual"
    }
}

function Assert-Null {
    param(
        $Actual,
        [string]$Message
    )

    if ($null -ne $Actual) {
        throw "$Message. Expected: null; Actual: $Actual"
    }
}

$startScript = Join-Path $RepoRoot 'Start-AIUsageGauge.ps1'
$tokens = $null
$parseErrors = $null
$scriptAst = [System.Management.Automation.Language.Parser]::ParseFile(
    $startScript,
    [ref]$tokens,
    [ref]$parseErrors
)

if ($parseErrors.Count -gt 0) {
    throw "Start-AIUsageGauge.ps1 has parse errors: $($parseErrors -join '; ')"
}

$requiredFunctions = @('Clamp-Percent', 'Convert-CodexRateLimitWindows')
foreach ($functionName in $requiredFunctions) {
    $definition = $scriptAst.Find({
        param($ast)
        $ast -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $ast.Name -eq $functionName
    }, $true)

    if ($null -eq $definition) {
        throw "$functionName function is missing from Start-AIUsageGauge.ps1"
    }

    Invoke-Expression $definition.Extent.Text
}

$weeklyOnly = Convert-CodexRateLimitWindows -PrimaryWindow @{
    used_percent = 33
    limit_window_seconds = 604800
    reset_after_seconds = 596050
} -SecondaryWindow $null

Assert-Null $weeklyOnly.ShortRemaining 'Weekly-only response must not populate ShortRemaining'
Assert-Equal 67 $weeklyOnly.LongRemaining 'Weekly-only response must map remaining percent to LongRemaining'
Assert-Null $weeklyOnly.ShortReset 'Weekly-only response must not populate ShortReset'
Assert-Equal 596050 $weeklyOnly.LongReset 'Weekly-only response must map reset time to LongReset'

$traditionalPair = Convert-CodexRateLimitWindows -PrimaryWindow @{
    used_percent = 20
    limit_window_seconds = 18000
    reset_after_seconds = 1000
} -SecondaryWindow @{
    used_percent = 40
    limit_window_seconds = 604800
    reset_after_seconds = 500000
}

Assert-Equal 80 $traditionalPair.ShortRemaining 'Traditional response must map primary remaining percent to ShortRemaining'
Assert-Equal 60 $traditionalPair.LongRemaining 'Traditional response must map secondary remaining percent to LongRemaining'
Assert-Equal 1000 $traditionalPair.ShortReset 'Traditional response must map primary reset time to ShortReset'
Assert-Equal 500000 $traditionalPair.LongReset 'Traditional response must map secondary reset time to LongReset'

Write-Host 'Codex window mapping tests passed'
