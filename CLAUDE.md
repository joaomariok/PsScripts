# Scripts repo

PowerShell scripts collection. Contains the **Cleanup** module (Windows system-cleanup tool),
**MouseMover**, a standalone WinForms idle-mouse-jiggler script, **DriveMount**, scripts to
mount/unmount a MEGA remote as a drive letter via rclone + WinFsp, and **Common**, a shared-utilities
module for code reused across the other modules.

## Layout

```
Cleanup/
  Cleanup-System.ps1        Entry-point script (run as: Cleanup\Cleanup-System.ps1 -WhatIf)
  Cleanup.psd1              Module manifest (RootModule = Cleanup.psm1)
  Cleanup.psm1              Root module: Clear-All (orchestration) + Clear-System (entry point)
  Modules/                  Nested modules, imported by Cleanup.psm1 (also imports Common/, see below,
                            for Test-Elevated/Write-Text/Write-Title/Write-MainTitle)
    GenericClears.psm1      Clear-DirectoryContents, Clear-AllDirectoryContents, Remove-File, Remove-RegistryKey
    SpecificClears.psm1     Clear-DirectoryServiceDependent, Clear-OldLogFiles, Clear-BrowserCache(s),
                            Clear-TeamsCache(Instance), Clear-UWPAppTemp, Clear-ClipboardContents
MouseMover/
  MouseMover.ps1            Standalone WinForms script: Start/Stop GUI that jiggles the mouse when idle
  MouseMover.vbs            Hidden launcher for MouseMover.ps1 (no console window; pwsh, falls back to powershell)
DriveMount/
  config.ps1                Shared settings: remote name, drive letter, log file, rclone RC address/log level, PID file
  mount_mega.ps1             Mounts the MEGA remote as a drive via `rclone mount` (background, WinFsp)
  unmount_mega.ps1           Unmounts via rclone RC `core/quit`, falling back to Stop-Process by saved PID
  status_mega.ps1            Reports whether the drive is mounted and whether the rclone process is running
Common/
  Common.psd1               Module manifest (RootModule = Common.psm1)
  Common.psm1               Root module: imports nested modules
  Modules/                  Nested modules, imported by Common.psm1
    Guards.psm1             Confirm-Action (Yes/No prompt), Test-Elevated (admin check),
                            Test-ExternalCommand (fail-early command availability check)
    DiffTools.psm1          Compare-Diff (line diff), Compare-CharDiff (char diff)
    Write.psm1              Write-Text, Write-Title, Write-MainTitle, etc. (console output helpers)
    Tree.psm1               Show-Tree, Show-TreeFromList (directory-tree rendering)
    FileTools.psm1          Find-DuplicateFile (content-based duplicate finder: size pre-filter, quick-pass
                            head-hash, byte-compare/full-hash, Fast/Compatible strategies, optional parallel)
    ImageSimilarity.psm1    Find-SimilarImage (perceptual image-similarity: dHash/pHash,
                            Auto/BruteForce/BKTree adaptive matching, optional parallel hashing)
    ExternalTools.psm1      Get-FilesViaEverything, Get-EnumeratedFiles (internal helpers for optional
                            es.exe-accelerated file enumeration, shared by FileTools.psm1/ImageSimilarity.psm1)
```

## Setup

If downloaded rather than git-cloned, the `.ps1`/`.psm1`/`.psd1` files will carry a
Zone.Identifier ADS marking them as from the internet, which blocks execution/import. Unblock:
```powershell
Get-ChildItem -Recurse -Include *.ps1, *.psm1, *.psd1 | Unblock-File
```

## Cleanup, MouseMover, DriveMount, and Common docs

See [Cleanup/Cleanup.md](Cleanup/Cleanup.md) for the Cleanup module's internals (how it works, the
nested-module import gotcha, running/testing), [MouseMover/MouseMover.md](MouseMover/MouseMover.md)
for MouseMover's internals (WinForms/tray details, the `.vbs` launcher, running/testing, and the
release workflow), [DriveMount/DriveMount.md](DriveMount/DriveMount.md) for DriveMount's
internals (rclone/WinFsp prerequisites, the RC quit/PID-file fallback, running/testing), and
[Common/Common.md](Common/Common.md) for the Common module (shared utilities, currently consumed
by Cleanup).
