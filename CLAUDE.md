# Scripts repo

PowerShell scripts collection. Contains the **Cleanup** module (Windows system-cleanup tool),
**MouseMover**, a standalone WinForms idle-mouse-jiggler script, and **DriveMount**, scripts to
mount/unmount a MEGA remote as a drive letter via rclone + WinFsp.

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
DriveMount/
  config.ps1                Shared settings: remote name, drive letter, log file, rclone RC address/log level, PID file
  mount_mega.ps1             Mounts the MEGA remote as a drive via `rclone mount` (background, WinFsp)
  unmount_mega.ps1           Unmounts via rclone RC `core/quit`, falling back to Stop-Process by saved PID
  status_mega.ps1            Reports whether the drive is mounted and whether the rclone process is running
```

## Setup

If downloaded rather than git-cloned, the `.ps1`/`.psm1`/`.psd1` files will carry a
Zone.Identifier ADS marking them as from the internet, which blocks execution/import. Unblock:
```powershell
Get-ChildItem -Recurse -Include *.ps1, *.psm1, *.psd1 | Unblock-File
```

## Cleanup, MouseMover, and DriveMount docs

See [Cleanup.md](Cleanup.md) for the Cleanup module's internals (how it works, the nested-module
import gotcha, running/testing), [MouseMover.md](MouseMover.md) for MouseMover's internals
(WinForms/tray details, the `.vbs` launcher, running/testing, and the release workflow), and
[DriveMount.md](DriveMount.md) for DriveMount's internals (rclone/WinFsp prerequisites, the RC
quit/PID-file fallback, running/testing).
