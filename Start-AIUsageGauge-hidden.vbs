Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
scriptPath = fso.BuildPath(scriptDir, "Start-AIUsageGauge.ps1")

If Not fso.FileExists(scriptPath) Then
    MsgBox "Start-AIUsageGauge.ps1 was not found." & vbCrLf & vbCrLf & _
        "Download the full package and keep this VBS file next to the PS1 file.", _
        vbCritical, "AI Usage Gauge"
    WScript.Quit 1
End If

On Error Resume Next
probeExit = shell.Run("pwsh -NoLogo -NoProfile -Command " & Chr(34) & "exit 0" & Chr(34), 0, True)
If Err.Number <> 0 Or probeExit <> 0 Then
    MsgBox "PowerShell 7 (pwsh) was not found." & vbCrLf & vbCrLf & _
        "Install PowerShell 7, then run this launcher again.", _
        vbCritical, "AI Usage Gauge"
    WScript.Quit 1
End If
On Error GoTo 0

command = "pwsh -NoProfile -STA -ExecutionPolicy Bypass -File " & Chr(34) & scriptPath & Chr(34) & " -Placement right"
shell.Run command, 0, False
