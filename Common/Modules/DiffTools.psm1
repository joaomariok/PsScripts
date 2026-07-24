# =============================================================================================
# DiffTools
#
# Two commands built on one shared LCS (Longest Common Subsequence) diff engine:
#   Compare-Diff      - line-based diff (git-style unified, or WinMerge-style side-by-side)
#   Compare-CharDiff  - character-based diff (inline, git word-diff-style markers)
#
# Import-Module this file; only Compare-Diff and Compare-CharDiff are exported - everything
# else below is a private implementation detail and isn't meant to be called directly.
#
# After importing, run `Get-Help Compare-Diff -Full` or `Get-Help Compare-CharDiff -Full`
# for complete parameter docs, examples, and known limitations for each command.
# =============================================================================================

# ---- shared LCS diff engine, used by both Compare-Diff and Compare-CharDiff.
# Takes two arrays/lists of comparable items (lines for Compare-Diff, characters for
# Compare-CharDiff) and returns an ordered list of Equal/Remove/Add entries. -FunctionName and
# -UnitName only affect the wording of the size-guard error message, so it reads naturally
# regardless of which caller hit it.
function Get-DiffOps {
    param(
        [Parameter(Mandatory)] $LeftItems,
        [Parameter(Mandatory)] $RightItems,
        [switch]$Force,
        [string]$FunctionName = 'Compare-Diff',
        [string]$UnitName = 'lines'
    )

    $n = $LeftItems.Count
    $m = $RightItems.Count

    if (-not $Force -and ([long]$n * [long]$m) -gt 4000000) {
        throw "${FunctionName}: inputs are $n x $m $UnitName ($([long]$n * $m) cells). The O(n*m) LCS algorithm would be slow/memory-heavy. Re-run with -Force to proceed anyway, or use 'git diff --no-index' / fc.exe for large files."
    }

    # ---- LCS dynamic-programming table ----
    $dp = [int[,]]::new($n + 1, $m + 1)
    for ($i = $n - 1; $i -ge 0; $i--) {
        for ($j = $m - 1; $j -ge 0; $j--) {
            if ($LeftItems[$i] -ceq $RightItems[$j]) {
                $dp[$i, $j] = $dp[($i + 1), ($j + 1)] + 1
            }
            else {
                $a = $dp[($i + 1), $j]; $b = $dp[$i, ($j + 1)]
                $dp[$i, $j] = if ($a -ge $b) { $a } else { $b }
            }
        }
    }

    # ---- backtrack into an ordered list of Equal/Remove/Add entries ----
    $diff = [System.Collections.Generic.List[object]]::new()
    $i = 0; $j = 0
    while ($i -lt $n -and $j -lt $m) {
        if ($LeftItems[$i] -ceq $RightItems[$j]) {
            $diff.Add([pscustomobject]@{ Type = 'Equal'; Text = $LeftItems[$i] })
            $i++; $j++
        }
        elseif ($dp[($i + 1), $j] -ge $dp[$i, ($j + 1)]) {
            $diff.Add([pscustomobject]@{ Type = 'Remove'; Text = $LeftItems[$i] })
            $i++
        }
        else {
            $diff.Add([pscustomobject]@{ Type = 'Add'; Text = $RightItems[$j] })
            $j++
        }
    }
    while ($i -lt $n) { $diff.Add([pscustomobject]@{ Type = 'Remove'; Text = $LeftItems[$i] }); $i++ }
    while ($j -lt $m) { $diff.Add([pscustomobject]@{ Type = 'Add';    Text = $RightItems[$j] }); $j++ }

    # ---- annotate with running left/right positions (used for hunk headers) ----
    $leftNum = 1; $rightNum = 1
    foreach ($e in $diff) {
        $e | Add-Member -NotePropertyName LeftPos  -NotePropertyValue $leftNum
        $e | Add-Member -NotePropertyName RightPos -NotePropertyValue $rightNum
        switch ($e.Type) {
            'Equal'  { $leftNum++; $rightNum++ }
            'Remove' { $leftNum++ }
            'Add'    { $rightNum++ }
        }
    }

    return , $diff
}

