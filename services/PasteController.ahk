/*
    PasteController.ahk
    Responsibility: user actions from shortcuts, the tray menu and clipboard events (paste, undo, step back, restart,
                    load, clear, exit, mode switches, on/off). Copy mode Queue: every copy from any program is
                    appended as one item. Copy mode List: a copied list replaces the current one (the same list
                    keeps its place). Menu actions ask before discarding an unfinished list.
    Dependencies: ItemList, DeliveryService, ClipboardService, Notifier, Settings
*/
class PasteController {
    ; --- Properties ---
    _items := ""        ; ItemList
    _delivery := ""     ; DeliveryService
    _clip := ""         ; ClipboardService
    _tips := ""         ; Notifier
    _prefs := ""        ; Settings
    _undo := []         ; delivery records, newest last
    _paused := false    ; while paused, copies are ignored
    _clock := ""        ; callable() -> milliseconds; A_TickCount unless a test passes its own
    _lastAppendText := ""
    _lastAppendTick := ""

    ; --- Constructor ---
    __New(items, delivery, clip, tips, prefs, clock := "") {
        for dep in [items, delivery, clip, tips, prefs] {
            if !IsObject(dep)
                throw Error("Missing dependency", A_ThisFunc)
        }
        this._items := items
        this._delivery := delivery
        this._clip := clip
        this._tips := tips
        this._prefs := prefs
        this._clock := HasMethod(clock) ? clock : () => A_TickCount
    }

    ; --- Public Methods: shortcuts ---
    ; hotkey: the shortcut that fired (e.g. "$^+v"); its keys must be released before anything is typed.
    PasteNext(hotkey := "") {
        Critical                                    ; other shortcuts and clipboard events wait until this finishes
        queue := this._IsQueueMode()
        if this._items.IsEmpty() {
            this._tips.Show(queue ? "Nothing queued yet. Copy something first." : "No list loaded. Copy a list of 2+ lines, or use the tray menu.")
            return
        }
        if this._items.IsFinished() {
            count := this._items.GetCount()
            this._tips.Show(queue ? "All " count " pasted. Copy more to queue them." : "List complete (" count " of " count "). Tray menu → Restart at top to go again.")
            return
        }
        problem := this._delivery.HeldKeysProblem(hotkey)
        if (problem = "")
            problem := this._delivery.TargetProblem()   ; checked after the wait: the window you're in once you let go
        if (problem != "") {
            this._tips.Show(problem)
            return
        }
        text := this._items.Peek()
        record := this._delivery.Deliver(text, this._prefs.Get("AdvanceMode"), this._prefs.Get("DeliveryMode"))
        if !IsObject(record) {
            this._tips.Show("Paste failed, see error.log")
            return
        }
        this._items.Advance()                       ; KIND_ADVANCE keeps the undo history
        this._undo.Push(record)
        pos := this._items.GetPosition()
        count := this._items.GetCount()
        this._tips.Show(pos " / " count ":  " text (pos = count ? (queue ? "   (all pasted)" : "   (list complete)") : ""))
    }

    Undo(hotkey := "") {
        Critical
        if !this._undo.Length {
            this._tips.Show("Nothing to undo")
            return
        }
        problem := this._delivery.HeldKeysProblem(hotkey)
        if (problem != "") {
            this._tips.Show(problem)
            return
        }
        record := this._undo.Pop()
        result := this._delivery.Erase(record)
        if (result.reason = "window") {
            this._undo.Push(record)
            this._tips.Show("Undo: switch back to the window you pasted into")
            return
        }
        this._items.StepBack(Constants.KIND_UNDO)
        next := this._items.GetPosition() + 1
        count := this._items.GetCount()
        if result.erased
            this._tips.Show("Undone: " record.text "   (next " next "/" count ")")
        else
            this._tips.Show("Moved back to " next "/" count ". Erase it manually (" result.reason ")")
    }

    ; --- Public Methods: tray menu and extra shortcuts ---
    Back() {
        if !this._items.StepBack(Constants.KIND_BACK)
            return
        this._tips.Show("Next paste: item " (this._items.GetPosition() + 1))
    }

    Reset() {
        this._items.Reset()
        this._tips.Show("Back to top")
    }

    ForceLoad() {
        this._delivery.RestoreNow()                 ; NOTE: timers pause while a menu is open, so a pending restore may not have run
        lines := this._items.ParseLines(this._clip.ReadText())
        if !lines.Length {
            this._tips.Show("Clipboard has no text")
            return
        }
        if !this._MayReplace("Replace")             ; lines were read before asking, so the prompt can't change them
            return
        this._items.Load(lines)
        this._tips.Show(this._LoadedMessage(lines.Length))
    }

