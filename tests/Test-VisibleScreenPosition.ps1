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

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
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

$functionDefinition = $scriptAst.Find({
    param($ast)
    $ast -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $ast.Name -eq 'ConvertTo-VisibleGaugePosition'
}, $true)

if ($null -eq $functionDefinition) {
    throw 'ConvertTo-VisibleGaugePosition function is missing from Start-AIUsageGauge.ps1'
}

Invoke-Expression $functionDefinition.Extent.Text

$primaryArea = [pscustomobject]@{
    Left = 0
    Top = 0
    Right = 1920
    Bottom = 1040
}
$leftArea = [pscustomobject]@{
    Left = -1280
    Top = -200
    Right = 0
    Bottom = 824
}

$visible = ConvertTo-VisibleGaugePosition -Left 100 -Top 120 -Width 142 -Height 132 -WorkingAreas @($primaryArea) -Margin 6
Assert-Equal 100 $visible.Left 'An already-visible left coordinate must remain unchanged'
Assert-Equal 120 $visible.Top 'An already-visible top coordinate must remain unchanged'
Assert-True (-not $visible.Corrected) 'An already-visible position must not be marked corrected'

$halfDipCorrection = ConvertTo-VisibleGaugePosition -Left 5.5 -Top 120 -Width 142 -Height 132 -WorkingAreas @($primaryArea) -Margin 6
Assert-Equal 6 $halfDipCorrection.Left 'Clamping must still return the safe coordinate at the tolerance boundary'
Assert-True (-not $halfDipCorrection.Corrected) 'A correction of exactly 0.5 DIP must remain within tolerance'

$overHalfDipCorrection = ConvertTo-VisibleGaugePosition -Left 5.4 -Top 120 -Width 142 -Height 132 -WorkingAreas @($primaryArea) -Margin 6
Assert-True $overHalfDipCorrection.Corrected 'A correction greater than 0.5 DIP must be reported'

$negativeMonitor = ConvertTo-VisibleGaugePosition -Left -1500 -Top 100 -Width 142 -Height 132 -WorkingAreas @($primaryArea, $leftArea) -Margin 6
Assert-Equal -1274 $negativeMonitor.Left 'A negative-coordinate monitor must be selected and clamped at its left margin'
Assert-Equal 100 $negativeMonitor.Top 'Clamping on a negative-coordinate monitor must preserve a visible top coordinate'
Assert-True $negativeMonitor.Corrected 'An off-screen negative coordinate must be marked corrected'
Assert-True (($negativeMonitor.Left + 142) -le ($leftArea.Right - 6)) 'The full window must fit within the selected negative-coordinate monitor'

$wideArea = [pscustomobject]@{
    Left = 0
    Top = 0
    Right = 1000
    Bottom = 800
}
$nearArea = [pscustomobject]@{
    Left = 1300
    Top = 0
    Right = 1400
    Bottom = 800
}
$nearestRectangle = ConvertTo-VisibleGaugePosition -Left 1050 -Top 100 -Width 142 -Height 132 -WorkingAreas @($wideArea, $nearArea) -Margin 6
Assert-Equal 852 $nearestRectangle.Left 'Monitor selection must use distance to the nearest rectangle point'

$removedMonitor = ConvertTo-VisibleGaugePosition -Left 5000 -Top 3000 -Width 142 -Height 132 -WorkingAreas @($leftArea, $primaryArea) -Margin 6
Assert-Equal 1772 $removedMonitor.Left 'A removed-monitor position must clamp to the nearest active working area horizontally'
Assert-Equal 902 $removedMonitor.Top 'A removed-monitor position must clamp to the nearest active working area vertically'
Assert-True $removedMonitor.Corrected 'A removed-monitor position must be marked corrected'
Assert-True ($removedMonitor.Left -ge ($primaryArea.Left + 6)) 'The corrected window left edge must include the screen margin'
Assert-True (($removedMonitor.Left + 142) -le ($primaryArea.Right - 6)) 'The corrected full window width must remain inside the selected working area'
Assert-True ($removedMonitor.Top -ge ($primaryArea.Top + 6)) 'The corrected window top edge must include the screen margin'
Assert-True (($removedMonitor.Top + 132) -le ($primaryArea.Bottom - 6)) 'The corrected full window height must remain inside the selected working area'

$nanArea = [pscustomobject]@{
    Left = [double]::NaN
    Top = 0
    Right = 100
    Bottom = 100
}
$extremeOffset = ConvertTo-VisibleGaugePosition -Left 1e200 -Top 1e200 -Width 142 -Height 132 -WorkingAreas @($nanArea, $leftArea, $primaryArea) -Margin 6
Assert-True $extremeOffset.Corrected 'A finite extreme offset must select a valid working area and report correction'
Assert-True (-not [double]::IsNaN($extremeOffset.Left) -and -not [double]::IsInfinity($extremeOffset.Left)) 'An extreme horizontal offset must clamp to a finite coordinate'
Assert-True (-not [double]::IsNaN($extremeOffset.Top) -and -not [double]::IsInfinity($extremeOffset.Top)) 'An extreme vertical offset must clamp to a finite coordinate'
$extremeFitsWorkingArea = $false
foreach ($area in @($leftArea, $primaryArea)) {
    if (
        $extremeOffset.Left -ge ($area.Left + 6) -and
        ($extremeOffset.Left + 142) -le ($area.Right - 6) -and
        $extremeOffset.Top -ge ($area.Top + 6) -and
        ($extremeOffset.Top + 132) -le ($area.Bottom - 6)
    ) {
        $extremeFitsWorkingArea = $true
    }
}
Assert-True $extremeFitsWorkingArea 'The full window at an extreme finite offset must clamp inside a valid working area'

$emptyAreas = ConvertTo-VisibleGaugePosition -Left 321 -Top -654 -Width 142 -Height 132 -WorkingAreas @() -Margin 6
Assert-Equal 321 $emptyAreas.Left 'An empty working-area list must preserve the original left coordinate'
Assert-Equal -654 $emptyAreas.Top 'An empty working-area list must preserve the original top coordinate'
Assert-True (-not $emptyAreas.Corrected) 'An empty working-area list must not report a correction'

$smallArea = [pscustomobject]@{
    Left = 0
    Top = 0
    Right = 100
    Bottom = 80
}
$oversized = ConvertTo-VisibleGaugePosition -Left 500 -Top 500 -Width 120 -Height 90 -WorkingAreas @($smallArea) -Margin 6
Assert-Equal -10 $oversized.Left 'An oversized window must be centered safely on the selected area horizontally'
Assert-Equal -5 $oversized.Top 'An oversized window must be centered safely on the selected area vertically'
Assert-True $oversized.Corrected 'An oversized off-screen window must be marked corrected'

Write-Host 'Visible screen position tests passed'