# ---- shared hunk-selection logic ("what to show"), used by both presentation layers below.
# $Context < 0 is the sentinel for "no collapsing - treat the whole file as a single hunk".
function Get-DiffHunks {
    param(
        [Parameter(Mandatory)] $Diff,
        [int]$Context = 3
    )

    $n = $Diff.Count
    if ($n -eq 0) { return , @() }

    if ($Context -lt 0) {
        $ranges = @([pscustomobject]@{ Start = 0; End = $n - 1 })
    }
    else {
        $changeIdx = for ($k = 0; $k -lt $n; $k++) { if ($Diff[$k].Type -ne 'Equal') { $k } }
        # NOTE: $changeIdx is $null if the loop yields nothing, a bare scalar int if it yields
        # exactly one value, or an array otherwise. Checking "-not $changeIdx" would be wrong:
        # if the single change happens to be at index 0, $changeIdx is the scalar 0, and PowerShell
        # treats -not 0 as $true, which would wrongly report "no changes" here. Use an explicit
        # null check instead so a lone change at index 0 isn't silently dropped.
        if ($null -eq $changeIdx) { return , @() }

        $ranges = [System.Collections.Generic.List[object]]::new()
        $curStart = -1; $curEnd = -1
        foreach ($idx in $changeIdx) {
            $s = [Math]::Max(0, $idx - $Context)
            $e = [Math]::Min($n - 1, $idx + $Context)
            if ($curStart -eq -1) { $curStart = $s; $curEnd = $e }
            elseif ($s -le ($curEnd + 1)) { $curEnd = [Math]::Max($curEnd, $e) }
            else { $ranges.Add([pscustomobject]@{ Start = $curStart; End = $curEnd }); $curStart = $s; $curEnd = $e }
        }
        if ($curStart -ne -1) { $ranges.Add([pscustomobject]@{ Start = $curStart; End = $curEnd }) }
    }

    # attach the header metadata (line positions/counts) once here, so every presentation
    # layer that consumes $Hunks renders identical @@ headers without recomputing anything.
    $hunks = foreach ($r in $ranges) {
        $slice = $Diff[$r.Start..$r.End]
        [pscustomobject]@{
            Start      = $r.Start
            End        = $r.End
            LeftStart  = $slice[0].LeftPos
            RightStart = $slice[0].RightPos
            LeftCount  = ($slice | Where-Object { $_.Type -in 'Equal', 'Remove' } | Measure-Object).Count
            RightCount = ($slice | Where-Object { $_.Type -in 'Equal', 'Add' }    | Measure-Object).Count
        }
    }

    return , @($hunks)
}

function Test-DiffCollection {
    param($Value)
    # Native arrays (what Get-Content returns) are the common case, but anything else people
    # reasonably pass as "a list of lines" - ArrayList, List[string], other IEnumerable - should
    # be treated the same way. Strings are IEnumerable too (of chars), so exclude them explicitly.
    return ($Value -is [System.Collections.IEnumerable]) -and (-not ($Value -is [string]))
}

function Resolve-DiffLines {
    param($Value, [switch]$IsText, [string]$Side, [string]$FunctionName)

    if (Test-DiffCollection $Value) {
        return , @($Value | ForEach-Object { [string]$_ })
    }

    $s = [string]$Value

    if ($IsText) {
        return , ($s -split "`r?`n")
    }

    if (-not (Test-Path -LiteralPath $s -PathType Leaf)) {
        throw "${FunctionName}: -$Side was not given -${Side}IsText, and '$s' is not an existing file. Pass -${Side}IsText if you meant literal text."
    }
    return , @(Get-Content -LiteralPath $s)
}

