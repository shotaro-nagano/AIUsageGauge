param(
    [string]$TaskFolder = '\AIUsageGauge\',
    [string]$TaskName = 'ClaudeOAuthRefresh',
    [int]$IntervalMinutes = 1
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

$pwsh = (Get-Command pwsh -ErrorAction Stop).Source
$arguments = ('-NoProfile -ExecutionPolicy Bypass -File "{0}" -Quiet' -f $helperPath)

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
$task.Settings.Hidden = $false
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

$action = $task.Actions.Create(0)
$action.Path = $pwsh
$action.Arguments = $arguments
$action.WorkingDirectory = $scriptDir

$null = $folder.RegisterTaskDefinition($TaskName, $task, 6, $null, $null, 3)

Write-Host ('Installed scheduled task {0}{1}' -f $TaskFolder, $TaskName)
