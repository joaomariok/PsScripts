Dim fso, shell, scriptDir, psPath, exe

Set fso = CreateObject("Scripting.FileSystemObject")
Set shell = CreateObject("WScript.Shell")

scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
psPath = fso.BuildPath(scriptDir, "MouseMover.ps1")

' Prefer PowerShell 7+ (pwsh), fall back to Windows PowerShell if not installed
On Error Resume Next
shell.Run "pwsh -Command exit", 0, True
If Err.Number = 0 Then
    exe = "pwsh"
Else
    exe = "powershell"
End If
On Error Goto 0

shell.Run exe & " -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & psPath & """", 0, False
