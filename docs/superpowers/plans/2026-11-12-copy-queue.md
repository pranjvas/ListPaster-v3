# Copy Queue Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every text copy from any source is queued while ListPaster is ON. Win+V pastes the queue in copy order, and Win+Alt+V turns the tool ON/OFF.

**Architecture:** This is a small change inside upstream's classes. A new `CopyMode` setting routes clipboard events in `PasteController` to a queue branch (`ItemList.Append`) or to upstream's list branch. ON/OFF is upstream's Pause (`Suspend`), plus one hotkey in a new Suspend-exempt group. The tray gains a Copy mode submenu and ON/OFF wording.

**Tech Stack:** AutoHotkey v2.0.23 at `C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe`, and the repo's own headless test runner `tests/RunTests.ahk`.

**Spec:** `docs/superpowers/specs/2026-11-12-copy-queue-design.md`

## Global Constraints

- Hotkeys: `HK_PASTE_NEXT := "#v"` and `HK_TOGGLE_ON := "#!v"`. All hotkeys are registered through the hook with the `$` prefix.
- Defaults: `CopyMode=Queue`, `DeliveryMode=Paste`, `StartOn=1`. `COPY_MODES := ["Queue", "List"]`.
- `DUP_WINDOW_MS := 1000`, `QUEUE_PREVIEW_MAX := 60`, `KIND_APPEND := "append"`, `VERSION := "3.2-q1"`.
- Exact user-facing text, verbatim from the spec:
  - `Nothing queued yet. Copy something first.`
  - `All <n> pasted. Copy more to queue them.`
  - `Queued #<n>: <preview>  (<k> waiting)`
  - `ListPaster ON: collecting copies`
  - `ListPaster OFF`
  - `Turn off ListPaster` / `Turn on ListPaster`
  - Tray status prefix `ON · ` or `OFF — `.
- Run tests from Git Bash with path conversion off. Exit code = number of failed checks:
  `MSYS_NO_PATHCONV=1 "/c/Program Files/AutoHotkey/v2/AutoHotkey64.exe" /ErrorStdOut tests/RunTests.ahk | cat`
- Keep upstream style: a header comment per file, try/catch around Windows calls, `_LogError`, and nothing from the list ever written to `error.log`.
- In the test file, a variable assigned inside a fat-arrow callback is local to it. Record hits with `arr.Push(...)`, never with `x .= ...`.
- AutoHotkey ignores keys a script sends to itself. Behaviour that needs real hotkeys (Suspend exemption, Win+V override) is tested by the live check in Task 6 with two processes, never inside `RunTests.ahk`.

## Review Focus

1. **A copy button that writes the clipboard twice** (empty or whitespace first, then the text, or the same text twice). Expect one queued item. Tests: `queue ignores blank then text`, `duplicate within 1000 ms ignored` (Task 3).
2. **A long or multi-line copy.** Expect the tooltip to show only the first line, cut to 60 characters with `…`, while the item stays whole. Test: `preview first line, 60 chars` (Task 3).
3. **ListPaster's own clipboard restore after a Paste-mode delivery.** It must not be re-queued. Covered live: after three pastes and a 2 s wait, another Win+V adds nothing (Task 6 step 3).
4. **Appended items with "Remember list after exit" on.** They must survive a restart. Test: `append marks the list dirty` (Task 2).
5. **The toggle key while OFF.** Win+Alt+V must still work while Win+V goes back to Windows. Tests: the pure `OptionsFor` test (Task 4) and the live two-process check (Task 6 step 4).

---

### Task 1: Settings and constants

**Files:**
- Modify: `Constants.ahk` (VERSION, hotkeys, modes, kinds, timing, `SETTINGS_DEFAULTS`)
- Modify: `services/Settings.ahk` (`_Validate`)
- Test: `tests/RunTests.ahk` (`Test_A10_Settings`, `NewControllerEnv`)