function Resolve-DiffText {
    param($Value, [switch]$IsText, [string]$Side, [string]$FunctionName)

    if (Test-DiffCollection $Value) {
        return ($Value | ForEach-Object { [string]$_ }) -join "`n"
    }

    $s = [string]$Value

    if ($IsText) {
        return $s
    }

    if (-not (Test-Path -LiteralPath $s -PathType Leaf)) {
        throw "${FunctionName}: -$Side was not given -${Side}IsText, and '$s' is not an existing file. Pass -${Side}IsText if you meant literal text."
    }
    return (Get-Content -LiteralPath $s -Raw)
}

# ---- produces the "--- <label>" / "+++ <label>" style header text: the real path when -Left
# or -Right was a file, or a generic placeholder when it was literal text or a collection.
function Get-DiffLabel {
    param($Value, [switch]$IsText, [string]$DefaultLabel)
    if (Test-DiffCollection $Value) { return $DefaultLabel }
    if ($IsText) { return $DefaultLabel }
    return [string]$Value
}

<#
.SYNOPSIS
    Line-based diff between two files and/or text blocks, printed as a git-style unified diff
    or a WinMerge-style side-by-side view.

.DESCRIPTION
    Compare-Diff runs an O(n*m) LCS (Longest Common Subsequence) diff over the lines of -Left
    and -Right, then renders the result in one of two styles. Both styles are driven by the same
    hunk-selection logic (see -Context / -Full) - given the same setting, they always agree on
    which lines count as "near" a change; they differ only in how each hunk is laid out.

    For a character-level diff instead - to see exactly which characters changed within a single
    sentence or line, rather than which lines changed - use Compare-CharDiff.

.PARAMETER Left
    The "left" / original / "-" side. One of:
      - a file path (default)
      - a literal text block (pass -LeftIsText)
      - a collection of lines - array, ArrayList, List[string], or any other non-string
        IEnumerable - detected automatically, no switch needed

.PARAMETER Right
    The "right" / new / "+" side. Same accepted forms as -Left (use -RightIsText for literal text).

.PARAMETER LeftIsText
    Treat -Left as a literal text block (split on newlines) instead of a file path. Ignored if
    -Left is already a collection.

.PARAMETER RightIsText
    Treat -Right as a literal text block instead of a file path. Ignored if -Right is already a
    collection.

.PARAMETER Style
    'Unified' (default) - git-style output with @@ hunk headers.
    'SideBySide' - WinMerge-style two-column view.

.PARAMETER Context
    Number of unchanged lines shown around each change, in both styles. Default 3 (git's
    default). A negative value (e.g. -1) disables hunk collapsing entirely and shows the
    complete file as one hunk - -Full is a clearer way to say the same thing.

.PARAMETER Full
    Show the complete file with no context collapsing. Equivalent to -Context -1; overrides
    whatever -Context is set to.

.PARAMETER NoColor
    Disable colored output (useful when redirecting to a file).

.PARAMETER Force
    Skip the size guard that blocks very large inputs. The LCS algorithm is O(n*m) in both time
    and memory, so this is a real limitation, not just a formality - see .NOTES.

.EXAMPLE
    Compare-Diff -Left .\old.cpp -Right .\new.cpp

.EXAMPLE
    Compare-Diff -Left "a`nb`nc" -LeftIsText -Right "a`nx`nc" -RightIsText -Style SideBySide

.EXAMPLE
    Compare-Diff -Left .\old.cpp -Right .\new.cpp -Style SideBySide -Full
    # shows the whole file side-by-side instead of collapsing unchanged stretches into hunks

.EXAMPLE
    Compare-Diff -Left .\old.cpp -Right .\new.cpp -Context 0
    # tightest possible hunks - only the changed lines themselves, no surrounding context

.EXAMPLE
    Compare-Diff -Left @("a","b","c") -Right (Get-Content .\new.txt)
    # -Left/-Right accept any collection of lines, not just what Get-Content returns

