param(
    [string]$InstallDir = $PSScriptRoot,
    [string]$PackageOutputDir = (Join-Path $PSScriptRoot 'dist'),
    [switch]$SkipShortcuts,
    [switch]$SkipStartup,
    [switch]$SkipScheduledTasks,
    [switch]$SkipPackage,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'

$InstallDir = (Resolve-Path -LiteralPath $InstallDir).Path
$hiddenLauncherPath = Join-Path $InstallDir 'Start-AIUsageGauge-hidden.vbs'
$taskInstallerPath = Join-Path $InstallDir 'Install-ClaudeOAuthRefreshTask.ps1'
$settingsPath = Join-Path $InstallDir 'settings.json'

function Write-InstallStatus {
    param([string]$Message)
    if (-not $Quiet) {
        Write-Host $Message
    }
}

function New-AIUsageGaugeShortcut {
    param(
        [string]$ShortcutPath,
        [string]$TargetPath,
        [string]$Arguments,
        [string]$WorkingDirectory
    )

    $parent = Split-Path -Parent $ShortcutPath
    if (!(Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }

    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($ShortcutPath)
    $shortcut.TargetPath = $TargetPath
    $shortcut.Arguments = $Arguments
    $shortcut.WorkingDirectory = $WorkingDirectory
    $shortcut.Description = 'AI Usage Gauge'
    $shortcut.Save()
}

function Write-SettingsJsonAtomically {
    param($Settings)

    $tempPath = "$settingsPath.$PID.tmp"
    try {
        $Settings | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $tempPath -Encoding UTF8
        [System.IO.File]::Move($tempPath, $settingsPath, $true)
    } catch {
        Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        throw
    }
}

function Ensure-SettingsFile {
    $defaults = [ordered]@{
        RefreshSeconds = 180
        Placement = 'left'
        EnableCodex = $true
        EnableClaude = $true
        EnableNotifications = $true
        NotificationThresholdPercent = 10
        NotificationCooldownMinutes = 60
        StaleAfterMinutes = 5
        LogRetentionDays = 2
        PersistWindowPosition = $true
        HealthHeartbeatSeconds = 30
        HealthStaleMinutes = 10
        HeartbeatConfirmationSeconds = 10
        ScreenMargin = 6
        PackageName = 'AI-Usage-Gauge'
    }

    if (!(Test-Path -LiteralPath $settingsPath)) {
        Write-SettingsJsonAtomically -Settings ([pscustomobject]$defaults)
        return
    }

    try {
        $settings = Get-Content -Raw -LiteralPath $settingsPath | ConvertFrom-Json
        if ($settings -isnot [System.Management.Automation.PSCustomObject]) {
            throw 'settings.json root must be an object.'
        }
        $changed = $false
        foreach ($entry in $defaults.GetEnumerator()) {
            if ($null -eq $settings.PSObject.Properties[$entry.Key]) {
                $settings | Add-Member -NotePropertyName $entry.Key -NotePropertyValue $entry.Value
                $changed = $true
            }
        }
        if ($changed) {
            Write-SettingsJsonAtomically -Settings $settings
        }
    } catch {
        throw "settings.json is malformed. Existing settings were not changed."
    }
}

function Install-Shortcuts {
    if (!(Test-Path -LiteralPath $hiddenLauncherPath)) {
        throw "Start-AIUsageGauge-hidden.vbs was not found in $InstallDir"
    }

    $wscript = Join-Path $env:WINDIR 'System32\wscript.exe'
    if (!(Test-Path -LiteralPath $wscript)) {
        throw "wscript.exe was not found."
    }

    $arguments = ('//B //Nologo "{0}"' -f $hiddenLauncherPath)

    if (-not $SkipShortcuts) {
        $desktop = [Environment]::GetFolderPath('Desktop')
        New-AIUsageGaugeShortcut -ShortcutPath (Join-Path $desktop 'AI Usage Gauge.lnk') -TargetPath $wscript -Arguments $arguments -WorkingDirectory $InstallDir
        Write-InstallStatus 'Desktop shortcut installed.'
    }

    if (-not $SkipStartup) {
        $startup = [Environment]::GetFolderPath('Startup')
        New-AIUsageGaugeShortcut -ShortcutPath (Join-Path $startup 'AI Usage Gauge.lnk') -TargetPath $wscript -Arguments $arguments -WorkingDirectory $InstallDir
        Write-InstallStatus 'Startup shortcut installed.'
    }
}

function Install-RefreshTask {
    if ($SkipScheduledTasks) {
        return
    }
    if (!(Test-Path -LiteralPath $taskInstallerPath)) {
        throw "Install-ClaudeOAuthRefreshTask.ps1 was not found in $InstallDir"
    }

    & $taskInstallerPath -IntervalMinutes 5 -Quiet | Out-Null
    Write-InstallStatus 'Claude refresh task installed.'
}

function New-ReleasePackage {
    if ($SkipPackage) {
        return
    }

    if (!(Test-Path -LiteralPath $PackageOutputDir)) {
        New-Item -ItemType Directory -Force -Path $PackageOutputDir | Out-Null
    }

    $packageName = 'AI-Usage-Gauge'
    try {
        $settings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
        if (-not [string]::IsNullOrWhiteSpace($settings.PackageName)) {
            $packageName = [string]$settings.PackageName
        }
    } catch {}

    $zipPath = Join-Path $PackageOutputDir ('{0}.zip' -f $packageName)
    if (Test-Path -LiteralPath $zipPath) {
        Remove-Item -LiteralPath $zipPath -Force
    }

    $packageFiles = @(
        'Start-AIUsageGauge.ps1',
        'Start-AIUsageGauge.cmd',
        'Start-AIUsageGauge-hidden.vbs',
        'ClaudeCredentialState.ps1',
        'Invoke-ClaudeOAuthRefresh.ps1',
        'Invoke-ClaudeOAuthRefresh-hidden.vbs',
        'Install-ClaudeOAuthRefreshTask.ps1',
        'Watch-AIUsageGaugeHealth.ps1',
        'Show-AIUsageGaugeStatus.ps1',
        'Install-AIUsageGauge.ps1',
        'Claude-relogin.cmd',
        'settings.json',
        'README.md',
        'LICENSE'
    ) | ForEach-Object { Join-Path $InstallDir $_ } | Where-Object { Test-Path -LiteralPath $_ }

    Compress-Archive -LiteralPath $packageFiles -DestinationPath $zipPath -Force
    Write-InstallStatus ('Release package created: {0}' -f $zipPath)
}

Ensure-SettingsFile
Install-Shortcuts
Install-RefreshTask
New-ReleasePackage