**Interfaces:**
- Produces:
  - `Constants.HK_PASTE_NEXT = "#v"` and `Constants.HK_TOGGLE_ON = "#!v"`
  - `Constants.COPY_MODES = ["Queue", "List"]`
  - `Constants.COPY_MODE_LABELS = Map("Queue", "Queue each copy", "List", "Load copied lists")`
  - `Constants.KIND_APPEND = "append"`
  - `Constants.DUP_WINDOW_MS = 1000` and `Constants.QUEUE_PREVIEW_MAX = 60`
  - Settings keys `CopyMode` (`Queue`|`List`) and `StartOn` (0|1)
  - `DeliveryMode` default `Paste`

- [ ] **Step 1: Update `Test_A10_Settings`.**
  - Change the default insert-mode assertion to `Assert.Eq(prefs.Get("DeliveryMode"), "Paste", "default insert mode is Paste")`.
  - Add `Assert.Eq(prefs.Get("CopyMode"), "Queue", "default copy mode is Queue")` and `Assert.Eq(prefs.Get("StartOn"), 1, "starts ON by default")`.
  - In the reload block, `prefs.Set("CopyMode", "list")` must reload as `"List"` ("copy mode stored with canonical spelling").
  - In the bad-values block, `IniWrite("Sideways", ini, "Settings", "CopyMode")` must fall back to `"Queue"`, and `IniWrite("2", ini, "Settings", "StartOn")` to `1`.
  - The two `ToggleDelivery` assertions flip order: the first toggle gives `"Type"` ("Paste switches to Type") and the second gives `"Paste"`.
- [ ] **Step 2: Make the legacy controller env use List mode.**
  - `NewControllerEnv(copyMode := "List")` calls `env.prefs.Set("CopyMode", copyMode)` before building the controller. Upstream tests A2–A9 keep their List-mode expectations unchanged.
- [ ] **Step 3: Run the tests and confirm A10 fails** (unknown setting `CopyMode`).
- [ ] **Step 4: Implement.**
  - Add the constants above to `Constants.ahk`, set `VERSION := "3.2-q1"`, and add `"CopyMode", "Queue"` and `"StartOn", 1` to `SETTINGS_DEFAULTS`, with `DeliveryMode` set to `"Paste"`.
  - In `Settings._Validate`, `case "CopyMode": return this._OneOf(key, value, Constants.COPY_MODES, fallback)`, and add `"StartOn"` to the 0/1 toggle case.
- [ ] **Step 5: Run the tests.** Expected: `failed: 0`.
- [ ] **Step 6: Commit:** `git commit -am "Settings: CopyMode, StartOn, Paste by default, Win+V keys"`

### Task 2: ItemList append and clear-done

**Files:**
- Modify: `services/ItemList.ahk`, `services/ListStore.ahk:64-71`, `gui/ListWindow.ahk:100-110`
- Test: `tests/RunTests.ahk` (new `Test_A17_ItemListQueue`, registered with `RunTest("A17 Queue list operations", ...)`)

**Interfaces:**
- Consumes: `Constants.KIND_APPEND`
- Produces:
  - `ItemList.Append(text) -> Boolean`: false for blank or whitespace-only text. Otherwise it pushes and notifies `KIND_APPEND`. The position never changes.
  - `ItemList.ClearDone() -> Integer`: the number of items removed. It drops items `1..position`, sets the position to 0, and notifies `KIND_EDIT` only when it removed something.

- [ ] **Step 1: Write `Test_A17_ItemListQueue`.**
  - `lst.Append("a")`, `lst.Append("b`nc")` → `Join(lst.ToArray())` = `"a|b`nc"`, `lst.GetPosition()` = `0` ("append keeps the position; multi-line stays one item").
  - `lst.Append("   ")` = `0` and the count stays 2 ("blank append rejected").
  - Advance twice, then `lst.Append("d")` → `lst.Peek()` = `"d"` ("appending after the end makes the new item next").
  - `lst.ClearDone()` = `2`, then `Join(lst.ToArray()) " @" lst.GetPosition()` = `"d @0"`.
  - A second `lst.ClearDone()` = `0`, and no extra `KIND_EDIT` is heard (record kinds with `kinds.Push(kind)`).
  - Kinds heard for an append = `"append"`.
  - **Review focus 4** (`append marks the list dirty`): with a `ListStore` built as in `Test_A11_Persistence` and `RememberList=1`, call `items.Append("x")`, run the `listSave` timer job, then reload into a fresh `ItemList`. Its items must end with `"x"`.
