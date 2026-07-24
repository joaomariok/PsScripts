Import-Module "$PSScriptRoot\Write.psm1" -Force
Import-Module "$PSScriptRoot\Guards.psm1" -Force
Import-Module "$PSScriptRoot\ExternalTools.psm1" -Force

# =============================================================================================
# Perceptual image similarity (Get-ImagePerceptualHash, Get-PerceptualDistance, Find-SimilarImage)
#
# Cryptographic hashes answer "are these bytes identical?". Perceptual hashes answer "do these
# look like the same picture?" -- they survive resizing, re-compression, format changes and mild
# colour edits. Requires System.Drawing, which is Windows-only from .NET 6 onward.
# =============================================================================================

Add-Type -AssemblyName System.Drawing

# ---- private: pairwise Hamming-distance comparison for perceptual hashes, done in C# rather
# than nested PowerShell loops -- pure PowerShell does roughly 500k comparisons per 5.6 seconds;
# the same loop in C# takes ~30ms, the difference between "usable on 500 photos" and "usable on
# 50,000". Two strategies are provided because neither wins at every threshold (measured on this
# machine, 20,000 synthetic hashes): FindPairsBruteForce is O(n^2) but its per-pair cost is
# trivial and constant regardless of threshold; FindPairsBKTree prunes via the triangle
# inequality (a node's children are bucketed by their exact distance to it, so a query only
# descends into buckets whose distance could still be within range) and is far faster at small
# thresholds (>20x at MaxDistance<=4) but LOSES to brute force once MaxDistance grows past ~8, as
# pruning stops eliminating enough of the tree to offset its own per-node overhead.
# FindPairsAuto picks between them using that measured crossover. Guarded so re-importing this
# module in the same session (Import-Module -Force) doesn't throw "type already exists".
if (-not ('PerceptualHashMatcher' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;

public static class PerceptualHashMatcher {
    public static int Distance(ulong a, ulong b) {
        ulong x = a ^ b; int c = 0;
        while (x != 0) { x &= x - 1; c++; }   // Kernighan popcount
        return c;
    }

    // Packs each matching pair as ((long)i << 32) | (uint)j
    public static long[] FindPairsBruteForce(ulong[] h, int maxDistance) {
        var result = new List<long>();
        for (int i = 0; i < h.Length - 1; i++)
            for (int j = i + 1; j < h.Length; j++)
                if (Distance(h[i], h[j]) <= maxDistance)
                    result.Add(((long)i << 32) | (uint)j);
        return result.ToArray();
    }

    // BK-tree: each node buckets its children by their exact distance to it. A query need only
    // descend into children whose bucket-distance lies within [d - maxDistance, d + maxDistance]
    // of the query's distance to the node -- anything outside that range cannot be close enough
    // to matter, by the triangle inequality.
    private sealed class Node {
        public ulong Hash; public int Index;
        public Dictionary<int, Node> Children = new Dictionary<int, Node>();
        public Node(ulong hash, int index) { Hash = hash; Index = index; }
    }

    public static long[] FindPairsBKTree(ulong[] h, int maxDistance) {
        var result = new List<long>();
        Node root = null;
        var stack = new Stack<Node>();

        for (int idx = 0; idx < h.Length; idx++) {
            ulong hash = h[idx];

            // Query everything inserted so far. Each hash queries only its predecessors, so
            // pairs come out as (earlier, later) exactly once -- same pairing as brute force.
            if (root != null) {
                stack.Clear();
                stack.Push(root);
                while (stack.Count > 0) {
                    Node cur = stack.Pop();
                    int d = Distance(hash, cur.Hash);
                    if (d <= maxDistance) result.Add(((long)cur.Index << 32) | (uint)idx);
                    int lo = d - maxDistance, hi = d + maxDistance;
                    foreach (var kv in cur.Children)
                        if (kv.Key >= lo && kv.Key <= hi) stack.Push(kv.Value);
                }
            }

            // Insert.
            if (root == null) { root = new Node(hash, idx); }
            else {
                Node cur = root;
                while (true) {
                    int d = Distance(hash, cur.Hash);
                    Node child;
                    if (cur.Children.TryGetValue(d, out child)) { cur = child; }
                    else { cur.Children[d] = new Node(hash, idx); break; }
                }
            }
        }
        return result.ToArray();
    }

    // Picks the matcher likely to be faster for this (size, threshold) pair, per the measured
    // crossover: the BK-tree wins decisively at small thresholds and loses at large ones. Below
    // a couple thousand hashes the whole thing is sub-second either way, so brute force is used
    // to avoid building a tree needlessly.
    public static long[] FindPairsAuto(ulong[] h, int maxDistance) {
        bool useTree = h.Length >= 2000 && maxDistance <= 6;
        return useTree ? FindPairsBKTree(h, maxDistance) : FindPairsBruteForce(h, maxDistance);
    }
}
'@ -ErrorAction Stop
}

# ---- private: pHash's 32x32 DCT, done in C# rather than nested PowerShell loops -- measured on
# this machine at ~15.7ms/image in PowerShell vs ~0.6ms/image here (~24x), which is nearly all of
# what made pHash slower than dHash. Computes only the top-left 8x8 output block, since that's
# all Get-PHashBits uses. Guarded so re-importing this module in the same session (Import-Module
# -Force) doesn't throw "type already exists" (same pattern as PerceptualHashMatcher above).
if (-not ('PHashDct' -as [type])) {
    Add-Type -TypeDefinition @'
using System;

public static class PHashDct {
    private const int N = 32;
    private static readonly double[,] Cos = Build();
    private static double[,] Build() {
        var c = new double[N, N];
        for (int k = 0; k < N; k++)
            for (int i = 0; i < N; i++)
                c[k, i] = Math.Cos(Math.PI * (i + 0.5) * k / N);
        return c;
    }

    // Input: 1024 doubles (32x32 luminance, row-major). Output: 64 doubles, the top-left 8x8
    // DCT-II block, row-major.
    public static double[] Compute(double[] gray32) {
        var rows = new double[N * N];
        for (int y = 0; y < N; y++) {
            int baseY = y * N;
            for (int k = 0; k < N; k++) {
                double s = 0;
                for (int i = 0; i < N; i++) s += gray32[baseY + i] * Cos[k, i];
                rows[baseY + k] = s;
            }
        }
        var outp = new double[64];
        for (int x = 0; x < 8; x++)
            for (int k = 0; k < 8; k++) {
                double s = 0;
                for (int i = 0; i < N; i++) s += rows[i * N + x] * Cos[k, i];
                outp[k * 8 + x] = s;
            }
        return outp;
    }
}
'@ -ErrorAction Stop
}

# Popcount lookup table: portable across Windows PowerShell 5.1 and PowerShell 7, avoids relying
# on 64-bit shift operator semantics.
$script:BitCount = [byte[]]::new(256)
for ($i = 1; $i -lt 256; $i++) { $script:BitCount[$i] = $script:BitCount[$i -shr 1] + ($i -band 1) }

$script:DctSize = 32

# ---- private: applies the EXIF orientation flag. Phone photos are frequently stored un-rotated
# with a flag telling the viewer to rotate; without this, the same photo "as shot" and "as
# exported" hash completely differently.
function ConvertTo-OrientedBitmap {
    param([Parameter(Mandatory)][System.Drawing.Image]$Image)

    try {
        $prop = $Image.GetPropertyItem(0x0112)   # throws if the tag is absent
        $orientation = [int]$prop.Value[0]
    }
    catch { return }

    $map = @{
        2 = 'RotateNoneFlipX'; 3 = 'Rotate180FlipNone'; 4 = 'Rotate180FlipX'
        5 = 'Rotate90FlipX';   6 = 'Rotate90FlipNone';  7 = 'Rotate270FlipX'
        8 = 'Rotate270FlipNone'
    }
    if ($map.ContainsKey($orientation)) {
        $Image.RotateFlip([System.Drawing.RotateFlipType]$map[$orientation])
    }
}

# ---- private: decodes an image, scales it to Width x Height and returns BT.601 luminance as a
# [double[,]] indexed [row, column].
function Get-GrayMatrix {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][int]$Width,
        [Parameter(Mandatory)][int]$Height,
        [switch]$IgnoreExifOrientation
    )

    $src = $null; $bmp = $null; $gfx = $null
    try {
        # Read via a stream so the file handle is released immediately and the file is not left
        # locked by GDI+.
        $bytes  = [System.IO.File]::ReadAllBytes($FilePath)
        $memory = [System.IO.MemoryStream]::new($bytes)
        $src    = [System.Drawing.Image]::FromStream($memory)

        if (-not $IgnoreExifOrientation) { ConvertTo-OrientedBitmap -Image $src }

        $bmp = [System.Drawing.Bitmap]::new($Width, $Height,
                    [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
        $gfx = [System.Drawing.Graphics]::FromImage($bmp)
        $gfx.CompositingMode    = [System.Drawing.Drawing2D.CompositingMode]::SourceCopy
        $gfx.InterpolationMode  = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $gfx.PixelOffsetMode    = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $gfx.SmoothingMode      = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
        $gfx.DrawImage($src, 0, 0, $Width, $Height)

        $rect = [System.Drawing.Rectangle]::new(0, 0, $Width, $Height)
        $data = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly,
                              [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
        try {
            $raw = [byte[]]::new($data.Stride * $Height)
            [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $raw, 0, $raw.Length)
        }
        finally { $bmp.UnlockBits($data) }

        $gray = New-Object 'double[,]' $Height, $Width
        for ($y = 0; $y -lt $Height; $y++) {
            $rowStart = $y * $data.Stride
            for ($x = 0; $x -lt $Width; $x++) {
                $o = $rowStart + $x * 3          # Format24bppRgb byte order is B,G,R
                $gray[$y, $x] = 0.299 * $raw[$o + 2] + 0.587 * $raw[$o + 1] + 0.114 * $raw[$o]
            }
        }
        # Unary comma: PowerShell enumerates (and thus flattens) multidimensional arrays on
        # output, so the matrix must be wrapped to survive the return.
        return ,$gray
    }
    finally {
        if ($gfx) { $gfx.Dispose() }
        if ($bmp) { $bmp.Dispose() }
        if ($src) { $src.Dispose() }
        if ($memory) { $memory.Dispose() }
    }
}

# ---- private: packs 64 booleans into 8 bytes, first bit = most significant bit of byte 0.
function ConvertTo-HashBytes {
    param([Parameter(Mandatory)][bool[]]$Bits)

    $bytes = [byte[]]::new(8)
    for ($i = 0; $i -lt 64; $i++) {
        # NOTE: [int](x/8) ROUNDS in PowerShell (12/8 -> 2), it does not truncate. Integer
        # division must be done explicitly with Math::Floor.
        $byteIndex = [int][Math]::Floor($i / 8)
        if ($Bits[$i]) { $bytes[$byteIndex] = $bytes[$byteIndex] -bor (1 -shl (7 - ($i % 8))) }
    }
    return ,$bytes
}

# ---- private: difference hash. Each bit says "is this pixel brighter than the one to its
# right?". Input must be a 9-wide, 8-tall luminance matrix.
function Get-DHashBits {
    param([Parameter(Mandatory)][double[,]]$Gray)

    $bits = [bool[]]::new(64); $n = 0
    for ($y = 0; $y -lt 8; $y++) {
        for ($x = 0; $x -lt 8; $x++) {
            $bits[$n++] = $Gray[$y, $x] -gt $Gray[$y, ($x + 1)]
        }
    }
    return $bits
}

# ---- private: perceptual hash. 2-D DCT-II of a 32x32 luminance matrix, keep the top-left 8x8
# low-frequency block, threshold against its median (DC term excluded). The DCT itself runs in
# C# (PHashDct, defined above) -- the PowerShell version this replaced cost ~15.7ms/image here
# and was almost all of pHash's per-image cost (see PHashDct's comment for the measured speedup).
function Get-PHashBits {
    param([Parameter(Mandatory)][double[,]]$Gray)

    $n = $script:DctSize

    # Flatten the n x n matrix to the row-major double[] PHashDct expects.
    $flat = [double[]]::new($n * $n)
    for ($y = 0; $y -lt $n; $y++) {
        $rowBase = $y * $n
        for ($x = 0; $x -lt $n; $x++) { $flat[$rowBase + $x] = $Gray[$y, $x] }
    }

    $block = [PHashDct]::Compute($flat)          # 64 doubles, top-left 8x8, row-major

    $sorted = ($block[1..63] | Sort-Object)      # median of the 63 non-DC coefficients
    $median = $sorted[31]

    $bits = [bool[]]::new(64)
    for ($i = 0; $i -lt 64; $i++) { $bits[$i] = $block[$i] -gt $median }
    return $bits
}

# ---- private: computes a 64-bit perceptual hash of an image file (dHash: fast, downscale +
# neighbour comparison; pHash: DCT-based, a bit more tolerant of heavy compression / brightness
# changes). pHash used to be ~50x slower than dHash when its DCT ran in PowerShell; now that the
# DCT runs in C# (PHashDct, above) they're within ~1.2x of each other, measured on this machine --
# the remaining gap is decode/resize to a larger 32x32 vs. dHash's 9x8. Used by Find-SimilarImage;
# requires Windows (System.Drawing).
function Get-ImagePerceptualHash {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipelineByPropertyName)]
        [Alias('FullName')]
        [string]$Path,

        [ValidateSet('dHash', 'pHash')]
        [string]$Algorithm = 'dHash',

        [switch]$IgnoreExifOrientation
    )

    process {
        $resolved = (Resolve-Path -LiteralPath $Path).ProviderPath
        try {
            if ($Algorithm -eq 'dHash') {
                $gray = Get-GrayMatrix -FilePath $resolved -Width 9 -Height 8 -IgnoreExifOrientation:$IgnoreExifOrientation
                $bits = Get-DHashBits -Gray $gray
            }
            else {
                $gray = Get-GrayMatrix -FilePath $resolved -Width $script:DctSize -Height $script:DctSize -IgnoreExifOrientation:$IgnoreExifOrientation
                $bits = Get-PHashBits -Gray $gray
            }
        }
        catch {
            Write-Warning "Could not hash '$resolved': $($_.Exception.Message)"
            return
        }

        $bytes = ConvertTo-HashBytes -Bits $bits

        # Detail score: how balanced the hash bits are. A blank wall or an all-black frame
        # produces a nearly all-zero hash and will collide with every other featureless image,
        # so surface this for filtering.
        $ones = 0; foreach ($b in $bytes) { $ones += $script:BitCount[$b] }
        $detail = [Math]::Round(1 - [Math]::Abs($ones - 32) / 32, 3)

        [PSCustomObject]@{
            Path        = $resolved
            Algorithm   = $Algorithm
            Hash        = (($bytes | ForEach-Object { $_.ToString('x2') }) -join '')
            HashBytes   = $bytes
            DetailScore = $detail
        }
    }
}

