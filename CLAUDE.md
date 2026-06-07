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

- `param([int]$IntervalSeconds = 30)` — the timer ticks every `$IntervalSeconds`.
- `[MouseHelper]` is a small inline C# type (via `Add-Type`) wrapping `user32.dll`'s
  `GetCursorPos` (to detect real user movement) and `SendInput` (to reposition the cursor).
  `SendInput` is used instead of `SetCursorPos` because the latter repositions the cursor directly,
  bypassing the input pipeline — Windows' lock timer (`GetLastInputInfo`) wouldn't see it as real
  activity and would still lock the workstation on schedule. `SendInput` requires building an
  `INPUT`/`MOUSEINPUT` struct pair and normalizing target coordinates to 0..65535 via
  `MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE`. Note: the `MOUSEINPUT` must be built as its own
  variable and assigned wholesale to `INPUT.mi` — assigning to nested fields directly
  (`$mouseInput.mi.dx = ...`) silently mutates a copy, since structs are value types in PowerShell.
- `SetHighDpiMode(PerMonitorV2)` + `AutoScaleMode = None` / `AutoScaleDimensions = (96, 96)` are set
  so the declared form size (200x120) renders at its literal pixel size on any display, instead of
  being bitmap-stretched by Windows DPI virtualization or rescaled by WinForms' own layout logic.
- The button uses `Dock = Fill` with the form's `Padding` providing the margin — `Margin` on a
  child control has no effect for `Dock = Fill` inside a plain `Form` (only layout-engine
  containers like `TableLayoutPanel`/`FlowLayoutPanel` honor it), so the margin must live on the form.
- On each tick: first checks for a running `LogonUI` process (the lock-screen owner) and bails out
  if found — no point jiggling the cursor while the workstation is locked. Otherwise it compares
  the current cursor position to the position recorded on the previous tick. If it changed, the
  user is active and the tick is skipped; if not, the cursor jumps to a random point within the
  primary screen's bounds. This keeps the mover from fighting active mouse use.
- `Switch-Running` (the Start/Stop toggle) is a shared function rather than living inline in a
  click handler, since both the form's button and the tray context-menu item need to invoke it and
  stay in sync.
- A "Run at startup" tray menu item (`$menuStartup`) toggles registration of `MouseMover.vbs` in
  the per-user `HKCU:\...\CurrentVersion\Run` registry key (no admin rights needed) via
  `Set-RunAtStartup`, mirroring `Set-Interval`'s pattern of driving the checked state from the
  setter rather than relying on `CheckOnClick` (the underlying registry write/remove can be
  inspected/fail, so the checkbox should reflect the actual outcome). Its checked state is
  initialized at startup by *reading* the registry (`Get-ItemProperty`), not by calling
  `Set-RunAtStartup` — calling the setter would rewrite the registry on every launch. The feature
  is opt-in: a fresh install starts unchecked and unregistered.
- A `NotifyIcon` + `ContextMenuStrip` provide the tray icon
  (tooltip "Mouse Mover") with "Start/Stop",
  an "Interval" submenu (predetermined values 1/2/5/10/15/30/60/120s, radio-style via `Set-Interval`
  checking only the matching `ToolStripMenuItem` by its `Tag`), "Run at startup" (see below), a
  separator, and "Exit". Note: `ShowImageMargin` is left at its default (`$true`) — both the
  Interval items and "Run at startup" rely on `.Checked` to render a checkmark, which needs that
  left gutter to be visible. Double-
  clicking the icon restores the form (`Show`, `WindowState = Normal`, `Activate`). `Set-Interval`
  is called once at startup with `$IntervalSeconds` so the timer and checked menu item start in sync
  — note that a custom `-IntervalSeconds` value outside the predetermined list leaves no item checked.
- The tray icon itself reflects running state — a green check (index 294) while active, a red X
  (index 131) while idle — swapped in `Switch-Running` alongside the button/menu text and color.
  Neither exists in `System.Drawing.SystemIcons`, so they're pulled from `shell32.dll` via the
  `ExtractIconEx` P/Invoke (`Get-ShellIcon`, MouseMover.ps1) — the only way to access indexed icons
  from a DLL's resource table from .NET/PowerShell. The indices were found empirically by rendering
  a scrollable preview grid of the DLL's icons (not officially documented, but stable since Vista).