- [ ] **Step 2: Run the tests and confirm A17 fails** (`Append` is not defined).
- [ ] **Step 3: Implement** `Append` and `ClearDone` in `ItemList.ahk`.
  - Add `|| kind = Constants.KIND_APPEND` to the `_listDirty` condition in `ListStore.OnListChanged`.
  - Add `KIND_APPEND` to the full-render condition in `ListWindow.OnListChanged`.
- [ ] **Step 4: Run the tests.** Expected: `failed: 0`.
- [ ] **Step 5: Commit:** `git commit -am "ItemList: Append and ClearDone for the copy queue"`

### Task 3: Queue capture and paste in PasteController

**Files:**
- Modify: `services/PasteController.ahk`
- Test: `tests/RunTests.ahk` (new `Test_A18_CopyQueue`, `RunTest("A18 Copy queue", ...)`, plus `NewQueueEnv()`)

**Interfaces:**
- Consumes: `ItemList.Append`, `ItemList.ClearDone`, Settings `CopyMode`, and the Task 1 constants.
- Produces:
  - `PasteController.__New(items, delivery, clip, tips, prefs, clock := "")`. `clock` is a callable that returns milliseconds and defaults to `() => A_TickCount`.
  - Unchanged public names: `OnClipboardText(text)`, `PasteNext(hotkey)`, `OnPausedChanged(paused)`, `OnListChanged(kind)`.

- [ ] **Step 1: Write `NewQueueEnv()`.**
  - It is `NewControllerEnv("Queue")`, except the controller is built with `clock := () => env.now`, where `env.now := 0` is a property the test advances.
  - Write `Test_A18_CopyQueue` with these assertions:
  - `OnClipboardText("alpha")`, then `env.now += 1500`, then `OnClipboardText("beta`nline2")` → items `"alpha|beta`nline2"`, position 0 ("each copy appends one item; multi-line stays whole").
  - `env.tips.Last()` = `"Queued #2: beta…  (2 waiting)"` (**review focus 2**: preview of the first line plus `…` when cut or multi-line).
  - A 100-character single-line copy → the tooltip preview is its first 60 characters + `…` ("preview first line, 60 chars").
  - **Review focus 1:** `OnClipboardText("")`, then `OnClipboardText("  ")`, then `OnClipboardText("gamma")` → count 3 ("queue ignores blank then text").
  - `env.now += 400`, then `OnClipboardText("gamma")` → count stays 3 ("duplicate within 1000 ms ignored").
  - `env.now += 1000`, then `OnClipboardText("gamma")` → count 4 ("same text later is queued again").
  - `PasteNext()` ×4 → `Join(env.delivery.delivered)` = `"alpha|beta`nline2|gamma|gamma"` ("pastes in copy order").
  - A fifth `PasteNext()` → `env.tips.Last()` = `"All 4 pasted. Copy more to queue them."`.
  - `OnClipboardText("delta")`, then `PasteNext()` → the last delivered item = `"delta"` ("copying after the end continues").
  - On a fresh `NewQueueEnv()`, `PasteNext()` → `env.tips.Last()` = `"Nothing queued yet. Copy something first."`.
  - `OnPausedChanged(true)`, then `OnClipboardText("x")` → the count is unchanged ("OFF ignores copies"), and `env.tips.Last()` = `"ListPaster OFF"`.
  - Resume check, using an env with items `a,b,c` at position 2:
    - `OnPausedChanged(false)` → items `"c"`, position 0 ("turning ON clears pasted items"), and `env.tips.Last()` = `"ListPaster ON: collecting copies"`.
    - The same sequence in a List-mode env leaves the items untouched.
  - Undo still works after an append in between. In a fresh `NewQueueEnv()`:
    - Queue `"p"`, then `env.now += 1500`, then `PasteNext()`.
    - Queue `"z"`, then `Undo()`.
    - Expect `env.delivery.erased[1]` = `"p"` and position `0` ("an append between paste and undo keeps undo working").