# ---- private: Hamming distance between two perceptual hashes (0 identical, 64 opposite).
# Accepts a 16-char hex string, a byte[8], or an object with a HashBytes property. Not currently
# called by anything in this module (Group-SimilarHash does its own distance math inline via the
# C# matcher) -- kept for standalone reuse.
function Get-PerceptualDistance {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]$First,
        [Parameter(Mandatory, Position = 1)]$Second
    )

    function ToBytes($v) {
        if ($v -is [byte[]]) { return $v }
        if ($v -is [string]) {
            $s = $v -replace '^0x', ''
            if ($s.Length -ne 16) { throw "Expected a 16-character hex hash, got '$v'." }
            return [byte[]](0..7 | ForEach-Object { [Convert]::ToByte($s.Substring($_ * 2, 2), 16) })
        }
        if ($v.PSObject.Properties.Name -contains 'HashBytes') { return $v.HashBytes }
        throw "Unsupported hash input of type $($v.GetType().FullName)."
    }

    $a = ToBytes $First
    $b = ToBytes $Second
    $d = 0
    for ($i = 0; $i -lt 8; $i++) { $d += $script:BitCount[($a[$i] -bxor $b[$i])] }
    return $d
}

# ---- private: groups hash records by Hamming distance via union-find, so A~B and B~C end up in
# the same group as A~C. Separated from file I/O so it can be tested without touching the disk.
function Group-SimilarHash {
    param(
        [Parameter(Mandatory)][object[]]$Record,
        [Parameter(Mandatory)][int]$MaxDistance,
        [ValidateSet('Auto', 'BruteForce', 'BKTree')][string]$Matcher = 'Auto'
    )

    $n = $Record.Count
    if ($n -lt 2) { return }

    # Pack each 8-byte hash big-endian into a UInt64 for the comparer.
    $packed = [UInt64[]]::new($n)
    for ($i = 0; $i -lt $n; $i++) {
        $hb = $Record[$i].HashBytes
        $v = [UInt64]0
        for ($k = 0; $k -lt 8; $k++) { $v = ($v -shl 8) -bor [UInt64]$hb[$k] }
        $packed[$i] = $v
    }

    $found = switch ($Matcher) {
        'BruteForce' { [PerceptualHashMatcher]::FindPairsBruteForce($packed, $MaxDistance) }
        'BKTree'     { [PerceptualHashMatcher]::FindPairsBKTree($packed, $MaxDistance) }
        default      { [PerceptualHashMatcher]::FindPairsAuto($packed, $MaxDistance) }
    }

    $parent = [int[]]::new($n)
    for ($i = 0; $i -lt $n; $i++) { $parent[$i] = $i }
    $findRoot = {
        param([int]$x)
        while ($parent[$x] -ne $x) { $parent[$x] = $parent[$parent[$x]]; $x = $parent[$x] }
        $x
    }

    $edges = [System.Collections.Generic.List[object]]::new()
    foreach ($p in $found) {
        $a = [int]($p -shr 32)
        $b = [int]($p -band 0xFFFFFFFFL)
        $edges.Add([PSCustomObject]@{
            A = $a; B = $b
            Distance = [PerceptualHashMatcher]::Distance($packed[$a], $packed[$b])
        })
        $ra = & $findRoot $a; $rb = & $findRoot $b
        if ($ra -ne $rb) { $parent[$rb] = $ra }
    }

    $groups = @{}
    for ($i = 0; $i -lt $n; $i++) {
        $r = & $findRoot $i
        if (-not $groups.ContainsKey($r)) { $groups[$r] = [System.Collections.Generic.List[int]]::new() }
        $groups[$r].Add($i)
    }

    # Single pass over $edges, bucketing each edge's distance by its group root -- NOT one
    # Where-Object rescan of all of $edges per group (previously O(groups * edges)). Real photo
    # libraries cluster far more than the random hashes used to benchmark the matcher above, so
    # $edges can be large enough that the old per-group rescan dwarfed the C# matcher's own cost.
    # & $findRoot is effectively O(1) here: the loop that built $groups above already walked
    # every index and fully path-compressed $parent.
    $maxDistanceByRoot = @{}
    foreach ($e in $edges) {
        $r = & $findRoot $e.A
        if (-not $maxDistanceByRoot.ContainsKey($r) -or $e.Distance -gt $maxDistanceByRoot[$r]) {
            $maxDistanceByRoot[$r] = $e.Distance
        }
    }

    foreach ($key in $groups.Keys) {
        $idx = $groups[$key]
        if ($idx.Count -lt 2) { continue }
        $members = @($idx | ForEach-Object { $Record[$_] })
        [PSCustomObject]@{
            Count           = $members.Count
            MaxPairDistance = if ($maxDistanceByRoot.ContainsKey($key)) { $maxDistanceByRoot[$key] } else { 0 }
            Members         = $members
        }
    }
}

