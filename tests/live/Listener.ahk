#Requires AutoHotkey v2.0
#SingleInstance Off
#NoTrayIcon

/*
    Listener.ahk (used by LiveCheck.ahk)
    Responsibility: notes every Win+V that gets past ListPaster. Started BEFORE ListPaster, so its keyboard hook is
                    older and Windows calls it after ListPaster's: it only sees Win+V when ListPaster lets it through
                    (OFF), exactly like Windows' own clipboard history would.
    Usage: AutoHotkey64.exe Listener.ahk <log file>   ; exits by itself after 120 s
*/

logFile := A_Args.Length ? A_Args[1] : A_Temp "\ListPasterListener.log"
Hotkey("~$#v", (*) => FileAppend("#v`n", logFile))     ; ~ = let the key through, $ = keyboard hook
SetTimer(() => ExitApp(0), -120000)
