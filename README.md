# Scripts

Personal PowerShell scripts. Currently contains the **Cleanup** module — a Windows system-cleanup tool.

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

See [CLAUDE.md](CLAUDE.md) for module internals and development notes.