- [ ] **Step 2: Run the tests and confirm A18 fails.**
- [ ] **Step 3: Implement.**
  - `OnClipboardText` returns early while paused, then branches.
    - The `List` branch is upstream's body, moved unchanged to `_LoadCopiedList(text)`.
    - The `Queue` branch is `_QueueCopy(text)`: ignore blank text, then the duplicate guard, comparing with `==` against `_lastAppendText` and `_lastAppendTick` with `DUP_WINDOW_MS`, then `Append`, then the tooltip.
  - `_Preview(text) -> String`: the first line, cut to `QUEUE_PREVIEW_MAX`. Append `…` when the text was cut or had more lines.
  - `PasteNext` uses the Queue wording for empty and finished lists when `CopyMode = "Queue"` and upstream's wording otherwise. The success tooltip suffix is `(all pasted)` in Queue mode and `(list complete)` in List mode.
  - `OnListChanged` keeps undo for `KIND_ADVANCE`, `KIND_UNDO` and `KIND_APPEND`.
  - `OnPausedChanged` sets `_paused` and shows the ON/OFF tooltip. In Queue mode, on resume, it calls `this._items.ClearDone()`.
- [ ] **Step 4: Run the tests.** Expected: `failed: 0`, and upstream A2–A9 are still green in List mode.
- [ ] **Step 5: Commit:** `git commit -am "Queue every copy; Win+V pastes them in order; ON/OFF messages"`

### Task 4: Always-on toggle hotkey, Win+V and startup state

**Files:**
- Modify: `services/HotkeyManager.ahk`, `Main.ahk`
- Test: `tests/RunTests.ahk` (`Test_A12_Shortcuts`)

**Interfaces:**
- Consumes: `Constants.HK_TOGGLE_ON`, `Constants.HK_PASTE_NEXT`, Settings `StartOn`
- Produces:
  - `HotkeyManager.Add(keys, label, fn, group)` accepts `group` = `"core"|"extra"|"always"`.
  - `HotkeyManager.OptionsFor(group, extrasOn) -> String` (pure): `"always"` → `"On S"`, `"core"` → `"On"`, `"extra"` → `extrasOn ? "On" : "Off"`.

- [ ] **Step 1: Extend `Test_A12_Shortcuts`.**
  - `hk.Describe("#v")` = `"Win+V"` and `hk.Describe("#!v")` = `"Win+Alt+V"`.
  - `hk.OptionsFor("always", false)` = `"On S"`, `hk.OptionsFor("core", false)` = `"On"`, `hk.OptionsFor("extra", false)` = `"Off"`, and `hk.OptionsFor("extra", true)` = `"On"`.
  - `hk.Add("F17", "Test always", (*) => 0, "always")` doesn't throw, and `hk.Add("F18", "x", (*) => 0, "sometimes")` throws `ValueError`.
  - A broken always-group key is reported as `unavailable until fixed`.
- [ ] **Step 2: Run the tests and confirm they fail.**
- [ ] **Step 3: Implement.**
  - `RegisterAll` uses `Hotkey("$" entry.keys, entry.fn, this.OptionsFor(entry.group, extrasOn))`.
  - The failure note treats `always` like `core`, and `SetExtraEnabled` is unchanged (it only touches `extra`).
  - In `Main.ahk`, add `hotkeys.Add(Constants.HK_TOGGLE_ON, "Turn ListPaster on/off", (*) => hotkeys.TogglePaused(), "always")`. Right after `hotkeys.RegisterAll()`, call `if (prefs.Get("StartOn") = 0) hotkeys.SetPaused(true)`.
  - Update the shortcut lines in both file headers.