.NOTES
    - The diff engine is a classic O(n*m) dynamic-programming LCS - conceptually the same family
      as GNU diff/git (which use the more efficient Myers algorithm internally). Measured on this
      machine: two ~1400-line files (~2M DP cells) took about 3 seconds. That scales
      quadratically, so a 5000-line pair (~25M cells) would be well over a minute - not something
      to reach for on large files. There's a built-in guard (see -Force) that blocks inputs above
      4,000,000 cells unless you explicitly opt in. For large files, prefer
      `git diff --no-index -- file1 file2` or `fc.exe` instead.
    - Hunk selection and rendering are deliberately separate: a private helper decides *what* to
      show (which line ranges count as a hunk, and their header numbers), and the Unified/
      SideBySide renderers take identical parameters and only decide *how* to lay it out. Both
      styles therefore always show the same hunks for the same -Context/-Full.
    - SideBySide is a simplified rendering: within a hunk, it does not pair up "changed" lines the
      way WinMerge's alignment heuristics do. Consecutive Remove/Add runs are shown as blank-padded
      rows on the opposite column - visually similar to WinMerge, but not an exact replication of
      its alignment.
    - Line comparison is case-sensitive (-ceq), matching git's default behavior.

.LINK
    Compare-CharDiff
#>
function Compare-Diff {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [object]$Left,

        [Parameter(Mandatory, Position = 1)]
        [object]$Right,

        [switch]$LeftIsText,
        [switch]$RightIsText,

        [ValidateSet('Unified', 'SideBySide')]
        [string]$Style = 'Unified',

        [int]$Context = 3,

        [switch]$Full,

        [switch]$NoColor,

        [switch]$Force
    )

    $leftLines  = Resolve-DiffLines -Value $Left  -IsText:$LeftIsText  -Side 'Left'  -FunctionName 'Compare-Diff'
    $rightLines = Resolve-DiffLines -Value $Right -IsText:$RightIsText -Side 'Right' -FunctionName 'Compare-Diff'

    $leftLabel  = Get-DiffLabel -Value $Left  -IsText:$LeftIsText  -DefaultLabel '(left text block)'
    $rightLabel = Get-DiffLabel -Value $Right -IsText:$RightIsText -DefaultLabel '(right text block)'

    $diff = Get-DiffOps -LeftItems $leftLines -RightItems $rightLines -Force:$Force -FunctionName 'Compare-Diff' -UnitName 'lines'

    if (($diff | Where-Object { $_.Type -ne 'Equal' } | Measure-Object).Count -eq 0) {
        Write-Host "No differences." -ForegroundColor Green
        return
    }

    $effectiveContext = if ($Full) { -1 } else { $Context }
    $hunks = Get-DiffHunks -Diff $diff -Context $effectiveContext

    # Both renderers below take the exact same parameters ($Diff, $Hunks, -NoColor, $LeftLabel,
    # $RightLabel) - Get-DiffHunks already decided *what* to show, so from here the two functions
    # differ only in *how* they lay it out. Swap in a new one without touching the logic above.
    if ($Style -eq 'Unified') {
        Write-UnifiedDiff -Diff $diff -Hunks $hunks -NoColor:$NoColor -LeftLabel $leftLabel -RightLabel $rightLabel
    }
    else {
        Write-SideBySideDiff -Diff $diff -Hunks $hunks -NoColor:$NoColor -LeftLabel $leftLabel -RightLabel $rightLabel
    }
}

<#
.SYNOPSIS
    Character-level diff between two text blocks, rendered inline with git word-diff-style
    [-removed-] / {+added+} markers.

.DESCRIPTION
    Compare-CharDiff runs the same O(n*m) LCS engine as Compare-Diff, but over individual
    characters instead of lines, so it shows exactly which characters changed rather than which
    lines changed. Output is a single inline stream, not a line-by-line list: unchanged text is
    printed as-is, removed spans are wrapped as [-text-], and added spans as {+text+}, colorized
    red/green when not -NoColor.

    Meant for short-to-medium text - a sentence, a single line, a short snippet - not whole
    documents; see .NOTES for why. For line-based diffs of files, use Compare-Diff instead.