<#
.SYNOPSIS
    Scans a folder tree and groups photos that look alike.

.DESCRIPTION
    Two stages: every candidate image is hashed once (Get-ImagePerceptualHash), then all hashes
    are compared pairwise for Hamming distance and merged into groups via union-find, so A~B and
    B~C end up in the same group as A~C. The pairwise comparison runs in a small C# helper type
    rather than nested PowerShell loops -- fast enough for tens of thousands of photos. This
    function only REPORTS similar images. It never deletes or modifies anything.

.PARAMETER Path
    Root folder to scan.

.PARAMETER MaxDistance
    How many of the 64 bits may differ and still count as the same photo. Measured guidance:
    0-2 catches resizes, format changes and re-compression; <=10 additionally catches small
    crops and slight rotations; unrelated photos in testing sat at 26+. Start at 10 and lower it
    if you see false matches.

.PARAMETER Algorithm
    dHash (default) or pHash -- see Get-ImagePerceptualHash.

.PARAMETER Extension
    File extensions to scan. Defaults to the common raster image formats.

.PARAMETER MinDetailScore
    Drops featureless images (blank walls, all-black frames) before grouping. Their hashes are
    degenerate and collide with each other. 0 disables it.

.PARAMETER UseNative
    Skip the Everything CLI ('es.exe') even if it's installed and running, and always enumerate
    via PowerShell's native Get-ChildItem instead. Same rationale as Find-DuplicateFile's
    -UseNative: forces a like-for-like comparison, or works around a stale Everything index.