- [ ] **Step 4: Run the tests.** Expected: `failed: 0`.
- [ ] **Step 5: Smoke-load the real app.** Run `MSYS_NO_PATHCONV=1 timeout 5 ".../AutoHotkey64.exe" /ErrorStdOut Main.ahk | cat`. The expected result is no load-time error output (timeout exit 124 is fine). Afterwards, kill any leftover process started from `Main.ahk`.
- [ ] **Step 6: Commit:** `git commit -am "Win+V pastes next; Win+Alt+V turns ListPaster on/off, even while off"`

### Task 5: Tray menu: ON/OFF and Copy mode

**Files:**
- Modify: `gui/TrayMenu.ahk`
- Test: `tests/RunTests.ahk` (`Test_A13_TrayState`)

**Interfaces:**
- Consumes: Settings `CopyMode`, `Constants.COPY_MODES`, `Constants.COPY_MODE_LABELS`, `HotkeyManager.Describe`
- Produces:
  - `TrayMenu.BuildState(info, cfg, paused, escapeAmpersands)`. `cfg` now requires `.copy` (`"Queue"|"List"`). The result gains `.copy`.
  - New pause item texts: `"Turn off ListPaster`tWin+Alt+V"` and `"Turn on ListPaster`tWin+Alt+V"`, with the key text from `Describe(Constants.HK_TOGGLE_ON)`.

- [ ] **Step 1: Update `Test_A13_TrayState` to the new layout.**
  - Add `copy: "List"` to `cfg`. Every non-paused status gains the `"ON · "` prefix, for example `"ON · No list loaded"` and `"ON · Next: 5 of 10 · Tab · Type"`, and the tooltip becomes `"ListPaster — ON · No list loaded"`.
  - Paused gives `"OFF — Next: 5 of 10 · Tab · Type"`, with `pauseText` = `"Turn on ListPaster`tWin+Alt+V"`.
  - Queue wording with `cfg.copy := "Queue"`: count 0 → `"ON · Nothing queued"`, and finished with count 10 → `"ON · All 10 pasted"`.
  - Real menu:
    - `GetMenuItemCount` = `19`.
    - The status line is `"ON · Next: 1 of 3 · None · Paste"`, because the default delivery mode is now Paste.
    - Position 9 is `"Copy mode"`, the Remember-list tick moves to position 15, and positions 17/18 are `"Turn off ListPaster`tWin+Alt+V"` / `"Exit"`.
    - `env.tray._OnCopyMode("List")` sets `CopyMode` to `"List"`.
    - After pausing, position 17 reads `"Turn on ListPaster`tWin+Alt+V"` and the status starts with `"OFF — "`.
- [ ] **Step 2: Run the tests and confirm A13 fails.**
- [ ] **Step 3: Implement.**
  - Add a `_copyMenu` radio submenu built from `COPY_MODES` and `COPY_MODE_LABELS`, inserted before "Auto-advance", with an `_OnCopyMode(mode, *)` handler that sets `CopyMode`.
  - `BuildState`:
    - Use the prefix rule `paused ? "OFF — " : "ON · "`.
    - In Queue mode, the empty and finished statuses are `"Nothing queued"` and `"All " count " pasted"`.
    - `pauseText` follows the item texts above.
  - `Refresh` passes `cfg.copy`, and `_Apply` checks the copy radio.
- [ ] **Step 4: Run the tests.** Expected: `failed: 0`.
- [ ] **Step 5: Commit:** `git commit -am "Tray: ON/OFF wording and Copy mode submenu"`

### Task 6: Live check on this PC (real hotkeys, two processes)

**Files:**
- Create: `tests/LiveCheck.ahk`, a self-contained check that drives a running `Main.ahk`. It prints `PASS`/`FAIL` lines and `passed: N failed: M`, and its exit code is the number of failures.
- Create: `tests/live/copy-button.html`, a page with two buttons that call `navigator.clipboard.writeText("web-one")` and `("web-two")`.

