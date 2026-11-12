# Copy queue for ListPaster: design

Date: 2026-11-12
Status: approved in chat, awaiting written-spec review
Fork of: [beepboop1998/ListPaster-v3](https://github.com/beepboop1998/ListPaster-v3) (MIT), based on upstream `697187b`
Fork: `pranjvas/ListPaster-v3`, branch `feature/copy-queue`

## Goal

Copy text from anywhere, then paste each item one at a time, in copy order, by pressing one hotkey
repeatedly in any app. A second hotkey turns the whole tool on and off.

"Anywhere" includes Ctrl+C, right-click > Copy, a website's copy button, and any program that writes
text to the clipboard. Capture therefore has to come from clipboard change notifications, not from
watching the Ctrl+C keystroke. ListPaster already monitors the clipboard with `OnClipboardChange`
(the Windows clipboard listener) and tells its own writes apart by clipboard sequence number.

## Decisions taken with the user

| Topic | Decision |
|---|---|
| Base | Fork ListPaster v3 rather than build from scratch or use closed-source Clibor |
| Paste next key | **Win+V**, active only while ON |
| On/off key | **Win+Alt+V**, always active (exempt from Pause) |
| Multi-line copy | Queued as **one item**, pasted whole |
| State at startup | **ON** |
| Delivery default | **Paste** mode (clipboard + Ctrl+V, then the user's clipboard is restored) |
| Install location | `C:\Users\pranj\projects\ListPaster-v3`, started at login from the Startup folder |

### Shortcut collision check (done 2026-11-12 on this PC)

- `RegisterHotKey` probe: Win+V **taken** (Windows clipboard history), Win+Alt+V **free**, Ctrl+Shift+V
  free, Win+Shift+V and Win+Ctrl+V taken by Windows.
- Win+Alt+V is not a documented Windows 11 shortcut. The nearest one is PowerToys' Paste as Plain Text,
  Ctrl+Win+Alt+V. PowerToys isn't installed here, and AutoHotkey's `#!v` does not fire for that
  combination.
- Win+V is taken over through AutoHotkey's keyboard hook (`$#v`) only while ListPaster is ON. While it
  is OFF, Suspend gives Win+V back to Windows clipboard history. Clipboard history is currently off on
  this PC. The live check must confirm that the hook wins over the shell's Win+V.

## Behaviour

### ON/OFF

- **Win+Alt+V** toggles. The tray item reads *Turn off ListPaster (Win+Alt+V)* or *Turn on ListPaster
  (Win+Alt+V)*. The tray status line starts with `ON ·` or `OFF —`.
- **OFF** is upstream's Pause: `Suspend` releases every ListPaster shortcut back to the apps, and copies
  are ignored. The toggle hotkey is registered with the `S` option so it keeps working while suspended.
- A tooltip confirms each change: `ListPaster ON: collecting copies` / `ListPaster OFF`.
- At startup the setting `StartOn` (default `1`) decides the initial state. It is an ini-only setting.
- **Turning ON clears items that were already pasted** and keeps unpasted ones. This applies in Queue
  mode only. It stops yesterday's finished batch from piling up without losing a half-pasted queue.

### Capture (Copy mode "Queue", the new default)

Every external clipboard change that carries text appends **one item** at the end of the list:

- Text that is empty or whitespace-only is ignored. Non-text clipboard content (images, files) is
  ignored, as upstream already does.
- Multi-line text stays one item, exactly as copied.
- **Duplicate guard:** a copy identical (case-sensitive) to the last appended item that arrives within
  `DUP_WINDOW_MS = 1000` ms of it is ignored. Some apps and sites write the clipboard twice for one copy.
  The same text copied deliberately later is queued again.
- ListPaster's own writes (Paste-mode delivery, clipboard restore) are never queued. This relies on the
  existing sequence-number check in `ClipboardService`.
- Appending does not move the position. If the list was finished, the new item becomes the next one.
- A tooltip confirms: `Queued #<n>: <preview>` (first line, at most 60 characters) and `(<k> waiting)`.

Copy mode "List" keeps upstream's behaviour: copying 2+ lines replaces the list, a single line is
ignored, and re-copying the same list keeps the place. It is offered in the tray as
*Copy mode ▸ Queue each copy / Load copied lists*. Tray *Load from clipboard* (split into lines,
replace the list) works in both modes.

### Paste next (Win+V)

Unchanged upstream flow: wait for the shortcut's keys to be released (LWin/RWin included), refuse
unsafe targets, deliver, advance, record for undo, and show a tooltip. New wording in Queue mode:

- Empty list: `Nothing queued yet. Copy something first.`
- Finished: `All <n> pasted. Copy more to queue them.`

List mode keeps upstream's messages.

### Unchanged from upstream

Undo (Ctrl+Alt+Z), Step back, Restart at top, Clear list, Auto-advance None/Tab/Enter, Type/Paste
insert mode, the list window (done items shown as done), the generator, Remember list after exit,
privacy markers on ListPaster's own clipboard writes, and the extra Ctrl+Alt hotkeys.

## Design: changes per file

| File | Change |
|---|---|
| `Constants.ahk` | `VERSION := "3.2-q1"`; `HK_PASTE_NEXT := "#v"`; new `HK_TOGGLE_ON := "#!v"`; `COPY_MODES := ["Queue", "List"]`; `KIND_APPEND := "append"`; `DUP_WINDOW_MS := 1000`; `QUEUE_PREVIEW_MAX := 60`; defaults `CopyMode=Queue`, `DeliveryMode=Paste`, `StartOn=1` |
| `services/Settings.ahk` | Validate `CopyMode` (one of `COPY_MODES`) and `StartOn` (0/1) |
| `services/ItemList.ahk` | `Append(text)`: rejects blank, pushes, notifies `KIND_APPEND`. `ClearDone()`: drops items `1..position`, sets the position to 0, notifies `KIND_EDIT` (no-op when nothing is done) |
| `services/PasteController.ahk` | Optional `clock` constructor argument (default `() => A_TickCount`) for the duplicate guard. `OnClipboardText` branches on `CopyMode`. `OnListChanged` keeps undo history on `KIND_APPEND`. `OnPausedChanged(false)` in Queue mode calls `ClearDone()`. Queue-mode wording for empty and finished lists |
| `services/HotkeyManager.ahk` | New group `"always"`, registered with `On S` (exempt from Suspend) and never touched by `SetExtraEnabled`. `SetPaused` shows the ON/OFF tooltip via a listener (kept out of the manager itself) |
| `services/ListStore.ahk`, `gui/ListWindow.ahk` | Handle `KIND_APPEND` like an edit (save, redraw) |
| `gui/TrayMenu.ahk` | `Copy mode` radio submenu; pause item text `Turn off/on ListPaster (Win+Alt+V)`; status prefix `ON ·` / `OFF —` |
| `Main.ahk` | Register `HK_TOGGLE_ON` in the `always` group; honour `StartOn` after `RegisterAll()`; wire the toggle tooltip |
| `README.md` | "This fork" section at the top: what changed, the new keys, how to install, credit to upstream |
| `tests/RunTests.ahk` | New tests (below); update upstream tests whose expectations change (defaults, menu count, labels); tests that exercise List-mode copying set `CopyMode=List` explicitly |

## Error handling

The upstream patterns stay as they are:

- Every Windows/API call is wrapped in try/catch.
- Failures go to `error.log`, which never contains list items.
- A failed delivery never advances.
- A bad hotkey name is reported once at startup.

New rules:

- `Append` with blank text returns false and changes nothing.
- An invalid `CopyMode` or `StartOn` in `settings.ini` falls back to its default and logs it.
- Hotkeys are registered through the keyboard hook (`$`), so another program's registration cannot
  make them fail. Only a bad key name can, and upstream's startup alert already reports it and points
  to the `HK_` lines in `Constants.ahk`. This covers `HK_TOGGLE_ON` too.

## Testing

**Headless (tests/RunTests.ahk, run with `MSYS_NO_PATHCONV=1` from Git Bash):**

- Queue capture: single and multi-line copies append in order, blank copies are ignored, and the
  position does not move.
- Duplicate guard: identical text within 1000 ms is ignored, after 1000 ms it is queued, and different
  text is always queued.
- Queue paste: paste in copy order. Appending after the end continues. Empty and finished messages.
- List mode with `CopyMode=List` keeps the existing tests A9 and others green.
- Paused (OFF) ignores copies. Resuming in Queue mode clears done items.
- `ItemList.Append`/`ClearDone` edge cases (blank text, nothing done, everything done).
- Settings: new defaults and validation fallbacks.
- `HotkeyManager`: an `always` hotkey still fires while suspended (an F-key hotkey triggered with
  `SendLevel 1`).
- Tray: ON/OFF wording, the Copy mode submenu, and the new menu entry count.
- All 226 upstream checks keep passing, or are updated only where this spec changes the behaviour.

**Live check on this PC (scripted, real hotkeys):**

- Start `Main.ahk`. A separate test script writes three texts to the clipboard programmatically, which
  is how a website copy button writes.
- It focuses a test window it owns and presses Win+V three times (`SendLevel 1`). The edit box must
  read the three texts in order, and Windows clipboard history must not open.
- Win+Alt+V turns it OFF. A copy is then not queued, and Win+V reaches Windows.
- Win+Alt+V turns it back ON, and the pasted items are cleared.
- A real website copy button test in the built-in browser (`navigator.clipboard.writeText`). The copied
  value must be pasted by Win+V.

## Setup on this PC

- Clone at `C:\Users\pranj\projects\ListPaster-v3`. Remotes: `origin` is the user's fork, `upstream` is
  beepboop1998.
- Startup shortcut `%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\ListPaster.lnk` runs
  `"C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe" "C:\Users\pranj\projects\ListPaster-v3\Main.ahk"`.
- Launch it once after install.

## Out of scope (YAGNI)

- Importing a list straight from a file (copying the file's text works).
- Images or rich text in the queue.
- Running elevated or with UI Access (documented upstream limitation).
- Contributing the changes back upstream (possible later; the fork keeps the history clean).