- Minimizing the window hides it to the tray; closing it (X or the tray's "Exit") exits for real.
  Teardown (stop/dispose timer, hide/dispose tray icon) lives in one `Stop-MouseMover` function,
  called from both `FormClosing` and the crash backstop below — "Exit" simply calls `$form.Close()`
  to funnel into the same `FormClosing` path rather than duplicating the cleanup.
- Two WinForms/PowerShell gotchas drove specific design choices here:
  - `Add_Resize` guards against hiding on `Minimized` with a `$script:formLoaded` flag (set in
    `Add_Shown`) — WinForms can transiently report `Minimized` during initial layout (e.g. under
    `PerMonitorV2` DPI scaling), and without the guard the form blinks open and immediately
    hides itself on every launch. It also restores `WindowState` to `Normal` before calling
    `Hide()` — hiding while still `Minimized` leaves a stuck/ghost entry in the taskbar.
  - The app **never calls `[Application]::Exit()`** — it tears down WinForms' static per-process
    message-loop state, so any later `Application.Run` in the *same* process returns instantly
    without showing a form (only surfaces when re-running the script in the same terminal session;
    real launches via `.vbs`/double-click always use a fresh process). Closing the form for real
    and letting `Application.Run` return naturally avoids this entirely.
- The `Add-Type` for `[MouseHelper]` is guarded with a `PSTypeName` check, since `Add-Type` can't
  redefine a type already loaded into the runspace — without the guard, re-running the script in
  the same session throws "type 'MouseHelper' already exists".
- A named, `Global\`-scoped `Mutex` (`Global\MouseMover-SingleInstance`) enforces a single running
  instance: acquired with `New-Object Mutex($true, name, [ref]$createdNew)` before any UI is built
  (note `[ref]$createdNew` requires the variable to be pre-declared — `[ref]` can't target a
  not-yet-existing variable). If `$createdNew` is false, another instance owns it, so a message box
  is shown and the script exits immediately. Released/disposed in `Stop-MouseMover`, guarded by
  nulling `$script:singletonMutex` after disposal — `Stop-MouseMover` runs from both `FormClosing`
  and the crash backstop, and releasing/disposing an already-disposed mutex throws. Kernel-owned
  named mutexes are auto-released by Windows on process exit (including force-kill), so a crashed
  instance never permanently locks out a future one — except within the *same process* (see the
  `Application.Run`/same-session note above and the testing tip below).
- A `try/finally` around `Application.Run` calls `Stop-MouseMover` even on a crash, as a backstop
  against ghost icons (dead `NotifyIcon` entries that linger in the tray, fully unresponsive,
  until the next sign-out/reboot — Explorer prunes them only when rebuilding the notification area).
  `Dispose()` on an already-disposed `Timer`/`NotifyIcon` is a safe no-op, so it's fine for both
  the normal-close path and this backstop to call the same teardown function.

### MouseMover.vbs — hidden launcher

Resolves its own folder via `WScript.ScriptFullName`, probes for `pwsh` (falling back to
`powershell` if not installed), and launches `MouseMover.ps1` with `-WindowStyle Hidden` so no
console window appears — useful for double-click launching.

### Running / testing

```powershell
# Run directly (default 30s interval):
.\MouseMover.ps1

# Custom interval:
.\MouseMover.ps1 -IntervalSeconds 30

# Or launch hidden, detached from any console (double-click also works):
.\MouseMover.vbs
```

Note: the singleton mutex is process-owned, and re-running `.\MouseMover.ps1` from an interactive
session executes in that *same* process (just a child scope) — so a still-held mutex from a prior
run blocks the new one until the terminal/process truly exits. To test multiple launches without
closing the terminal, spawn a fresh child process instead:

```powershell
pwsh -File .\MouseMover.ps1
```

### Releases (.github/workflows/release.yml)

Pushes to `main` that touch `MouseMover.ps1` or `MouseMover.vbs` (or a manual `workflow_dispatch`
run) zip both files into `MouseMover.zip` and publish/update a single rolling `latest` GitHub
release with that zip attached — giving users a one-file download without needing git. The job
declares `permissions: contents: write` so `softprops/action-gh-release` can create/update the
release under the default `GITHUB_TOKEN`.