    ClearList() {
        if this._items.IsEmpty()
            return
        if !this._MayReplace("Clear")
            return
        this._items.Load([])
        this._tips.Show("List cleared")
    }

    ; True when it's fine to exit; asks first if an unfinished list would be lost.
    ConfirmExit() {
        if (!this._items.IsUnfinished() || this._prefs.Get("RememberList") = 1)
            return true
        question := "Exit and discard your unfinished list? (" this._DoneText() ")`n`nTo keep lists between restarts, turn on 'Remember list after exit' in the tray menu."
        return this._tips.Confirm(question)
    }

    CycleAdvance() {
        modes := Constants.ADVANCE_MODES
        current := this._prefs.Get("AdvanceMode")
        nextMode := modes[1]
        for i, mode in modes {
            if (mode = current) {
                nextMode := modes[Mod(i, modes.Length) + 1]
                break
            }
        }
        this._prefs.Set("AdvanceMode", nextMode)
        this._tips.Show("Auto-advance: " nextMode)
    }

    ToggleDelivery() {
        nextMode := (this._prefs.Get("DeliveryMode") = "Type") ? "Paste" : "Type"
        this._prefs.Set("DeliveryMode", nextMode)
        this._tips.Show(nextMode = "Paste" ? "Mode: Paste (clipboard)" : "Mode: Type")
    }

    ; --- Public Methods: events ---
    OnClipboardText(text) {
        if this._paused
            return
        if this._IsQueueMode()
            this._QueueCopy(text)
        else
            this._LoadCopiedList(text)
    }

    OnListChanged(kind) {
        if (kind != Constants.KIND_ADVANCE && kind != Constants.KIND_UNDO && kind != Constants.KIND_APPEND)
            this._undo := []                        ; position moved some other way: old records no longer match
    }

    ; Turning ON (resume) in Queue mode drops what was already pasted, so a finished batch doesn't pile up.
    OnPausedChanged(paused) {
        this._paused := paused ? true : false
        this._tips.Show(this._paused ? "ListPaster OFF" : "ListPaster ON: collecting copies")
        if (!this._paused && this._IsQueueMode())
            this._items.ClearDone()
    }

    ; --- Private Methods ---
    _IsQueueMode() => (this._prefs.Get("CopyMode") = "Queue")

    ; Queue mode: every copy (from any program) becomes one item at the end; the position doesn't move.
    _QueueCopy(text) {
        if (Trim(text, " `t`r`n") = "")
            return
        now := this._clock.Call()
        if (this._lastAppendTick != "" && text == this._lastAppendText && now - this._lastAppendTick < Constants.DUP_WINDOW_MS)
            return                                  ; the same copy written to the clipboard twice
        if !this._items.Append(text)
            return
        this._lastAppendText := text
        this._lastAppendTick := now
        count := this._items.GetCount()
        waiting := count - this._items.GetPosition()
        this._tips.Show("Queued #" count ": " this._Preview(text) "  (" waiting " waiting)")
    }

    ; First line, cut to QUEUE_PREVIEW_MAX characters; "…" marks a cut or further lines.
    _Preview(text) {
        lines := StrSplit(text, "`n", "`r")
        first := lines[1]
        preview := SubStr(first, 1, Constants.QUEUE_PREVIEW_MAX)
        if (StrLen(first) > Constants.QUEUE_PREVIEW_MAX || lines.Length > 1)
            preview .= "…"
        return preview
    }

    ; List mode (upstream behaviour): a copied list of 2+ lines replaces the current one.
    _LoadCopiedList(text) {
        lines := this._items.ParseLines(text)
        if (lines.Length < 2)
            return                                  ; single-line copies never replace the list
        if (!this._items.IsFinished() && this._items.HasSameItems(lines)) {   ; re-copy mid-list: keep the place
            this._tips.Show("Same list, still at " this._items.GetPosition() "/" this._items.GetCount() ". Tray menu → Restart at top to start over.")
            return
        }
        this._items.Load(lines)
        this._tips.Show(this._LoadedMessage(lines.Length))
    }

    _MayReplace(verb) {
        if !this._items.IsUnfinished()
            return true
        return this._tips.Confirm(verb " your unfinished list? (" this._DoneText() ")")
    }

    _DoneText() => this._items.GetPosition() " of " this._items.GetCount() " done"

    _LoadedMessage(count) {
        return "Loaded " count (count = 1 ? " item" : " items")
    }

    _LogError(caller, message) {
        FileAppend(FormatTime(, "yyyy-MM-dd HH:mm:ss") " ERROR [" caller "]: " message "`n", A_ScriptDir "\" Constants.ERROR_LOG)
    }
}
