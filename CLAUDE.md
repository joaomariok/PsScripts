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

## Cleanup and MouseMover docs

See [Cleanup.md](Cleanup.md) for the Cleanup module's internals (how it works, the nested-module
import gotcha, running/testing), and [MouseMover.md](MouseMover.md) for MouseMover's internals
(WinForms/tray details, the `.vbs` launcher, running/testing, and the release workflow).