.PARAMETER Left
    The "left" / original side. One of:
      - a file path (default)
      - a literal text block (pass -LeftIsText)
      - a collection of lines - array, ArrayList, List[string], or any other non-string
        IEnumerable - joined with newlines before comparing

.PARAMETER Right
    The "right" / new side. Same accepted forms as -Left (use -RightIsText for literal text).

.PARAMETER LeftIsText
    Treat -Left as a literal text block instead of a file path. Ignored if -Left is already a
    collection.

.PARAMETER RightIsText
    Treat -Right as a literal text block instead of a file path. Ignored if -Right is already a
    collection.

.PARAMETER NoColor
    Disable colored output. The [-removed-] / {+added+} markers are still shown in this mode,
    since color is otherwise the only signal of what changed.

.PARAMETER Force
    Skip the size guard that blocks very large inputs - see .NOTES.

.EXAMPLE
    Compare-CharDiff -Left "The quick brown fox" -LeftIsText -Right "The quick red fox" -RightIsText
    # The quick [-b-]r[-own-]{+ed+} fox
    # (LCS finds the shared "r" between "brown" and "red" - correct, if not how a human would phrase it)

.EXAMPLE
    Compare-CharDiff -Left "cat" -LeftIsText -Right "cats" -RightIsText
    # cat{+s+}

.NOTES
    - Same O(n*m) LCS engine and 4,000,000-cell size guard as Compare-Diff (see -Force), but here
      the "cells" are characters, not lines, so the guard bites at much shorter input - around
      2000 characters per side. This command is meant for short text, not whole files.
    - Splits on .NET chars (UTF-16 code units), not Unicode grapheme clusters. Characters outside
      the Basic Multilingual Plane (most emoji, a few rare scripts) are represented as surrogate
      pairs and could in principle be split across a removed/added boundary, which would render
      oddly. Plain text, code, and most natural-language scripts are unaffected.
    - Comparison is case-sensitive (-ceq), matching git's default behavior.

.LINK
    Compare-Diff
#>
function Compare-CharDiff {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [object]$Left,

        [Parameter(Mandatory, Position = 1)]
        [object]$Right,

        [switch]$LeftIsText,
        [switch]$RightIsText,

        [switch]$NoColor,

        [switch]$Force
    )

    $leftText  = Resolve-DiffText -Value $Left  -IsText:$LeftIsText  -Side 'Left'  -FunctionName 'Compare-CharDiff'
    $rightText = Resolve-DiffText -Value $Right -IsText:$RightIsText -Side 'Right' -FunctionName 'Compare-CharDiff'

    $leftChars  = $leftText.ToCharArray()
    $rightChars = $rightText.ToCharArray()

    $diff = Get-DiffOps -LeftItems $leftChars -RightItems $rightChars -Force:$Force -FunctionName 'Compare-CharDiff' -UnitName 'characters'

    if (($diff | Where-Object { $_.Type -ne 'Equal' } | Measure-Object).Count -eq 0) {
        Write-Host $leftText
        return
    }

    Write-CharDiff -Diff $diff -NoColor:$NoColor
}

# ---- presentation layer (Unified style): given precomputed hunks, decides only *how* to lay
# each one out. See Compare-Diff's .NOTES for the what/how split with Write-SideBySideDiff.
function Write-UnifiedDiff {
    param($Diff, $Hunks, [switch]$NoColor, [string]$LeftLabel, [string]$RightLabel)

    function Write-DiffLine($text, $color) {
        if ($NoColor) { Write-Host $text } else { Write-Host $text -ForegroundColor $color }
    }

    Write-DiffLine "--- $LeftLabel"  'DarkYellow'
    Write-DiffLine "+++ $RightLabel" 'DarkYellow'

    foreach ($hunk in $Hunks) {
        $slice = $Diff[$hunk.Start..$hunk.End]

        Write-DiffLine "@@ -$($hunk.LeftStart),$($hunk.LeftCount) +$($hunk.RightStart),$($hunk.RightCount) @@" 'Cyan'

        foreach ($e in $slice) {
            switch ($e.Type) {
                'Equal'  { Write-DiffLine "  $($e.Text)" 'Gray' }
                'Remove' { Write-DiffLine "- $($e.Text)" 'Red' }
                'Add'    { Write-DiffLine "+ $($e.Text)" 'Green' }
            }
        }
    }
}

