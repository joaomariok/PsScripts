Import-Module "$PSScriptRoot\Write.psm1" -Force
Import-Module "$PSScriptRoot\Guards.psm1" -Force
Import-Module "$PSScriptRoot\ExternalTools.psm1" -Force

# ---------------------------------------------------------------------------
# File-type taxonomy. Kept as module data rather than being buried in the
# filter so the categories can evolve (or be edited by the caller) without
# touching any scanning logic. Sets may overlap; resolution is a union.
# ---------------------------------------------------------------------------
$script:FileTypeExtension = @{
    Image      = '.jpg', '.jpeg', '.png', '.gif', '.bmp', '.tif', '.tiff', '.webp',
                 '.heic', '.heif', '.svg', '.ico', '.psd', '.raw', '.cr2', '.nef',
                 '.arw', '.dng'
    Video      = '.mp4', '.m4v', '.mkv', '.avi', '.mov', '.wmv', '.flv', '.webm',
                 '.mpg', '.mpeg', '.3gp', '.ts', '.m2ts', '.vob', '.ogv'
    Audio      = '.mp3', '.wav', '.flac', '.aac', '.m4a', '.ogg', '.oga', '.opus',
                 '.wma', '.aiff', '.aif', '.mid', '.midi'
    Document   = '.pdf', '.doc', '.docx', '.xls', '.xlsx', '.ppt', '.pptx', '.odt',
                 '.ods', '.odp', '.rtf', '.txt', '.md', '.csv', '.epub', '.mobi'
    Archive    = '.zip', '.rar', '.7z', '.tar', '.gz', '.tgz', '.bz2', '.xz',
                 '.zst', '.iso', '.cab'
    Code       = '.ps1', '.psm1', '.psd1', '.py', '.js', '.ts', '.jsx', '.tsx',
                 '.cs', '.java', '.c', '.h', '.cpp', '.hpp', '.go', '.rb', '.php',
                 '.rs', '.sh', '.sql', '.html', '.css', '.json', '.xml', '.yaml', '.yml'
    Executable = '.exe', '.dll', '.msi', '.msix', '.appx', '.bat', '.cmd', '.com', '.sys'
}

# ---- private: turns the user's category choice plus any explicit extensions into a
# single concrete extension list. Returns $null to mean "no filtering at all", which
# keeps the caller from having to special-case All.
function Resolve-FileTypeExtension {
    [CmdletBinding()]
    param(
        [string[]]$FileType,
        [string[]]$Extension
    )

    $wanted = [System.Collections.Generic.List[string]]::new()

    if ($FileType -and ($FileType -notcontains 'All')) {
        foreach ($type in $FileType) {
            if (-not $script:FileTypeExtension.ContainsKey($type)) {
                throw "Unknown file type '$type'. Known types: $(($script:FileTypeExtension.Keys | Sort-Object) -join ', ')"
            }
            foreach ($ext in $script:FileTypeExtension[$type]) { $wanted.Add($ext) }
        }
    }

    foreach ($ext in $Extension) {
        $normalized = $ext.ToLowerInvariant()
        if (-not $normalized.StartsWith('.')) { $normalized = ".$normalized" }
        $wanted.Add($normalized)
    }

    if ($wanted.Count -eq 0) { return $null }
    # Unary comma: without it PowerShell unrolls the pipeline output and a
    # single-extension result comes back as a bare string, not an array.
    return ,@($wanted | Sort-Object -Unique)
}

# ---- private: candidate selection. Two files of different sizes cannot be identical,
# so grouping by length discards most of the tree without opening a single file.
# Enumeration is delegated to Get-EnumeratedFiles (ExternalTools.psm1) -- same
# Everything-CLI-with-Get-ChildItem-fallback strategy as Find-SimilarImage.
function Get-CandidateFileGroup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [long]$MinimumSize = 1,
        [string[]]$Extension,
        [switch]$UseNative
    )

    # -Verbose is forwarded explicitly: $VerbosePreference doesn't cross module boundaries on
    # its own, so without this, Get-EnumeratedFiles's Write-Verbose calls would stay silent even
    # when this function is called with -Verbose.
    $allFiles = @(Get-EnumeratedFiles -Root $Path -UseNative:$UseNative -Verbose:$VerbosePreference)

    if ($allFiles.Count -eq 0) {
        Write-Warning "No files found under '$Path'."
        return @()
    }

    $filtered = $allFiles | Where-Object { $_.Length -ge $MinimumSize }
    if ($Extension) {
        # Get-FilesViaEverything's objects (FullName/Length/LastWriteTime) don't carry an
        # Extension property like Get-ChildItem's FileInfo does, so derive it from FullName
        # for both shapes (same fix as Find-SimilarImage).
        $filtered = $filtered | Where-Object { $Extension -contains [System.IO.Path]::GetExtension($_.FullName).ToLowerInvariant() }
    }

    Write-Verbose ("{0} files found, {1} pass the size/extension filter." -f $allFiles.Count, @($filtered).Count)
    @($filtered | Group-Object -Property Length | Where-Object { $_.Count -gt 1 })
}

