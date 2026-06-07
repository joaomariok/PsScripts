# Scripts repo

PowerShell scripts collection. Contains the **Cleanup** module (Windows system-cleanup tool) and
**MouseMover**, a standalone WinForms idle-mouse-jiggler script.

## Layout

```
Cleanup-System.ps1          Entry-point script (run as: Cleanup-System.ps1 -WhatIf)
Cleanup/
  Cleanup.psd1              Module manifest (RootModule = Cleanup.psm1)
  Cleanup.psm1              Root module: Clear-All (orchestration) + Clear-System (entry point)
  Modules/                  Nested modules, imported by Cleanup.psm1
    Write.psm1              Write-Text, Write-Title, Write-MainTitle (console output helpers)
    Helpers.psm1            Test-Elevated (admin check)
    GenericClears.psm1      Clear-DirectoryContents, Clear-AllDirectoryContents, Remove-File, Remove-RegistryKey
    SpecificClears.psm1     Clear-DirectoryServiceDependent, Clear-OldLogFiles, Clear-BrowserCache(s),
                            Clear-TeamsCache(Instance), Clear-UWPAppTemp, Clear-ClipboardContents
MouseMover.ps1              Standalone WinForms script: Start/Stop GUI that jiggles the mouse when idle
MouseMover.vbs              Hidden launcher for MouseMover.ps1 (no console window; pwsh, falls back to powershell)
```

## Setup

If downloaded rather than git-cloned, the `.ps1`/`.psm1`/`.psd1` files will carry a
Zone.Identifier ADS marking them as from the internet, which blocks execution/import. Unblock:
```powershell
Get-ChildItem -Recurse -Include *.ps1, *.psm1, *.psd1 | Unblock-File
```

## Cleanup

### How it works

- `Clear-System` is the only function exported from the root module (`Export-ModuleMember -Function 'Clear-System'`).
- It requires admin (`Test-Elevated`), starts a transcript log to `C:\Windows\Logs\Cleanup-*.log`,
  runs `Clear-All`, then stops the transcript and prunes old logs (keeps 5 most recent).
- `Clear-All` orchestrates the actual cleanup: temp folders, recycle bin, thumbnail/icon caches,
  shader caches, browser caches, Teams cache, UWP app temp, DNS cache, Windows Update cache,
  privacy-related registry keys/clipboard, old logs, and optionally DISM component cleanup (`-CleanDism`).
- Everything supports `-WhatIf` via `SupportsShouldProcess` / `$PSCmdlet.ShouldProcess`, propagated
  down through every helper via `-WhatIf:$WhatIfPreference`.
- `-Optional` switch on generic clear helpers suppresses "does not exist" warnings for paths that
  may legitimately be absent (e.g. app caches for uninstalled software).

### Nested module imports — important gotcha

Each file in `Modules/` imports its dependencies relative to its own `$PSScriptRoot` (which equals
`Cleanup\Modules`, NOT `Cleanup`). E.g. `SpecificClears.psm1` needs both:
```powershell
Import-Module "$PSScriptRoot\Write.psm1" -Force
Import-Module "$PSScriptRoot\GenericClears.psm1" -Force
```
(NOT `$PSScriptRoot\Modules\Write.psm1` — that doubles the path segment and fails to resolve.)

All `Import-Module` calls use `-Force`, which cascades: re-importing the root module with `-Force`
re-executes its top-level imports, which re-execute theirs, ensuring every nested module reloads
its latest code in one go — no need to `Remove-Module` everything manually during development.

### Running / testing

```powershell
# Reload everything and dry-run:
clear
Import-Module "C:\Users\joaom\Scripts\Cleanup\Cleanup.psd1" -Force
Clear-System -WhatIf

# Or via the entry-point script (note: .ps1 needs extension or full/relative path even if dir is in PATH):
Cleanup-System.ps1 -WhatIf
```

## MouseMover

A self-contained WinForms script (not part of the Cleanup module — no nested-module imports).

### How it works

- `param([int]$IntervalSeconds = 60)` — the timer ticks every `$IntervalSeconds`.
- `[MouseHelper]` is a small inline C# type (via `Add-Type`) wrapping `user32.dll`'s
  `GetCursorPos`/`SetCursorPos` — used to detect real user movement and to reposition the cursor.
- `SetHighDpiMode(PerMonitorV2)` + `AutoScaleMode = None` / `AutoScaleDimensions = (96, 96)` are set
  so the declared form size (200x120) renders at its literal pixel size on any display, instead of
  being bitmap-stretched by Windows DPI virtualization or rescaled by WinForms' own layout logic.
- The button uses `Dock = Fill` with the form's `Padding` providing the margin — `Margin` on a
  child control has no effect for `Dock = Fill` inside a plain `Form` (only layout-engine
  containers like `TableLayoutPanel`/`FlowLayoutPanel` honor it), so the margin must live on the form.
- On each tick: compares the current cursor position to the position recorded on the previous tick.
  If it changed, the user is active and the tick is skipped; if not, the cursor jumps to a random
  point within the primary screen's bounds. This keeps the mover from fighting active mouse use.

### MouseMover.vbs — hidden launcher

Resolves its own folder via `WScript.ScriptFullName`, probes for `pwsh` (falling back to
`powershell` if not installed), and launches `MouseMover.ps1` with `-WindowStyle Hidden` so no
console window appears — useful for double-click launching.

### Running / testing

```powershell
# Run directly (default 60s interval):
.\MouseMover.ps1

# Custom interval:
.\MouseMover.ps1 -IntervalSeconds 30

# Or launch hidden, detached from any console (double-click also works):
.\MouseMover.vbs
```
