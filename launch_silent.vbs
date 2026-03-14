Set WshShell = CreateObject("WScript.Shell")
scriptPath = WScript.ScriptFullName
baseDir = Left(scriptPath, InStrRev(scriptPath, "\"))
WshShell.Run Chr(34) & baseDir & "launch.cmd" & Chr(34), 0, False