# ---- private: one file -> one digest. MaxBytes > 0 hashes only the head of the file,
# which is how the cheap prefilter is expressed without a second near-identical function.
# UseCmdlet swaps the fast .NET path for Get-FileHash.
function Get-FileContentHash {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string]$Algorithm,
        [int]$MaxBytes = 0,
        [switch]$UseCmdlet
    )

    if ($UseCmdlet -and $MaxBytes -le 0) {
        return (Get-FileHash -LiteralPath $FilePath -Algorithm $Algorithm).Hash
    }

    $hasher = [System.Security.Cryptography.HashAlgorithm]::Create($Algorithm)
    try {
        # FileShare::ReadWrite so files held open by another process still read.
        # Deliberately NOT passing a large custom buffer: measured, a 1 MB buffer
        # is 6.5x SLOWER than the default on small files (one 1 MB allocation per
        # file) and no faster on large ones, where hash CPU dominates.
        $stream = [System.IO.File]::Open($FilePath, [System.IO.FileMode]::Open,
                      [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            if ($MaxBytes -gt 0) {
                $buffer = [byte[]]::new($MaxBytes)
                $read   = $stream.Read($buffer, 0, $MaxBytes)
                $bytes  = $hasher.ComputeHash($buffer, 0, $read)
            }
            else {
                $bytes = $hasher.ComputeHash($stream)
            }
            return [BitConverter]::ToString($bytes).Replace('-', '')
        }
        finally { $stream.Dispose() }
    }
    finally { $hasher.Dispose() }
}

# ---- private: two files -> bool, without hashing either. Aborts at the first differing
# byte, and skips hash computation entirely: measured ~6x faster than hashing both files.
# Compiles its C# helper on first use only (~600 ms), so callers that never hit a
# two-file group never pay for it. Guarded so re-importing this module in the same
# session (Import-Module -Force) doesn't throw "type already exists" (same pattern as
# ImageSimilarity.psm1's PerceptualHashMatcher).
function Test-FileContentEqual {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FirstPath,
        [Parameter(Mandatory)][string]$SecondPath,
        [int]$BufferSize = 262144
    )

    if (-not ('DuplicateFinder.FileComparer' -as [type])) {
        Write-Verbose 'Compiling byte comparer...'
        Add-Type -TypeDefinition @'
using System;
using System.IO;

namespace DuplicateFinder {
    public static class FileComparer {
        public static bool Equal(string p1, string p2, int bufSize) {
            using (var a = new FileStream(p1, FileMode.Open, FileAccess.Read, FileShare.ReadWrite, bufSize, FileOptions.SequentialScan))
            using (var b = new FileStream(p2, FileMode.Open, FileAccess.Read, FileShare.ReadWrite, bufSize, FileOptions.SequentialScan)) {
                if (a.Length != b.Length) return false;
                byte[] ba = new byte[bufSize], bb = new byte[bufSize];
                int n;
                while ((n = ReadFull(a, ba)) > 0) {
                    ReadFull(b, bb);
                    if (!new ReadOnlySpan<byte>(ba, 0, n).SequenceEqual(new ReadOnlySpan<byte>(bb, 0, n)))
                        return false;
                }
                return true;
            }
        }
        private static int ReadFull(Stream s, byte[] buf) {
            int total = 0, r;
            while (total < buf.Length && (r = s.Read(buf, total, buf.Length - total)) > 0) total += r;
            return total;
        }
    }
}
'@ -ErrorAction Stop
    }

    [DuplicateFinder.FileComparer]::Equal($FirstPath, $SecondPath, $BufferSize)
}