.PARAMETER Parallel
    Hash images on multiple threads. PowerShell 7+ only; ignored on 5.1. Hashing is CPU-bound
    once an image is decoded, so this helps when the disk isn't the bottleneck (SSD, or cached
    data) and can HURT on a spinning disk, where concurrent reads cause seek thrashing. Measure
    with -ShowStats before trusting it on your data.

.PARAMETER ThrottleLimit
    Threads to use with -Parallel. Defaults to the processor count.

.PARAMETER Matcher
    Which pairwise-matching strategy Group-SimilarHash uses once every image is hashed:
      Auto (default) - picks BK-tree or brute force by the measured crossover (see
                       PerceptualHashMatcher in this module for the numbers). Right for almost
                       every case.
      BruteForce     - always O(n^2). Predictable cost; fastest choice at large -MaxDistance.
      BKTree         - always the tree. Fastest at small -MaxDistance, but slower than brute
                       force once -MaxDistance grows past the crossover.
    All three produce identical groupings -- this only affects speed.

.PARAMETER ShowStats
    Report images hashed/usable and hashing time vs. matching time separately, so it's visible
    which stage dominates on your data -- and therefore whether -Parallel or -Matcher is worth
    reaching for.

.PARAMETER CsvPath
    Optional. Write one row per file per group to this CSV file.

