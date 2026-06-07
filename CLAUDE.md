# Scripts repo

PowerShell scripts collection. Currently contains a single module: **Cleanup**, a Windows system-cleanup tool.

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
```

## How it works

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

## Nested module imports — important gotcha

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

## Setup

If downloaded rather than git-cloned, the `.ps1`/`.psm1`/`.psd1` files will carry a
Zone.Identifier ADS marking them as from the internet, which blocks execution/import. Unblock:
```powershell
Get-ChildItem -Recurse -Include *.ps1, *.psm1, *.psd1 | Unblock-File
```

## Running / testing

```powershell
# Reload everything and dry-run:
clear
Import-Module "C:\Users\joaom\Scripts\Cleanup\Cleanup.psd1" -Force
Clear-System -WhatIf

# Or via the entry-point script (note: .ps1 needs extension or full/relative path even if dir is in PATH):
Cleanup-System.ps1 -WhatIf
```