# ---- private: many files -> digests. Isolates the execution strategy (serial vs
# parallel) from both the hashing itself and the orchestration. -File is untyped
# (not [System.IO.FileInfo[]]) because Get-EnumeratedFiles may hand back
# Get-FilesViaEverything's PSCustomObject shape instead of a real FileInfo.
function Invoke-FileHashBatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$File,
        [Parameter(Mandatory)][string]$Algorithm,
        [switch]$UseCmdlet,
        [switch]$Parallel,
        [int]$ThrottleLimit = [Environment]::ProcessorCount
    )

    if ($File.Count -eq 0) { return }

    if ($Parallel -and $PSVersionTable.PSVersion.Major -ge 7 -and $File.Count -gt 1) {
        Write-Verbose "Hashing $($File.Count) file(s) in parallel (throttle $ThrottleLimit)."

        # ForEach-Object -Parallel starts fresh runspaces that cannot see this
        # module's private functions, so the hashing has to be inlined here
        # rather than calling Get-FileContentHash. $using: passes variables only.
        $results = $File.FullName | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
            $path = $_                                # $_ is rebound inside catch
            $algorithm = $using:Algorithm
            $viaCmdlet = $using:UseCmdlet
            try {
                if ($viaCmdlet) {
                    $hash = (Get-FileHash -LiteralPath $path -Algorithm $algorithm).Hash
                }
                else {
                    # HashAlgorithm is not thread-safe: one instance per thread.
                    $hasher = [System.Security.Cryptography.HashAlgorithm]::Create($algorithm)
                    try {
                        $stream = [System.IO.File]::Open($path, [System.IO.FileMode]::Open,
                                      [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
                        try { $hash = [BitConverter]::ToString($hasher.ComputeHash($stream)).Replace('-', '') }
                        finally { $stream.Dispose() }
                    }
                    finally { $hasher.Dispose() }
                }
                [pscustomobject]@{ Path = $path; Hash = $hash }
            }
            catch { Write-Warning ("Skipping '{0}': {1}" -f $path, $_.Exception.Message) }
        }

        $byPath = @{}
        foreach ($f in $File) { $byPath[$f.FullName] = $f }
        foreach ($r in $results) {
            [pscustomobject]@{ File = $byPath[$r.Path]; Hash = $r.Hash; Bytes = $byPath[$r.Path].Length }
        }
        return
    }

    $i = 0
    foreach ($f in $File) {
        $i++
        if ($File.Count -gt 50) {
            # Split-Path works uniformly whether $f came from Get-ChildItem (has .Name) or
            # Get-FilesViaEverything (FullName only).
            Write-Progress -Activity 'Hashing' -Status (Split-Path -Leaf $f.FullName) -PercentComplete ($i * 100 / $File.Count)
        }
        try {
            $hash = Get-FileContentHash -FilePath $f.FullName -Algorithm $Algorithm -UseCmdlet:$UseCmdlet
            [pscustomobject]@{ File = $f; Hash = $hash; Bytes = $f.Length }
        }
        catch { Write-Warning ("Skipping '{0}': {1}" -f $f.FullName, $_.Exception.Message) }
    }
    if ($File.Count -gt 50) { Write-Progress -Activity 'Hashing' -Completed }
}

# ---- private: the output contract, defined once so the byte-compare path and the hash
# path cannot drift apart. -File is untyped for the same duck-typing reason as
# Invoke-FileHashBatch above.
function New-DuplicateGroupResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$GroupId,
        [Parameter(Mandatory)][object[]]$File,
        [Parameter(Mandatory)][ValidateSet('Hash', 'ByteCompare')][string]$MatchedBy,
        [string]$Hash
    )

    $ordered = $File | Sort-Object -Property @{ Expression = 'Length'; Descending = $true }, FullName
    [pscustomobject]@{
        GroupId     = $GroupId
        Count       = $ordered.Count
        SizeBytes   = $ordered[0].Length
        WastedBytes = $ordered[0].Length * ($ordered.Count - 1)
        MatchedBy   = $MatchedBy
        Hash        = if ($PSBoundParameters.ContainsKey('Hash')) { $Hash } else { $null }
        Files       = @($ordered.FullName)
    }
}

<#
.SYNOPSIS
    Finds files with identical content in a folder and its subfolders.

