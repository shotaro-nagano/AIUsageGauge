param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
)

$ErrorActionPreference = 'Stop'
$assertionFailures = [System.Collections.Generic.List[string]]::new()

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

function Assert-Throws {
    param(
        [scriptblock]$Action,
        [string]$ExpectedMessage,
        [string]$Message
    )

    try {
        & $Action
    } catch {
        if ($_.Exception.Message -ne $ExpectedMessage) {
            throw "$Message. Expected exception: $ExpectedMessage; Actual: $($_.Exception.Message)"
        }
        return
    }

    $script:assertionFailures.Add("$Message. Expected exception: $ExpectedMessage") | Out-Null
}

function Assert-Matches {
    param(
        [string]$Actual,
        [string]$Pattern,
        [string]$Message
    )

    if ($Actual -notmatch $Pattern) {
        throw "$Message. Pattern not found: $Pattern"
    }
}

function Assert-NotMatches {
    param(
        [string]$Actual,
        [string]$Pattern,
        [string]$Message
    )

    if ($Actual -match $Pattern) {
        throw "$Message. Unexpected pattern found: $Pattern"
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

function Get-FunctionDefinitionAst([string]$FunctionName) {
    $scriptAst.Find({
        param($ast)
        $ast -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $ast.Name -eq $FunctionName
    }, $true)
}

$requiredFunctions = @(
    'Clamp-Percent'
    'Convert-CodexRateLimitWindows'
    'Set-Row'
    'Set-RowUnavailable'
    'Format-Duration'
    'Format-OptionalDuration'
    'Update-Usage'
)
$functionDefinitions = @{}
foreach ($functionName in $requiredFunctions) {
    $definition = Get-FunctionDefinitionAst $functionName

    if ($null -eq $definition) {
        throw "$functionName function is missing from Start-AIUsageGauge.ps1"
    }

    $functionDefinitions[$functionName] = $definition
    Invoke-Expression $definition.Extent.Text
}

$setRowText = $functionDefinitions['Set-Row'].Extent.Text
$setRowUnavailableText = $functionDefinitions['Set-RowUnavailable'].Extent.Text

Assert-Matches $setRowText '\$Row\.Value\.Foreground\s*=\s*[''"]#f8fafc[''"]' 'Set-Row must restore the available value foreground'
Assert-Matches $setRowUnavailableText '\$innerWidth\s*=\s*\[Math\]::Max\(0,\s*\$Row\.Battery\.ActualWidth\s*-\s*4\)' 'Set-RowUnavailable must compute the row inner width'
Assert-Matches $setRowUnavailableText 'if\s*\(\$innerWidth\s*-eq\s*0\)\s*\{\s*\$innerWidth\s*=\s*80\s*\}' 'Set-RowUnavailable must preserve the inner width fallback'
Assert-Matches $setRowUnavailableText '\$Row\.Fill\.Width\s*=\s*2\b' 'Set-RowUnavailable must render a minimal fill'
Assert-Matches $setRowUnavailableText '\$Row\.Fill\.Fill\s*=\s*[''"]#475569[''"]' 'Set-RowUnavailable must use the neutral gray fill'
Assert-Matches $setRowUnavailableText '\$Row\.Value\.Text\s*=\s*[''"]--[''"]' 'Set-RowUnavailable must show the unavailable value literal'
Assert-Matches $setRowUnavailableText '\$Row\.Value\.Foreground\s*=\s*[''"]#94a3b8[''"]' 'Set-RowUnavailable must use the muted value foreground'

Assert-Equal '--' (Format-OptionalDuration $null) 'Null reset duration must render as unavailable'
Assert-Equal (Format-Duration 0) (Format-OptionalDuration 0) 'Zero reset duration must be formatted as an available value'

$updateUsageText = $functionDefinitions['Update-Usage'].Extent.Text
$codexBlockMatch = [regex]::Match($updateUsageText, '(?s)# Codex(?<Body>.*?)# Claude')
if (-not $codexBlockMatch.Success) {
    throw 'Codex UI block is missing from Update-Usage'
}
$codexUiBlock = $codexBlockMatch.Groups['Body'].Value

foreach ($propertyName in @('ShortRemaining', 'LongRemaining', 'ShortReset', 'LongReset')) {
    Assert-Matches $codexUiBlock ('\$usage\.' + $propertyName + '\b') "Codex UI must consume $propertyName"
}

Assert-NotMatches $codexUiBlock '\$usage\.(PrimaryRemaining|WeeklyRemaining|PrimaryReset|WeeklyReset)\b' 'Codex UI must not reference legacy window properties'
Assert-Matches $codexUiBlock '(?s)if\s*\(\s*\$null\s*-ne\s*\$usage\.ShortRemaining\s*\)\s*\{\s*Set-Row\s+\$primaryRow\s+\$usage\.ShortRemaining.*?Notify-IfLowRemaining[^\r\n]*\$usage\.ShortRemaining\s*\}\s*else\s*\{\s*Set-RowUnavailable\s+\$primaryRow\s*\}' 'Short remaining notification must be guarded by availability'
Assert-Matches $codexUiBlock '(?s)if\s*\(\s*\$null\s*-ne\s*\$usage\.LongRemaining\s*\)\s*\{\s*Set-Row\s+\$weeklyRow\s+\$usage\.LongRemaining.*?Notify-IfLowRemaining[^\r\n]*\$usage\.LongRemaining\s*\}\s*else\s*\{\s*Set-RowUnavailable\s+\$weeklyRow\s*\}' 'Long remaining notification must be guarded by availability'
Assert-Matches $codexUiBlock '\$footer\.Text\s*=\s*\(''reset \{0\} / \{1\}''\s*-f\s*\(Format-OptionalDuration\s+\$usage\.ShortReset\),\s*\(Format-OptionalDuration\s+\$usage\.LongReset\)\)' 'Codex footer must format short and long resets independently'

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

$invalidDurationMessage = 'Codex rate limit window must include a positive limit_window_seconds value.'
$invalidDurationCases = @(
    [pscustomobject]@{
        Name = 'Missing duration'
        Window = @{ used_percent = 10; reset_after_seconds = 100 }
    }
    [pscustomobject]@{
        Name = 'Zero duration'
        Window = @{ used_percent = 10; limit_window_seconds = 0; reset_after_seconds = 100 }
    }
    [pscustomobject]@{
        Name = 'Negative duration'
        Window = @{ used_percent = 10; limit_window_seconds = -1; reset_after_seconds = 100 }
    }
)

foreach ($case in $invalidDurationCases) {
    $assertThrowsParams = @{
        Action = {
            Convert-CodexRateLimitWindows -PrimaryWindow $case.Window -SecondaryWindow $null | Out-Null
        }
        ExpectedMessage = $invalidDurationMessage
        Message = "$($case.Name) must be rejected"
    }
    Assert-Throws @assertThrowsParams
}

$shortBoundary = Convert-CodexRateLimitWindows -PrimaryWindow @{
    used_percent = 25
    limit_window_seconds = 86400
    reset_after_seconds = 100
} -SecondaryWindow $null

Assert-Equal 75 $shortBoundary.ShortRemaining 'Exactly 86400 seconds must map to ShortRemaining'
Assert-Null $shortBoundary.LongRemaining 'Exactly 86400 seconds must not populate LongRemaining'

$longBoundary = Convert-CodexRateLimitWindows -PrimaryWindow @{
    used_percent = 25
    limit_window_seconds = 86401
    reset_after_seconds = 100
} -SecondaryWindow $null

Assert-Null $longBoundary.ShortRemaining 'Exactly 86401 seconds must not populate ShortRemaining'
Assert-Equal 75 $longBoundary.LongRemaining 'Exactly 86401 seconds must map to LongRemaining'

if ($assertionFailures.Count -gt 0) {
    throw ($assertionFailures -join [Environment]::NewLine)
}

Write-Host 'Codex window mapping tests passed'