.PARAMETER JsonPath
    Optional. Write a JSON object to this file mapping each GroupId to its array of file paths,
    e.g. { "1": ["C:\...\a.jpg", "C:\...\b.jpg"], "2": [...] }.

.EXAMPLE
    Find-SimilarImage -Path 'D:\Photos' -MaxDistance 8 -Verbose

.EXAMPLE
    Find-SimilarImage -Path 'D:\Photos' -Parallel -ShowStats

.EXAMPLE
    Find-SimilarImage -Path 'D:\Photos' -CsvPath '.\similar.csv'

.EXAMPLE
    Find-SimilarImage -Path 'D:\Photos' -JsonPath '.\similar.json'

.NOTES
    Requires Windows -- image decoding uses System.Drawing, which is Windows-only even under
    modern .NET (throws PlatformNotSupportedException elsewhere).
    Uses the Everything CLI ('es.exe', https://www.voidtools.com/) for fast file enumeration
    when installed and running; falls back to Get-ChildItem otherwise. No behavior difference
    in results, only enumeration speed on large trees.
#>
function Find-SimilarImage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Path,
        [ValidateRange(0, 64)][int]$MaxDistance = 10,
        [ValidateSet('dHash', 'pHash')][string]$Algorithm = 'dHash',
        [string[]]$Extension = @('.jpg', '.jpeg', '.png', '.bmp', '.gif', '.tif', '.tiff', '.webp'),
        [ValidateRange(0, 1)][double]$MinDetailScore = 0.15,
        [switch]$UseNative,
        [switch]$Parallel,
        [int]$ThrottleLimit = [Environment]::ProcessorCount,
        [ValidateSet('Auto', 'BruteForce', 'BKTree')][string]$Matcher = 'Auto',
        [switch]$ShowStats,
        [string]$CsvPath,
        [string]$JsonPath
    )

    # --- Validate input -------------------------------------------------------
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "Path not found or not a directory: $Path"
    }

    $resolvedRoot = (Resolve-Path -LiteralPath $Path).ProviderPath
    Write-Title "Scanning for Similar Images in '$resolvedRoot'..."

    # --- Enumerate candidate files ---------------------------------------------
    # Same Everything-CLI-with-Get-ChildItem-fallback strategy as Find-DuplicateFile, via
    # ExternalTools.psm1's Get-EnumeratedFiles -- 'es' enumerates every file under the root
    # regardless of extension, so the image-extension filter below still runs either way.
    # -Verbose is forwarded explicitly: $VerbosePreference doesn't cross module boundaries on
    # its own, so without this, Get-EnumeratedFiles's Write-Verbose calls would stay silent even
    # when this function is called with -Verbose.
    $allFiles = @(Get-EnumeratedFiles -Root $resolvedRoot -UseNative:$UseNative -Verbose:$VerbosePreference)

    # Get-FilesViaEverything's objects (FullName/Length/LastWriteTime) don't carry an Extension
    # property like Get-ChildItem's FileInfo does, so derive it from FullName for both shapes.
    $files = @($allFiles | Where-Object { $Extension -contains [System.IO.Path]::GetExtension($_.FullName).ToLowerInvariant() })
    Write-Verbose "$($files.Count) candidate image files."
    if ($files.Count -lt 2) {
        Write-Warning "Fewer than 2 candidate images found."
        return
    }

    # --- Hash every candidate ---------------------------------------------------
    $hashTimer = [Diagnostics.Stopwatch]::StartNew()
    $records   = [System.Collections.Generic.List[object]]::new()

    if ($Parallel -and $PSVersionTable.PSVersion.Major -ge 7 -and $files.Count -gt 1) {
        Write-Verbose "Hashing $($files.Count) image(s) in parallel (throttle $ThrottleLimit)."

        # ForEach-Object -Parallel runspaces start fresh and cannot see this module's private
        # functions (Get-ImagePerceptualHash, Get-GrayMatrix, ...). Unlike Find-DuplicateFile's
        # Invoke-FileHashBatch -- which inlines its (much simpler) hashing logic directly into
        # the scriptblock -- re-inlining this module's GDI+/EXIF/DCT pipeline would duplicate
        # ~150 lines that would need to be kept in lockstep with Get-ImagePerceptualHash.
        # Plain `Import-Module $using:modulePath` does NOT fix this: Import-Module only exposes
        # what a module actually exports (just Find-SimilarImage here), regardless of which
        # scope re-imports it -- verified this fails with "term not recognized" before landing
        # on the fix below. `-PassThru` returns the module object, and `& $module { ... }` runs
        # the scriptblock inside that module's own session state, where its private functions
        # ARE visible. This calls the real Get-ImagePerceptualHash with no duplicated logic and
        # no change to what the module exports.
        #
        # CRITICAL: import once per runspace, not once per file. `ForEach-Object -Parallel`
        # reuses a pool of $ThrottleLimit runspaces across every item, so importing
        # unconditionally (with -Force, no less) on every single iteration means thousands of
        # concurrent Import-Module calls fighting over PowerShell's process-wide module-loading
        # locks -- measured this collapsing 16-way parallelism down to roughly one core's worth
        # of real throughput on a 4600-image run (CPU barely above idle despite 16 "concurrent"
        # threads). Checking Get-Module first means each runspace only pays the import cost
        # once, on its own first item, and reuses it for every later item that lands on the same
        # runspace.
        # Progress across runspaces needs a shared, lock-protected counter -- a Synchronized
        # hashtable only makes individual Get/Set calls thread-safe, not the read-increment-write
        # of "Done++", so each update takes the hashtable's own Monitor lock explicitly.
        $modulePath    = $PSCommandPath
        $totalFiles    = $files.Count
        $progressState = [hashtable]::Synchronized(@{ Done = 0 })
        $records.AddRange(@(
            $files | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
                $module = Get-Module -Name ImageSimilarity
                if (-not $module) { $module = Import-Module $using:modulePath -PassThru }
                $file = $_
                $algorithm = $using:Algorithm
                $h = & $module { param($Path, $Algorithm) Get-ImagePerceptualHash -Path $Path -Algorithm $Algorithm } $file.FullName $algorithm

                $state = $using:progressState
                [System.Threading.Monitor]::Enter($state)
                try { $done = ++$state.Done }
                finally { [System.Threading.Monitor]::Exit($state) }
                $total = $using:totalFiles
                Write-Progress -Activity 'Hashing images' -Status "$done / $total" -PercentComplete ($done * 100 / $total)

                if ($h) {
                    Add-Member -InputObject $h -NotePropertyName Length -NotePropertyValue $file.Length
                    $h
                }
            }
        ))
        Write-Progress -Activity 'Hashing images' -Completed
    }
    else {
        $i = 0
        foreach ($f in $files) {
            $i++
            # Split-Path works uniformly whether $f came from Get-ChildItem (has .Name) or
            # Get-FilesViaEverything (FullName only).
            Write-Progress -Activity 'Hashing images' -Status (Split-Path -Leaf $f.FullName) -PercentComplete ($i * 100 / $files.Count)
            $h = Get-ImagePerceptualHash -Path $f.FullName -Algorithm $Algorithm
            if ($h) {
                Add-Member -InputObject $h -NotePropertyName Length -NotePropertyValue $f.Length
                $records.Add($h)
            }
        }
        Write-Progress -Activity 'Hashing images' -Completed
    }
    $hashTimer.Stop()

    Write-Verbose "$($records.Count) image(s) hashed in $($hashTimer.ElapsedMilliseconds) ms."

    $usable  = @($records | Where-Object { $_.DetailScore -ge $MinDetailScore })
    $skipped = $records.Count - $usable.Count
    if ($skipped -gt 0) { Write-Verbose "$skipped low-detail image(s) excluded (DetailScore < $MinDetailScore)." }
    if ($usable.Count -lt 2) {
        Write-Warning "Fewer than 2 usable images after filtering."
        return
    }

    # --- Group by Hamming distance ---------------------------------------------
    $matchTimer = [Diagnostics.Stopwatch]::StartNew()
    $groups = @(Group-SimilarHash -Record $usable -MaxDistance $MaxDistance -Matcher $Matcher)
    $matchTimer.Stop()

    if ($groups.Count -eq 0) {
        Write-Success "No similar images found."
        return
    }

    # --- Build result objects ---------------------------------------------------
    # $flatRows mirrors $results one row per file per group (rather than per group with array
    # properties), for the CSV export below -- built from $g.Members directly so each row's
    # Hash/DetailScore/Length/FullName stay aligned to the same file.
    $groupId  = 0
    $flatRows = [System.Collections.Generic.List[object]]::new()
    # Wrapped in @() -- otherwise a single-group result is an unwrapped PSCustomObject, and
    # since that object has its own "Count" property (images in the group), $results.Count
    # below would silently resolve to that instead of the number of groups.
    $results = @(foreach ($g in $groups) {
        $groupId++
        foreach ($m in $g.Members) {
            $flatRows.Add([PSCustomObject]@{
                GroupId     = $groupId
                Hash        = $m.Hash
                DetailScore = $m.DetailScore
                Length      = $m.Length
                FullName    = $m.Path
            })
        }
        [PSCustomObject]@{
            GroupId         = $groupId
            Count           = $g.Count
            MaxPairDistance = $g.MaxPairDistance
            # Largest file first -- usually the best copy to keep.
            Files           = @($g.Members | Sort-Object Length -Descending | Select-Object -ExpandProperty Path)
            Hashes          = @($g.Members | Select-Object -ExpandProperty Hash)
        }
    })

    # --- Report ---------------------------------------------------------------
    $totalImages = ($results | Measure-Object -Property Count -Sum).Sum

    Write-EmptyLine
    Write-Text "Similar groups  : $($results.Count)"
    Write-Text "Images involved : $totalImages"
    Write-Text "Images skipped  : $skipped (insufficient detail)"
    Write-EmptyLine

    foreach ($r in $results) {
        Write-Title ("Group {0}  (max distance {1}, {2} images)" -f $r.GroupId, $r.MaxPairDistance, $r.Count)
        $r.Files | ForEach-Object { Write-Text "    $_" }
    }

    if ($ShowStats) {
        Write-EmptyLine
        Write-Text ('  images hashed : {0:N0}' -f $records.Count)
        Write-Text ('  usable        : {0:N0}' -f $usable.Count)
        Write-Text ('  hashing       : {0:N0} ms  ({1})' -f $hashTimer.ElapsedMilliseconds, $(if ($Parallel) { 'parallel' } else { 'serial' }))
        Write-Text ('  matching      : {0:N0} ms  (Matcher={1}, MaxDistance={2})' -f $matchTimer.ElapsedMilliseconds, $Matcher, $MaxDistance)
        Write-EmptyLine
    }

    if ($CsvPath) {
        $flatRows | Export-Csv -LiteralPath $CsvPath -NoTypeInformation -Encoding UTF8
        Write-Success "CSV written to: $CsvPath" -NoNewlineAfter
    }

    if ($JsonPath) {
        # [ordered] so groups round-trip in the same order they were reported in, not
        # hashtable-random order.
        $byGroup = [ordered]@{}
        foreach ($r in $results) { $byGroup["$($r.GroupId)"] = $r.Files }
        $byGroup | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $JsonPath -Encoding UTF8
        Write-Success "JSON written to: $JsonPath" -NoNewlineAfter
    }

    # Emit objects to the pipeline so the function composes with other commands.
    $results
}

Export-ModuleMember -Function Find-SimilarImage