.DESCRIPTION
    Duplicates are detected by content, never by name. Work proceeds in stages
    so as little data as possible is read: group by size, optionally prefilter
    large files by a head-only hash, then confirm by full hash or by direct
    byte comparison. This function only REPORTS duplicates. It never deletes or
    modifies anything.

.PARAMETER Path
    Root folder to scan.

.PARAMETER Strategy
    Fast (default)
        Hashes via .NET directly and compares two-file groups byte-for-byte.
        Measured up to ~4x faster end to end.
    Compatible
        Uses the Get-FileHash cmdlet and never compiles C#. Slower, but useful
        in locked-down environments where Add-Type is blocked, or when you want
        the plainest possible code path.

    Individual switches below always win over the strategy default.

.PARAMETER Algorithm
    SHA256 by default. MD5 was measured ~1.55x faster on large files and is
    fine for finding accidental duplicates, but is not collision-resistant
    against a deliberate attacker.

.PARAMETER MinimumSize
    Skip files smaller than this. Default 1, which drops zero-byte files: they
    are all technically identical to each other and are usually just noise.

.PARAMETER FileType
    Restrict the scan to one or more categories: Image, Video, Audio, Document,
    Archive, Code, Executable. Defaults to All, which applies no filter.
    Categories may overlap and are combined as a union.

    The extension list for each category lives in $script:FileTypeExtension at
    the top of the module and can be edited there.

.PARAMETER Extension
    Restrict to these extensions, with or without the leading dot. If both
    -FileType and -Extension are supplied the two sets are combined, so
    -FileType Image -Extension .xyz means "images, plus .xyz files".

.PARAMETER QuickPass
    For files above -QuickPassThreshold, hash only the first -HeadBytes first
    and drop anything whose head is unique. Only pays off when files differ
    near their start, which is common but not guaranteed.

.PARAMETER NoPairCompare
    Disable byte-for-byte comparison of two-file groups and hash them instead.

.PARAMETER UseFileHashCmdlet
    Force Get-FileHash even under -Strategy Fast.

.PARAMETER UseNative
    Skip the Everything CLI ('es.exe') even if it's installed and running, and always
    enumerate via PowerShell's native Get-ChildItem instead. Useful to force a
    like-for-like comparison, or if Everything's index might be stale for the folder
    being scanned.

.PARAMETER Parallel
    Hash on multiple threads. PowerShell 7+ only; ignored on 5.1. Helps when
    the CPU is the bottleneck (SSD, or cached data) and can HURT on a spinning
    disk, where concurrent reads cause seek thrashing. Measure before trusting.

.PARAMETER ShowStats
    Report files read, bytes read and throughput, to reveal whether you are
    disk bound (low MB/s: read less) or CPU bound (high MB/s: try -Parallel).

.PARAMETER CsvPath
    Optional. Write one row per file per group to this CSV file.

.PARAMETER JsonPath
    Optional. Write a JSON object to this file mapping each GroupId to its array of file paths,
    e.g. { "1": ["C:\...\a.txt", "C:\...\b.txt"], "2": [...] }.

.EXAMPLE
    Find-DuplicateFile -Path 'D:\Data'

.EXAMPLE
    Find-DuplicateFile -Path 'D:\Media' -QuickPass -Parallel -ShowStats |
        Sort-Object WastedBytes -Descending | Select-Object -First 20

.EXAMPLE
    Find-DuplicateFile -Path 'D:\Data' -Strategy Compatible -Algorithm MD5

.EXAMPLE
    # Only photos and videos, largest wasted space first
    Find-DuplicateFile -Path 'D:\Media' -FileType Image, Video |
        Sort-Object WastedBytes -Descending

.EXAMPLE
    Find-DuplicateFile -Path 'D:\Data' -UseNative
    # Always enumerates via Get-ChildItem, even if the Everything CLI is installed

.EXAMPLE
    Find-DuplicateFile -Path 'D:\Data' -JsonPath '.\duplicates.json'

