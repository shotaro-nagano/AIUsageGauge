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

    throw "$Message. Expected exception: $ExpectedMessage"
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
    'Convert-ClaudeUsageResponse'
    'Convert-ClaudeResetToSeconds'
)

foreach ($functionName in $requiredFunctions) {
    $definition = Get-FunctionDefinitionAst $functionName
    if ($null -eq $definition) {
        throw "$functionName function is missing from Start-AIUsageGauge.ps1"
    }
    Invoke-Expression $definition.Extent.Text
}

$response = [pscustomobject]@{
    five_hour = [pscustomobject]@{
        utilization = 19
        resets_at = '2026-07-29T03:50:00Z'
    }
    seven_day = [pscustomobject]@{
        utilization = 4
        resets_at = '2026-08-04T23:00:00Z'
    }
    limits = @(
        [pscustomobject]@{
            kind = 'weekly_scoped'
            percent = 0
            scope = [pscustomobject]@{
                model = [pscustomobject]@{ display_name = 'Fable' }
            }
        }
    )
}
$now = [DateTimeOffset]::Parse('2026-07-29T03:20:00Z')
$actual = Convert-ClaudeUsageResponse -UsageResponse $response -Now $now

Assert-Equal 81 $actual.FiveHourRemaining '5h remaining'
Assert-Equal 96 $actual.SevenDayRemaining '7d remaining'
Assert-Equal 100 $actual.FableRemaining 'Fable remaining'
Assert-Equal 1800 $actual.FiveHourReset '5h reset'

$missingFable = Convert-ClaudeUsageResponse -UsageResponse ([pscustomobject]@{
    five_hour = $response.five_hour
    seven_day = $response.seven_day
    limits = @()
}) -Now $now
Assert-Null $missingFable.FableRemaining 'missing Fable'

$missingValues = Convert-ClaudeUsageResponse -UsageResponse ([pscustomobject]@{
    five_hour = $null
    seven_day = [pscustomobject]@{ utilization = $null; resets_at = $null }
    limits = @(
        [pscustomobject]@{
            kind = 'WEEKLY_SCOPED'
            percent = $null
            scope = [pscustomobject]@{
                model = [pscustomobject]@{ display_name = 'fable' }
            }
        }
    )
}) -Now $now
Assert-Null $missingValues.FiveHourRemaining 'missing 5h utilization'
Assert-Null $missingValues.FiveHourReset 'missing 5h reset'
Assert-Null $missingValues.SevenDayRemaining 'null 7d utilization'
Assert-Null $missingValues.SevenDayReset 'null 7d reset'
Assert-Null $missingValues.FableRemaining 'null Fable percent'

Assert-Equal 2 (Convert-ClaudeResetToSeconds '2026-07-29T03:20:01.001Z' $now) 'reset seconds must round up'
Assert-Equal 0 (Convert-ClaudeResetToSeconds '2026-07-29T03:19:59Z' $now) 'past reset must clamp to zero'
Assert-Null (Convert-ClaudeResetToSeconds $null $now) 'missing reset must remain null'

$invalidFable = [pscustomobject]@{
    five_hour = $response.five_hour
    seven_day = $response.seven_day
    limits = @(
        [pscustomobject]@{
            kind = 'weekly_scoped'
            percent = 'not-a-number'
            scope = [pscustomobject]@{
                model = [pscustomobject]@{ display_name = 'Fable' }
            }
        }
    )
}
Assert-Throws {
    Convert-ClaudeUsageResponse -UsageResponse $invalidFable -Now $now | Out-Null
} 'Fable percent must be numeric.' 'Nonnumeric Fable percent must be rejected'

Write-Host 'Claude usage mapping tests passed'
