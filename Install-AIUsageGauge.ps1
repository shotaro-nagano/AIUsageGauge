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

function Ensure-SettingsFile {
    if (Test-Path -LiteralPath $settingsPath) {
        return
    }

    [ordered]@{
        RefreshSeconds = 180
        Placement = 'left'
        EnableCodex = $true
        EnableClaude = $true
        EnableNotifications = $true
        NotificationThresholdPercent = 10
        NotificationCooldownMinutes = 60
        StaleAfterMinutes = 5
        PersistWindowPosition = $true
        PackageName = 'AI-Usage-Gauge'
    } | ConvertTo-Json | Set-Content -LiteralPath $settingsPath -Encoding UTF8
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