.NOTES
    Uses the Everything CLI ('es.exe', https://www.voidtools.com/) for fast file enumeration
    when installed and running; falls back to Get-ChildItem otherwise. No behavior difference
    in results, only enumeration speed on large trees.
#>
function Find-DuplicateFile {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('FullName')]
        [string]$Path,

        [ValidateSet('Fast', 'Compatible')]
        [string]$Strategy = 'Fast',

        [ValidateSet('SHA256', 'SHA384', 'SHA512', 'SHA1', 'MD5')]
        [string]$Algorithm = 'SHA256',

        [long]$MinimumSize = 1,

        [ValidateSet('All', 'Image', 'Video', 'Audio', 'Document', 'Archive', 'Code', 'Executable')]
        [string[]]$FileType = 'All',

        [string[]]$Extension,

        [switch]$QuickPass,
        [long]$QuickPassThreshold = 10MB,
        [int]$HeadBytes = 65536,

        [switch]$NoPairCompare,
        [switch]$UseFileHashCmdlet,
        [switch]$UseNative,
        [switch]$Parallel,
        [int]$ThrottleLimit = [Environment]::ProcessorCount,
        [switch]$ShowStats,
        [string]$CsvPath,
        [string]$JsonPath
    )

    process {
        # --- Validate input -------------------------------------------------------
        if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
            throw "Path not found or not a directory: $Path"
        }

        $resolvedRoot = (Resolve-Path -LiteralPath $Path).ProviderPath
        Write-Title "Scanning for Duplicate Files in '$resolvedRoot'..."

        # Strategy sets the defaults; an explicitly supplied switch overrides it.
        $useCmdlet   = ($Strategy -eq 'Compatible')
        $comparePair = ($Strategy -eq 'Fast')
        if ($PSBoundParameters.ContainsKey('UseFileHashCmdlet')) { $useCmdlet   = [bool]$UseFileHashCmdlet }
        if ($PSBoundParameters.ContainsKey('NoPairCompare'))     { $comparePair = -not $NoPairCompare }

        Write-Verbose "Strategy=$Strategy UseCmdlet=$useCmdlet PairCompare=$comparePair Parallel=$Parallel"

        $timer     = [Diagnostics.Stopwatch]::StartNew()
        $bytesRead = [long]0
        $filesRead = [long]0

        # -FileType and -Extension are combined as a union: 'Image plus .xyz'.
        # A resolved value of $null means no extension filtering at all.
        $wantedExtension = Resolve-FileTypeExtension -FileType $FileType -Extension $Extension
        if ($wantedExtension) {
            Write-Verbose ("Extension filter ({0}): {1}" -f $wantedExtension.Count, ($wantedExtension -join ' '))
        }
        else { Write-Verbose 'No extension filter (all file types).' }

        # --- Enumerate + Stage 1 size pre-filter -----------------------------------
        $groups = @(Get-CandidateFileGroup -Path $resolvedRoot -MinimumSize $MinimumSize -Extension $wantedExtension `
                        -UseNative:$UseNative -Verbose:$VerbosePreference)
        Write-Verbose ("{0} size group(s) contain more than one file." -f $groups.Count)

        if ($groups.Count -eq 0) {
            Write-Success "No duplicates found (every file has a unique size)."
            return
        }

        $toHash  = [System.Collections.Generic.List[object]]::new()
        $results = [System.Collections.Generic.List[object]]::new()
        $groupId = 0

        foreach ($group in $groups) {
            $size = [long]$group.Name

            # Exactly two files: settle it without hashing anything.
            if ($comparePair -and $group.Count -eq 2) {
                $first, $second = $group.Group
                try {
                    $buffer = [int][Math]::Min(262144, [Math]::Max(4096, $size))
                    $filesRead += 2
                    $bytesRead += $size * 2      # upper bound; early exit reads less
                    if (Test-FileContentEqual -FirstPath $first.FullName -SecondPath $second.FullName -BufferSize $buffer) {
                        $groupId++
                        $results.Add((New-DuplicateGroupResult -GroupId $groupId -File @($first, $second) -MatchedBy ByteCompare))
                    }
                }
                catch { Write-Warning ("Skipping pair '{0}': {1}" -f $first.FullName, $_.Exception.Message) }
                continue
            }

            # Three or more: optional cheap head prefilter, then full hashing.
            if ($QuickPass -and $size -gt $QuickPassThreshold) {
                $heads = foreach ($file in $group.Group) {
                    try {
                        $filesRead++
                        $bytesRead += [Math]::Min($HeadBytes, $size)
                        [pscustomobject]@{
                            File = $file
                            Head = Get-FileContentHash -FilePath $file.FullName -Algorithm $Algorithm -MaxBytes $HeadBytes
                        }
                    }
                    catch {
                        # $_ is the ErrorRecord in here, so $file supplies the name.
                        Write-Warning ("Skipping head read '{0}': {1}" -f $file.FullName, $_.Exception.Message)
                    }
                }
                foreach ($headGroup in @($heads | Group-Object Head | Where-Object { $_.Count -gt 1 })) {
                    foreach ($h in $headGroup.Group) { $toHash.Add($h.File) }
                }
            }
            else {
                foreach ($file in $group.Group) { $toHash.Add($file) }
            }
        }

        $hashed = @(Invoke-FileHashBatch -File $toHash.ToArray() -Algorithm $Algorithm `
                        -UseCmdlet:$useCmdlet -Parallel:$Parallel -ThrottleLimit $ThrottleLimit)
        foreach ($h in $hashed) { $filesRead++; $bytesRead += $h.Bytes }

        foreach ($hashGroup in @($hashed | Group-Object Hash | Where-Object { $_.Count -gt 1 })) {
            $groupId++
            $results.Add((New-DuplicateGroupResult -GroupId $groupId -File @($hashGroup.Group.File) -MatchedBy Hash -Hash $hashGroup.Name))
        }

        $timer.Stop()

        if ($results.Count -eq 0) {
            Write-Success "No duplicates found."
            return
        }

        # --- Report -----------------------------------------------------------------
        $totalDupeFiles = ($results | Measure-Object -Property Count -Sum).Sum
        $redundantFiles = $totalDupeFiles - $results.Count
        $wastedBytes    = ($results | Measure-Object -Property WastedBytes -Sum).Sum

        Write-EmptyLine
        Write-Text "Duplicate groups : $($results.Count)"
        Write-Text "Files involved   : $totalDupeFiles"
        Write-Text "Redundant copies : $redundantFiles"
        Write-Text ("Reclaimable space: {0:N2} MB" -f ($wastedBytes / 1MB))
        Write-EmptyLine

        foreach ($r in $results) {
            Write-Title ("Group {0}  ({1:N0} bytes x {2} copies, {3})" -f $r.GroupId, $r.SizeBytes, $r.Count, $r.MatchedBy)
            $r.Files | ForEach-Object { Write-Text "    $_" }
        }

        if ($ShowStats) {
            $mb      = $bytesRead / 1MB
            $seconds = [Math]::Max($timer.Elapsed.TotalSeconds, 0.001)
            Write-EmptyLine
            Write-Text ('  size groups   : {0:N0}' -f $groups.Count)
            Write-Text ('  files read    : {0:N0}' -f $filesRead)
            Write-Text ('  data read     : {0:N1} MB' -f $mb)
            Write-Text ('  elapsed       : {0:N2} s' -f $seconds)
            Write-Text ('  throughput    : {0:N0} MB/s' -f ($mb / $seconds))
            Write-Text '  low MB/s  -> disk bound: read less (-MinimumSize, -QuickPass, -Extension)'
            Write-Text '  high MB/s -> CPU bound: try -Parallel or -Algorithm MD5'
            Write-EmptyLine
        }

        if ($CsvPath) {
            # One row per file per group (rather than per group with a Files array
            # property), same shape/rationale as Find-SimilarImage's $flatRows.
            $flatRows = foreach ($r in $results) {
                foreach ($f in $r.Files) {
                    [pscustomobject]@{
                        GroupId   = $r.GroupId
                        MatchedBy = $r.MatchedBy
                        Hash      = $r.Hash
                        SizeBytes = $r.SizeBytes
                        FullName  = $f
                    }
                }
            }
            $flatRows | Export-Csv -LiteralPath $CsvPath -NoTypeInformation -Encoding UTF8
            Write-Success "CSV written to: $CsvPath" -NoNewlineAfter
        }

        if ($JsonPath) {
            # [ordered] so groups round-trip in the same order they were reported in, not
            # hashtable-random order. Same shape/rationale as Find-SimilarImage's -JsonPath.
            $byGroup = [ordered]@{}
            foreach ($r in $results) { $byGroup["$($r.GroupId)"] = $r.Files }
            $byGroup | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $JsonPath -Encoding UTF8
            Write-Success "JSON written to: $JsonPath" -NoNewlineAfter
        }

        # Emit objects to the pipeline so the function composes with other commands.
        $results
    }
}

Export-ModuleMember -Function Find-DuplicateFile