# ---- presentation layer (SideBySide style): identical parameters to Write-UnifiedDiff, same
# hunks, only the layout differs. See Compare-Diff's .NOTES.
function Write-SideBySideDiff {
    param($Diff, $Hunks, [switch]$NoColor, [string]$LeftLabel, [string]$RightLabel)

    function Write-DiffLine($text, $color) {
        if ($NoColor) { Write-Host $text } else { Write-Host $text -ForegroundColor $color }
    }

    $consoleWidth = try { $Host.UI.RawUI.WindowSize.Width } catch { 120 }
    if (-not $consoleWidth -or $consoleWidth -lt 40) { $consoleWidth = 120 }
    $colWidth = [Math]::Max(20, [int](($consoleWidth - 7) / 2))

    function Get-Padded($text, $width) {
        if ($null -eq $text) { $text = '' }
        if ($text.Length -gt $width) { return $text.Substring(0, $width - 1) + '~' }
        return $text.PadRight($width)
    }

    Write-DiffLine ("{0} | {1}" -f (Get-Padded $LeftLabel $colWidth), (Get-Padded $RightLabel $colWidth)) 'DarkYellow'
    Write-DiffLine ('-' * $consoleWidth) 'DarkYellow'

    foreach ($hunk in $Hunks) {
        $slice = $Diff[$hunk.Start..$hunk.End]

        Write-DiffLine "@@ -$($hunk.LeftStart),$($hunk.LeftCount) +$($hunk.RightStart),$($hunk.RightCount) @@" 'Cyan'

        foreach ($e in $slice) {
            switch ($e.Type) {
                'Equal'  { Write-DiffLine ("{0} | {1}" -f (Get-Padded $e.Text $colWidth), (Get-Padded $e.Text $colWidth)) 'Gray' }
                'Remove' { Write-DiffLine ("{0} | {1}" -f (Get-Padded $e.Text $colWidth), (Get-Padded '' $colWidth)) 'Red' }
                'Add'    { Write-DiffLine ("{0} | {1}" -f (Get-Padded '' $colWidth), (Get-Padded $e.Text $colWidth)) 'Green' }
            }
        }
    }
}

# ---- presentation layer for Compare-CharDiff: groups consecutive same-type diff entries into
# runs (so "brown" -> "own" doesn't print one marker per character) and writes each run inline.
function Write-CharDiff {
    param($Diff, [switch]$NoColor)

    function Write-Chunk($text, $color) {
        if ($NoColor) { Write-Host $text -NoNewline } else { Write-Host $text -NoNewline -ForegroundColor $color }
    }

    $curType = $null
    $buf = [System.Text.StringBuilder]::new()

    function Write-Flushed {
        if ($buf.Length -eq 0) { return }
        $text = $buf.ToString()
        switch ($curType) {
            'Equal'  { Write-Chunk $text 'Gray' }
            'Remove' { Write-Chunk "[-$text-]" 'Red' }
            'Add'    { Write-Chunk "{+$text+}" 'Green' }
        }
        [void]$buf.Clear()
    }

    foreach ($e in $Diff) {
        if ($e.Type -ne $curType) {
            Write-Flushed
            $curType = $e.Type
        }
        [void]$buf.Append([string]$e.Text)
    }
    Write-Flushed
    Write-Host ''
}

# Only the two user-facing commands are exported; Get-DiffOps, Get-DiffHunks, Test-DiffCollection,
# Resolve-DiffLines, Resolve-DiffText, Get-DiffLabel, Write-UnifiedDiff, Write-SideBySideDiff, and
# Write-CharDiff are implementation details and stay private to the module.
Export-ModuleMember -Function Compare-Diff, Compare-CharDiff
