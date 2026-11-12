#Requires AutoHotkey v2.0
#SingleInstance Off
#NoTrayIcon

/*
    LiveCheck.ahk
    Responsibility: end-to-end check on the real desktop. Starts Main.ahk, writes to the clipboard the way a website
                    copy button does (a program writing text), presses the real Win+V / Win+Alt+V shortcuts and reads
                    what landed in a test window it owns.
    Usage (Git Bash):
        MSYS_NO_PATHCONV=1 "/c/Program Files/AutoHotkey/v2/AutoHotkey64.exe" /ErrorStdOut tests/LiveCheck.ahk | cat
        ... tests/LiveCheck.ahk paste 2 "web-oneweb-two"   ; paste 2 already-queued items, compare with the text
    Needs default settings (Copy mode Queue, insert mode Paste, auto-advance None, Remember list off, StartOn 1).
    "full" restarts ListPaster, so anything queued in the running copy is discarded. Exit code = failed checks.
    Don't type or click while it runs (about 15 seconds): it sends real keystrokes. It stops before sending a key
    if its own test window isn't the active window.
*/

global passed := 0
global failed := 0
global repo := RegExReplace(A_ScriptDir, "\\tests$")
global mainTitle := repo "\Main.ahk ahk_class AutoHotkey"
global listenerLog := A_Temp "\ListPasterLiveCheck-listener.log"
global listenerPid := 0
global appState := "unknown"    ; "on" / "off" once this run started ListPaster itself; toggles flip it
global clipChanged := false     ; true once this run wrote to the clipboard

SendLevel(1)                ; ListPaster reacts to keys from another script only when they are sent above level 0
DetectHiddenWindows(true)   ; to find ListPaster's hidden main window

saved := ClipboardAll()
mode := A_Args.Length ? A_Args[1] : "full"
g := ""
try {
    g := TestWindow()
    if (mode = "paste")
        PasteOnly(g, A_Args.Length >= 2 ? Integer(A_Args[2]) : 1, A_Args.Length >= 3 ? A_Args[3] : "")
    else
        Full(g)
} catch Error as e {
    Check(false, "no error while checking (" e.Message ", line " e.Line ")")
}
QuietRestore(saved)
if IsObject(g)
    g.Destroy()
if listenerPid
    ProcessClose(listenerPid)
Out("passed: " passed "   failed: " failed)
ExitApp(failed)

; =====================================================================================

