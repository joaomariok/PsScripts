# Scripts

Personal PowerShell scripts. Contains the **Cleanup** module — a Windows system-cleanup tool — and
**MouseMover**, a small WinForms utility that nudges the mouse to keep the system from going idle.

## Setup

If this repo was downloaded (not cloned via git), Windows marks the `.ps1`/`.psm1`/`.psd1` files as
coming from the internet, which blocks script/module execution. Unblock them first:

```powershell
Get-ChildItem -Recurse -Include *.ps1, *.psm1, *.psd1 | Unblock-File
```

## Cleanup

Cleans temp files, recycle bin, thumbnail/icon caches, shader caches, browser caches (Chrome, Edge,
Brave, Vivaldi, Opera), Microsoft Teams cache, UWP app temp folders, DNS cache, Windows Update
cache, and privacy-related items (clipboard history, search/address-bar/dialog MRU registry keys).
Also prunes old log files and optionally runs a DISM component-store cleanup.

Requires Administrator privileges.

### Usage

```powershell
# Dry run (shows what would be removed, changes nothing)
Cleanup-System.ps1 -WhatIf

# Actually clean
Cleanup-System.ps1

# Also run DISM component cleanup
Cleanup-System.ps1 -CleanDism
```

> Note: `.ps1` scripts aren't matched by bare command name even when their folder is on `PATH`
> (`.PS1` isn't in `$env:PATHEXT`). Include the extension, e.g. `Cleanup-System.ps1`, or call it
> via full/relative path (`& "C:\Users\joaom\Scripts\Cleanup-System.ps1"` / `.\Cleanup-System.ps1`).

Every cleanup step supports `-WhatIf`/`-Confirm` (via `SupportsShouldProcess`), so you can safely
preview what will happen before committing to it.

A transcript log of each run is written to `C:\Windows\Logs\Cleanup-*.log` (the 5 most recent are kept).

## MouseMover

A small WinForms GUI with a Start/Stop button and a system tray icon (which itself shows a green
check or red X to reflect whether it's running). While running, it checks once
per `IntervalSeconds` whether the cursor moved since the last check; if not (you've been idle), it
jiggles the mouse to a random position on the primary screen — keeping the system/session from
going idle without interfering while you're actively using the mouse. It also skips jiggling while
the screen is locked, since there's no point moving the cursor when no one can see it.

Minimizing the window sends it to the tray — double-click the tray icon to bring it back, or use its
right-click menu to toggle Start/Stop or Exit. Closing the window exits the app for good.

### Usage

```powershell
# Default: check/move every 60 seconds
.\MouseMover.ps1

# Custom interval
.\MouseMover.ps1 -IntervalSeconds 30
```

To run it detached, with no PowerShell console window, double-click `MouseMover.vbs` — it launches
the script hidden via `pwsh` (falling back to `powershell` if PowerShell 7+ isn't installed).

### Download

A ready-to-use `MouseMover.zip` (containing `MouseMover.ps1` and `MouseMover.vbs`) is published on
the [latest release](../../releases/latest) — rebuilt automatically whenever either file changes
on `main` (or on demand via the workflow's manual trigger).

See [CLAUDE.md](CLAUDE.md) for module internals and development notes.
