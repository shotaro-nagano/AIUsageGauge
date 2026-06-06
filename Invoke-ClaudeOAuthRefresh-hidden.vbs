Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
helperPath = fso.BuildPath(scriptDir, "Invoke-ClaudeOAuthRefresh.ps1")

If Not fso.FileExists(helperPath) Then
    WScript.Quit 1
End If

command = "pwsh -NoProfile -ExecutionPolicy Bypass -File " & Chr(34) & helperPath & Chr(34) & " -Quiet"
exitCode = shell.Run(command, 0, True)
WScript.Quit exitCode
