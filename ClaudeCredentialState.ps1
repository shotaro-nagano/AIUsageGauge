function ConvertFrom-ClaudeEpochMilliseconds {
    param($Value)

    if ($null -eq $Value) { return $null }
    $typeCode = [Type]::GetTypeCode($Value.GetType())
    if ($typeCode -notin @(
        [TypeCode]::SByte
        [TypeCode]::Byte
        [TypeCode]::Int16
        [TypeCode]::UInt16
        [TypeCode]::Int32
        [TypeCode]::UInt32
        [TypeCode]::Int64
        [TypeCode]::UInt64
    )) {
        return $null
    }

    try {
        $milliseconds = [int64]$Value
        if ($milliseconds -le 0) { return $null }
        [DateTimeOffset]::FromUnixTimeMilliseconds($milliseconds)
    } catch {
        $null
    }
}

function Get-ClaudeCredentialRefreshDecision {
    param(
        $Credentials,
        [DateTimeOffset]$Now = [DateTimeOffset]::UtcNow,
        [int]$RefreshWindowSeconds = 30,
        [int]$LoginRenewalWarningDays = 3
    )

    $oauth = $Credentials.claudeAiOauth
    $accessPresent = $null -ne $oauth -and -not [string]::IsNullOrWhiteSpace([string]$oauth.accessToken)
    $refreshPresent = $null -ne $oauth -and -not [string]::IsNullOrWhiteSpace([string]$oauth.refreshToken)
    $accessExpiresAt = if ($null -eq $oauth) { $null } else { ConvertFrom-ClaudeEpochMilliseconds $oauth.expiresAt }
    $refreshExpiryProperty = if ($null -eq $oauth) { $null } else { $oauth.PSObject.Properties['refreshTokenExpiresAt'] }
    $refreshExpiresAt = if ($null -eq $refreshExpiryProperty) { $null } else {
        ConvertFrom-ClaudeEpochMilliseconds $refreshExpiryProperty.Value
    }

    $accessFresh = $accessPresent -and $null -ne $accessExpiresAt -and
        $accessExpiresAt -gt $Now.AddSeconds([Math]::Max(0, $RefreshWindowSeconds))
    $refreshUsable = $refreshPresent -and
        ($null -eq $refreshExpiryProperty -or ($null -ne $refreshExpiresAt -and $refreshExpiresAt -gt $Now))
    $loginRenewalDue = $refreshPresent -and $null -ne $refreshExpiresAt -and
        $refreshExpiresAt -gt $Now -and $refreshExpiresAt -le $Now.AddDays([Math]::Max(1, $LoginRenewalWarningDays))

    $decision = if ($accessFresh) {
        'fresh'
    } elseif ($refreshUsable) {
        'refresh'
    } else {
        'login_required'
    }

    [pscustomobject]@{
        Decision = $decision
        AccessTokenPresent = $accessPresent
        RefreshTokenPresent = $refreshPresent
        AccessExpiresAt = $accessExpiresAt
        RefreshExpiresAt = $refreshExpiresAt
        LoginRenewalDue = $loginRenewalDue
    }
}