**Interfaces:**
- Consumes: the real app with default settings (Queue, Paste, StartOn=1).
- Produces: `LiveCheck.ahk [full|paste N]`. `full` (the default) runs steps 1–5. `paste N` opens the test window, presses Win+V N times and prints the edit box text (used by step 6).

- [ ] **Step 1: Write `tests/LiveCheck.ahk`.**
  - Save `ClipboardAll()` at the start and restore it at the end.
  - `Run('"' A_AhkPath '" "' repo '\Main.ahk"')`, then wait 1500 ms.
  - Create its own `Gui` with a multi-line `Edit`. Send all input with `SendLevel(1)` and wait about 900 ms after each Win+V (the paste pre/post delays plus margin).
  - Normalise CRLF to LF before every text comparison.
- [ ] **Step 2: Capture, then paste in order.**
  - Write `A_Clipboard := "alpha"`, `"beta`nline2"` and `"gamma"`, 300 ms apart.
  - Focus the edit box and press `#v` three times.
  - Expect the edit text `"alphabeta`nline2gamma"`. `WinActive(gui)` must stay true after every press, which proves Windows clipboard history did not open.
- [ ] **Step 3: Own restore is not queued (review focus 3).** Wait 2000 ms, press `#v` once more, and expect the edit text unchanged.
- [ ] **Step 4: OFF and back ON (review focus 5).**
  - Press `#!v`, then `A_Clipboard := "delta"`, then press `#v`.
  - Expect the edit text unchanged and our window no longer active, since Windows handled Win+V. Then send `{Esc}` and re-activate the gui.
  - Press `#!v` (ON), then `#v`. Expect the text unchanged: pasted items were cleared and delta was not captured.
  - `A_Clipboard := "epsilon"`, then `#v`. Expect the edit text to end with `"epsilon"`.
- [ ] **Step 5: Run it.** Command: `MSYS_NO_PATHCONV=1 "/c/Program Files/AutoHotkey/v2/AutoHotkey64.exe" /ErrorStdOut tests/LiveCheck.ahk | cat`. Expected: `failed: 0`.
- [ ] **Step 6: Real website copy button.**
  - Open `tests/live/copy-button.html` in the built-in browser and click "Copy web-one", then "Copy web-two".
  - Run `tests/LiveCheck.ahk paste 2`. Expected output: `web-oneweb-two`.
- [ ] **Step 7: Commit:** `git add tests/LiveCheck.ahk tests/live && git commit -m "Live check: real Win+V, Win+Alt+V and a website copy button"`

### Task 7: README, install, GitHub fork

**Files:**
- Modify: `README.md`, which gets a "This fork: copy queue" section at the top. It covers what changed, the keys table (Win+V, Win+Alt+V, Ctrl+Alt+Z), Copy mode, StartOn, the install and Startup steps, a credit and link to upstream, and the `MSYS_NO_PATHCONV=1` note in the test command.
- Create: `%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\ListPaster.lnk`

- [ ] **Step 1: Write the README section and commit it:** `git commit -am "README: document the copy-queue fork"`
- [ ] **Step 2: Create the Startup shortcut** with PowerShell `WScript.Shell`.
  - Target: `C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe`
  - Arguments: `"C:\Users\pranj\projects\ListPaster-v3\Main.ahk"`
  - Working directory: the repo
  - Verify that `(New-Object -ComObject WScript.Shell).CreateShortcut(<lnk>).Arguments` matches.
- [ ] **Step 3: Launch it.** Start `Main.ahk` and confirm an `AutoHotkey64.exe` process is running with `Main.ahk` in its command line.
- [ ] **Step 4: Fork and push.**
  - Run `gh repo fork beepboop1998/ListPaster-v3 --clone=false`, then `git remote add origin https://github.com/pranjvas/ListPaster-v3.git`.
  - `git push -u origin feature/copy-queue`.
  - Merge into the fork's `master` per the finishing-a-development-branch choice. Never open a PR against upstream.
