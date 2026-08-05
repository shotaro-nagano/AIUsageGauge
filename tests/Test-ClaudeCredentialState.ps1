param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
)

$ErrorActionPreference = 'Stop'

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    if ($Expected -ne $Actual) {
        throw "$Message. Expected: $Expected; Actual: $Actual"
    }
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

$stateScript = Join-Path $RepoRoot 'ClaudeCredentialState.ps1'
Assert-True (Test-Path -LiteralPath $stateScript) 'ClaudeCredentialState.ps1 is missing'

. $stateScript

$now = [DateTimeOffset]::Parse('2026-08-05T12:00:00Z')
function Convert-ToUnixMilliseconds([DateTimeOffset]$Value) {
    $Value.ToUnixTimeMilliseconds()
}

$fresh = Get-ClaudeCredentialRefreshDecision -Credentials ([pscustomobject]@{
    claudeAiOauth = [pscustomobject]@{
        accessToken = 'present'
        refreshToken = 'present'
        expiresAt = Convert-ToUnixMilliseconds $now.AddHours(1)
        refreshTokenExpiresAt = Convert-ToUnixMilliseconds $now.AddDays(5)
    }
}) -Now $now -RefreshWindowSeconds 30
Assert-Equal 'fresh' $fresh.Decision 'A usable access token must be treated as fresh'
Assert-Equal $false $fresh.LoginRenewalDue 'A refresh login with five days left must not warn yet'

$renewalDue = Get-ClaudeCredentialRefreshDecision -Credentials ([pscustomobject]@{
    claudeAiOauth = [pscustomobject]@{
        accessToken = 'present'
        refreshToken = 'present'
        expiresAt = Convert-ToUnixMilliseconds $now.AddHours(1)
        refreshTokenExpiresAt = Convert-ToUnixMilliseconds $now.AddDays(2)
    }
}) -Now $now -RefreshWindowSeconds 30
Assert-Equal 'fresh' $renewalDue.Decision 'An access token remains usable before login renewal'
Assert-Equal $true $renewalDue.LoginRenewalDue 'A refresh login inside three days must warn early'

$refreshable = Get-ClaudeCredentialRefreshDecision -Credentials ([pscustomobject]@{
    claudeAiOauth = [pscustomobject]@{
        accessToken = ''
        refreshToken = 'present'
        expiresAt = 0
        refreshTokenExpiresAt = Convert-ToUnixMilliseconds $now.AddDays(1)
    }
}) -Now $now -RefreshWindowSeconds 30
Assert-Equal 'refresh' $refreshable.Decision 'A valid refresh token must allow CLI refresh even when access is absent'

$expiredLogin = Get-ClaudeCredentialRefreshDecision -Credentials ([pscustomobject]@{
    claudeAiOauth = [pscustomobject]@{
        accessToken = ''
        refreshToken = ''
        expiresAt = 0
        refreshTokenExpiresAt = Convert-ToUnixMilliseconds $now.AddDays(-1)
    }
}) -Now $now -RefreshWindowSeconds 30
Assert-Equal 'login_required' $expiredLogin.Decision 'Expired empty credentials must require login'

$legacyRefresh = Get-ClaudeCredentialRefreshDecision -Credentials ([pscustomobject]@{
    claudeAiOauth = [pscustomobject]@{
        accessToken = 'present'
        refreshToken = 'present'
        expiresAt = Convert-ToUnixMilliseconds $now.AddMinutes(-1)
    }
}) -Now $now -RefreshWindowSeconds 30
Assert-Equal 'refresh' $legacyRefresh.Decision 'Legacy credentials without refresh expiry must remain refreshable'

$start = Get-Content -Raw -LiteralPath (Join-Path $RepoRoot 'Start-AIUsageGauge.ps1')
$helper = Get-Content -Raw -LiteralPath (Join-Path $RepoRoot 'Invoke-ClaudeOAuthRefresh.ps1')
$relogin = Get-Content -Raw -LiteralPath (Join-Path $RepoRoot 'Claude-relogin.cmd')
$installer = Get-Content -Raw -LiteralPath (Join-Path $RepoRoot 'Install-AIUsageGauge.ps1')
$tokens = $null
$parseErrors = $null
$startAst = [System.Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $RepoRoot 'Start-AIUsageGauge.ps1'),
    [ref]$tokens,
    [ref]$parseErrors
)
Assert-Equal 0 $parseErrors.Count 'Start script must parse before function inspection'
$failureStatusFunction = $startAst.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'Get-GaugeServiceFailureStatus'
}, $true)
Assert-True ($null -ne $failureStatusFunction) 'Get-GaugeServiceFailureStatus is missing'

Assert-True ($start -match 'ClaudeCredentialState\.ps1') 'Gauge must load the shared credential decision'
Assert-True ($helper -match 'ClaudeCredentialState\.ps1') 'Refresh helper must load the shared credential decision'
Assert-True ($start -match 'AIUG_LOGIN_REQUIRED') 'Gauge must use a stable login-required error'
Assert-True ($start -match "AIUG_TOKEN_EXPIRED\|AIUG_LOGIN_REQUIRED") 'UI must show relogin for both expired and missing credentials'
Assert-True ($failureStatusFunction.Extent.Text -match 'AIUG_LOGIN_REQUIRED') 'Login-required health must be classified as auth'
Assert-True ($start -match 'login renewal due') 'Gauge must warn before the refresh login expires'
Assert-True ($helper -match "'refresh_login_required'") 'Refresh helper must log the token-free login-required state'
$decisionIndex = $helper.IndexOf("'login_required'")
$cliStartIndex = $helper.IndexOf('$claude = Get-ClaudeCliPath')
Assert-True ($decisionIndex -ge 0 -and $decisionIndex -lt $cliStartIndex) 'Login-required credentials must be handled before CLI launch'
Assert-True ($relogin -match '(?i)auth\s+login\s+--claudeai') 'One-click relogin must invoke the current CLI auth command directly'
Assert-True ($relogin -notmatch '(?i)Type:\s*/login') 'Relogin must not require typing /login'
Assert-True ($installer -match "'ClaudeCredentialState\.ps1'") 'Release package must include the shared credential state script'

Write-Host 'Claude credential state tests passed'
