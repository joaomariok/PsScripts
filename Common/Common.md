# Common

Shared utilities intended for use across the other feature modules (Cleanup, MouseMover,
DriveMount) as they're identified. `Common.psm1` imports each nested module below.

### Layout

```
Modules/
  Guards.psm1          Confirm-Action (Yes/No prompt), Test-Elevated (admin check),
                       Test-ExternalCommand (fail-early command availability check)
  DiffTools.psm1       Compare-Diff (line diff), Compare-CharDiff (char diff) + shared LCS engine
  Write.psm1           Write-EmptyLine, Write-Text, Write-Success, Write-Title, Write-MainTitle,
                       Show-PathEntries
  Tree.psm1            Show-Tree, Show-TreeFromList (directory-tree rendering)
  FileTools.psm1       Find-DuplicateFile (content-based duplicate finder: size pre-filter,
                       optional head-hash quick pass, byte-compare or full hash, with
                       Fast/Compatible strategies and optional parallel hashing)
  ImageSimilarity.psm1 Find-SimilarImage (perceptual image-similarity: dHash/pHash,
                       Auto/BruteForce/BKTree Hamming-distance matching, optional parallel
                       hashing)
  ExternalTools.psm1   Get-FilesViaEverything, Get-EnumeratedFiles -- internal helpers shared by
                       FileTools.psm1 and ImageSimilarity.psm1, not part of Common's public
                       surface; home for any future external-CLI-tool integrations too
```

### How it works

- Consumed by [Cleanup](../Cleanup/Cleanup.md), which imports `Common.psd1` for
  `Test-Elevated`/`Write-Text`/`Write-Title`/`Write-MainTitle` instead of carrying its own copies.
  MouseMover and DriveMount don't currently duplicate anything here and aren't wired up to Common.
- `Find-DuplicateFile` (`FileTools.psm1`) and `Find-SimilarImage` (`ImageSimilarity.psm1`) both
  delegate file enumeration entirely to `Get-EnumeratedFiles` (`ExternalTools.psm1`), which
  optionally accelerates it with the [Everything](https://www.voidtools.com/) CLI (`es.exe`) when
  it's installed and running, detected via `Test-ExternalCommand`. It falls back to
  `Get-ChildItem` automatically if `es` isn't found or the query fails, or always when called
  with `-UseNative`; `Get-ChildItem` enumeration errors (permission denied, long paths, ...) are
  collected and reported as a warning either way. `ExternalTools.psm1` is a small internal-only
  module exported for reuse between the two callers but not listed in `Common.psd1`'s
  `FunctionsToExport` -- it isn't part of Common's public surface, and is meant as the home for
  any other external-CLI-tool integrations added to Common later.
- `Find-SimilarImage` groups visually-similar (not byte-identical) images using perceptual
  hashing: dHash (fast, gradient-based, default) or pHash (DCT-based, more robust to
  scaling/recompression) via `-Algorithm`. Both the pHash DCT and the pairwise Hamming-distance
  comparison run in small C# types (`PHashDct`, `PerceptualHashMatcher` -- loaded once via
  `Add-Type -TypeDefinition`, guarded against re-registration on repeated `-Force` reimports)
  rather than nested PowerShell loops, since pure PowerShell measured roughly 25x slower for the
  DCT alone. `PerceptualHashMatcher` offers two matching strategies plus an `Auto` mode
  (`-Matcher`): brute force is O(n^2) but has trivial, threshold-independent per-pair cost; a
  BK-tree prunes via the triangle inequality and is far faster at small `-MaxDistance` but loses
  to brute force once `-MaxDistance` grows past the measured crossover, as pruning stops
  eliminating enough of the tree to offset its own overhead. `Auto` picks between them by that
  crossover; all three produce identical groupings. `-Parallel` hashes on multiple threads
  (PS7+); unlike `Find-DuplicateFile`'s inlined parallel hashing, each runspace here re-imports
  `ImageSimilarity.psm1` with `-PassThru` and invokes `Get-ImagePerceptualHash` via module-scope
  invocation (`& $module { ... }`), since inlining its GDI+/EXIF/DCT pipeline would duplicate far
  more logic than `Find-DuplicateFile`'s much simpler hashing -- a plain `Import-Module` alone
  doesn't work here, since it only exposes what the module exports (just `Find-SimilarImage`),
  not the private function the parallel path needs to call. Image decoding itself always
  requires Windows -- it uses `System.Drawing`, which has no cross-platform fallback.

### Running / testing

```powershell
Import-Module .\Common.psd1 -Force
```

To exercise `Find-DuplicateFile`'s or `Find-SimilarImage`'s `Get-ChildItem` fallback path even
when the Everything CLI is installed, pass `-UseNative`.
