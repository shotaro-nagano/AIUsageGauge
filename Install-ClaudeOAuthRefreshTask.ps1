param(
    [string]$TaskFolder = '\AIUsageGauge\',
    [string]$TaskName = 'ClaudeOAuthRefresh',
    [int]$IntervalMinutes = 5,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'

$scriptDir = if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) {
    Split-Path -Parent $MyInvocation.MyCommand.Path
} else {
    $PSScriptRoot
}

$helperPath = Join-Path $scriptDir 'Invoke-ClaudeOAuthRefresh.ps1'
if (!(Test-Path -LiteralPath $helperPath)) {
    throw "Invoke-ClaudeOAuthRefresh.ps1 was not found next to this installer."
}

$hiddenLauncherPath = Join-Path $scriptDir 'Invoke-ClaudeOAuthRefresh-hidden.vbs'
if (!(Test-Path -LiteralPath $hiddenLauncherPath)) {
    throw "Invoke-ClaudeOAuthRefresh-hidden.vbs was not found next to this installer."
}

$wscript = Join-Path $env:WINDIR 'System32\wscript.exe'
if (!(Test-Path -LiteralPath $wscript)) {
    throw "wscript.exe was not found."
}
$arguments = ('//B //Nologo "{0}"' -f $hiddenLauncherPath)

$service = New-Object -ComObject Schedule.Service
$service.Connect()

$root = $service.GetFolder('\')
$folderPath = $TaskFolder.Trim('\')
$folder = $root
if ($folderPath) {
    foreach ($part in $folderPath.Split('\')) {
        if ([string]::IsNullOrWhiteSpace($part)) { continue }
        try {
            $folder = $folder.GetFolder($part)
        } catch {
            $folder = $folder.CreateFolder($part)
        }
    }
}

$task = $service.NewTask(0)
$task.RegistrationInfo.Description = 'Keeps Claude OAuth credentials fresh for AI Usage Gauge without logging token values.'
$task.Settings.Enabled = $true
$task.Settings.Hidden = $true
$task.Settings.StartWhenAvailable = $true
$task.Settings.WakeToRun = $true
$task.Settings.DisallowStartIfOnBatteries = $false
$task.Settings.StopIfGoingOnBatteries = $false
$task.Settings.MultipleInstances = 2

$timeTrigger = $task.Triggers.Create(1)
$timeTrigger.Enabled = $true
$timeTrigger.StartBoundary = (Get-Date).AddMinutes(1).ToString('yyyy-MM-ddTHH:mm:ss')
$timeTrigger.Repetition.Interval = ('PT{0}M' -f $IntervalMinutes)
$timeTrigger.Repetition.Duration = 'P3650D'

$wakeTrigger = $task.Triggers.Create(0)
$wakeTrigger.Enabled = $true
$wakeTrigger.Subscription = @'
<QueryList>
  <Query Id="0" Path="System">
    <Select Path="System">*[System[Provider[@Name='Microsoft-Windows-Power-Troubleshooter'] and EventID=1]]</Select>
  </Query>
</QueryList>
'@

$logonTrigger = $task.Triggers.Create(9)
$logonTrigger.Enabled = $true

$action = $task.Actions.Create(0)
$action.Path = $wscript
$action.Arguments = $arguments
$action.WorkingDirectory = $scriptDir

$null = $folder.RegisterTaskDefinition($TaskName, $task, 6, $null, $null, 3)

if (-not $Quiet) {
    Write-Host ('Installed scheduled task {0}{1}; interval {2} minutes' -f $TaskFolder, $TaskName, $IntervalMinutes)
}