Full(g) {
    if !DefaultsInUse()
        return
    StartListener()             ; before ListPaster, so it only hears the Win+V that ListPaster lets through
    if WinExist(mainTitle)
        Out("note: restarting ListPaster; anything it had queued is discarded")
    StartApp()

    ; 1. Three copies written by a program (a website's copy button writes the clipboard the same way)
    for text in ["alpha", "beta`nline2", "gamma"] {
        SetClip(text)
        Sleep(300)
    }
    loop 3
        PressInto(g, "#v")
    Check(EditText(g) == "alphabeta`nline2gamma", "Win+V pastes the three copies in copy order (got: " Show(EditText(g)) ")")
    Check(ListenerHeard() = 0, "while ON, ListPaster keeps Win+V from Windows (passed on: " ListenerHeard() ")")

    ; 2. ListPaster's own clipboard restore after pasting must not be queued
    Sleep(2000)
    PressInto(g, "#v")
    Check(EditText(g) == "alphabeta`nline2gamma", "the clipboard restore after pasting was not queued")

    ; 3. OFF: copies are ignored and Win+V goes back to Windows
    Toggle()
    SetClip("delta")
    Sleep(300)
    before := EditText(g)
    PressInto(g, "#v")
    Check(EditText(g) == before, "while OFF, Win+V pastes nothing from the queue")
    Check(ListenerHeard() = 1, "while OFF, Win+V is passed on to Windows (passed on: " ListenerHeard() ")")

    ; 4. Back ON: pasted items were cleared, the copy made while OFF wasn't queued, new copies are
    Toggle()
    PressInto(g, "#v")
    Check(EditText(g) == before, "after turning ON, nothing old is pasted (got: " Show(EditText(g)) ")")
    SetClip("epsilon")
    Sleep(300)
    PressInto(g, "#v")
    Check(SubStr(EditText(g), -7) == "epsilon", "a copy made after turning back ON is pasted")
    Check(ListenerHeard() = 1, "back ON, Win+V is kept from Windows again (passed on: " ListenerHeard() ")")
}

; Pastes n items that are already queued (e.g. from a website's copy buttons) and compares with expected.
PasteOnly(g, n, expected) {
    if !WinExist(mainTitle) {
        Check(false, "ListPaster is running")
        return
    }
    loop n
        PressInto(g, "#v")
    Out("pasted: " Show(EditText(g)))
    if (expected != "")
        Check(EditText(g) == expected, "pasted text is " expected)
}

; =====================================================================================

DefaultsInUse() {
    ini := repo "\data\settings.ini"
    want := Map("CopyMode", "Queue", "DeliveryMode", "Paste", "AdvanceMode", "None", "StartOn", "1", "RememberList", "0")
    for key, value in want {
        got := IniRead(ini, "Settings", key, value)
        if (got != value) {
            Check(false, "default settings in use (" key "=" got ", needs " value ")")
            return false
        }
    }
    return true
}

StartListener() {
    global listenerPid
    if FileExist(listenerLog)
        FileDelete(listenerLog)
    Run('"' A_AhkPath '" "' A_ScriptDir '\live\Listener.ahk" "' listenerLog '"', , , &listenerPid)
    Sleep(700)
}

; How many Win+V presses got past ListPaster since the listener started.
ListenerHeard() {
    if !FileExist(listenerLog)
        return 0
    return StrSplit(Trim(FileRead(listenerLog), "`n"), "`n").Length
}

StartApp() {
    global appState
    Run('"' A_AhkPath '" "' repo '\Main.ahk"', repo)     ; #SingleInstance Force replaces a running copy
    started := WinWait(mainTitle, , 5)
    Check(started, "ListPaster started")
    if !started
        throw Error("ListPaster did not start")
    appState := "on"                                     ; StartOn=1 was checked in DefaultsInUse
    Sleep(1500)
}

TestWindow() {
    g := Gui("+AlwaysOnTop", "ListPaster live check")
    g.Add("Edit", "vE w420 h160 Multi")
    g.Show("x40 y40")
    return g
}

Activate(g) {
    WinActivate("ahk_id " g.Hwnd)
    if !WinWaitActive("ahk_id " g.Hwnd, , 2)
        throw Error("the test window lost focus; stopped before sending keys to another window")
    ControlFocus(g["E"])
}

PressInto(g, keys) {
    Activate(g)
    if !WinActive("ahk_id " g.Hwnd)
        throw Error("the test window lost focus; stopped before sending keys to another window")
    Send(keys)
    Sleep(1000)                 ; Paste mode waits 250 ms before and after Ctrl+V
}

Press(keys) {
    Send(keys)
    Sleep(500)
}

; Win+Alt+V, keeping track of the ON/OFF state when this run knows it.
Toggle() {
    global appState
    Press("#!v")
    if (appState != "unknown")
        appState := (appState = "on") ? "off" : "on"
}

SetClip(text) {
    global clipChanged
    A_Clipboard := text
    clipChanged := true
}

; Puts the user's clipboard back only if this run changed it, while ListPaster is OFF so it isn't queued, and
; leaves ListPaster ON (turning ON clears the test's pasted items). Never toggles a copy it doesn't know the state of.
QuietRestore(saved) {
    if !clipChanged
        return
    if (appState = "unknown" || !WinExist(mainTitle)) {
        A_Clipboard := saved
        return
    }
    if (appState = "on")
        Toggle()
    A_Clipboard := saved
    Sleep(300)
    Toggle()
}

EditText(g) => StrReplace(g["E"].Value, "`r`n", "`n")
Show(text) => StrReplace(text, "`n", "\n")

Check(ok, name) {
    global passed, failed
    if ok
        passed += 1
    else
        failed += 1
    Out((ok ? "PASS " : "FAIL ") name)
}

Out(text) {
    FileAppend(text "`n", "*", "UTF-8-RAW")
}
