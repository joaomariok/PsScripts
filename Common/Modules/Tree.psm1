<#
.SYNOPSIS
    Displays a directory tree structure to the console.

.DESCRIPTION
    This function recursively displays a directory structure using tree-style formatting with connectors (├──, └──).
    It supports depth limiting, optional file inclusion, and alphabetical sorting with directories first.

.PARAMETER Path
    The path to the directory to display. Defaults to the current directory.

.PARAMETER Depth
    The maximum depth to traverse. -1 means unlimited depth. 0 shows only the root directory.

.PARAMETER IncludeFiles
    If specified, includes files in the output. By default, only directories are shown.

.PARAMETER Indent
    Internal parameter for recursion. Specifies the indentation string for the current level.

.EXAMPLE
    PS> Show-Tree
    # Displays the current directory structure (directories only, unlimited depth)

.EXAMPLE
    PS> Show-Tree -Path "C:\Projects" -Depth 2
    # Displays 2 levels of the C:\Projects directory

.EXAMPLE
    PS> Show-Tree -IncludeFiles
    # Displays the current directory structure including files
#>
function Show-Tree {
    param(
        [string]$Path = ".",
        [int]$Depth = -1,
        [switch]$IncludeFiles,
        [string]$Indent = ""
    )

    $resolved = Resolve-Path $Path -ErrorAction SilentlyContinue
    if (-not $resolved) { return }

    $item = Get-Item $resolved -ErrorAction SilentlyContinue
    if (-not $item) { return }

    # Print root name only
    if (-not $Indent) { Write-Host "$($item.Name)/" }

    if ($Depth -eq 0) { return }

    # Get children - directories first, then files, all alphabetically sorted
    $children = Get-ChildItem $resolved -Force -ErrorAction SilentlyContinue |
                Where-Object { $IncludeFiles -or $_.PSIsContainer } |
                Sort-Object @{Expression="PSIsContainer";Descending=$true}, Name

    for ($i = 0; $i -lt $children.Count; $i++) {
        $child = $children[$i]
        $isLast = ($i -eq $children.Count - 1)
        $connector = if ($isLast) { "└── " } else { "├── " }
        $childIndent = if ($isLast) { "    " } else { "│   " }
        $folderSuffix = if ($child.PSIsContainer) { "/" } else { "" }

        Write-Host "$Indent$connector$($child.Name)$folderSuffix"

        if ($child.PSIsContainer) {
            Show-Tree $child.FullName -Depth ($Depth - 1) -IncludeFiles:$IncludeFiles -Indent "$Indent$childIndent"
        }
    }
}

<#
.SYNOPSIS
    Renders a flat list of paths as an indented tree.

.DESCRIPTION
    Accepts full paths from the pipeline (one per line, e.g. from es.exe),
    builds a prefix tree, and prints it with box-drawing connectors.
    Preserves input order by default, so `es.exe -s` output stays sorted.
    Supports pipeline input via ValueFromPipeline and ValueFromPipelineByPropertyName,
    with automatic FullName property binding from Get-ChildItem objects.

    Folder detection (marked with a trailing "/"):
    1. Node has children in the result set -> folder, no filesystem hit.
    2. Every leaf -> checked against the filesystem with
       [System.IO.Directory]::Exists(), so names are never guessed from
       their shape (a folder named "MyLib.Core" is detected correctly).

.PARAMETER Path
    The array of paths to render as a tree. Accepts pipeline input either as
    strings (full paths) or objects with a FullName property (e.g., FileInfo).
    This parameter is mandatory and supports multiple paths.

.PARAMETER Sort
    If specified, re-sorts sibling entries alphabetically instead of preserving
    the original pipeline order. By default, input order is maintained, which
    is useful when piping sorted output from tools like es.exe.

.PARAMETER Collapse
    If specified, merges chains of folders that contain a single folder child
    into one line (GitHub-style). For example, "src/main/java/" instead of
    showing each folder on a separate line. Useful for reducing vertical space
    when displaying deep directory structures with sparse content.

.EXAMPLE
    es.exe -s -path C:\dev\myproject | Show-TreeFromList
    # Displays the search results as a tree, preserving es.exe's sorted order

.EXAMPLE
    es.exe -s ext:cpp;h path:src | Show-TreeFromList -Collapse
    # Displays C++ and header files in src folder as a tree with collapsed single child folders

.EXAMPLE
    Get-ChildItem -Recurse | Show-TreeFromList
    # Works with FileInfo objects via FullName property binding

.EXAMPLE
    Get-ChildItem -Recurse | Show-TreeFromList -Sort
    # Displays all files and folders with alphabetical sorting at each level
#>
function Show-TreeFromList {
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('FullName')]
        [string[]]$Path,

        # Re-sort siblings alphabetically instead of keeping pipeline order
        [switch]$Sort,

        # Merge chains of folders that contain a single folder child into one
        # line, GitHub-style (e.g. "src/main/java/")
        [switch]$Collapse
    )

    begin {
        # Ordered = preserves insertion order; PowerShell-created dictionaries
        # are case-insensitive, matching Windows path semantics.
        $tree = [ordered]@{}
    }

    process {
        foreach ($p in $Path) {
            if ([string]::IsNullOrWhiteSpace($p)) { continue }
            $parts = @($p -split '[\\/]+' -ne '')
            if ($parts.Count -eq 0) { continue }
            # Keep the UNC prefix on the root segment so reconstructed paths
            # stay valid for Directory.Exists (\\server\share\...)
            if ($p -match '^\\\\') { $parts[0] = '\\' + $parts[0] }
            $node = $tree
            foreach ($part in $parts) {
                if (-not $node.Contains($part)) {
                    $node[$part] = [ordered]@{}
                }
                $node = $node[$part]
            }
        }
    }

    end {
        # Iterative pre-order render with an explicit stack. A recursive
        # scriptblock costs one invocation per node, and every emitted line
        # travels back up through the nested pipelines (depth x lines) --
        # measured ~10s of 14s total on 100k paths. This loop renders the
        # same tree in ~0.5s.
        # Frame layout: 0=name, 1=node, 2=linePrefix(incl. connector),
        #               3=childPrefix, 4=realPath
        $out   = [System.Collections.Generic.List[string]]::new()
        $stack = [System.Collections.Generic.Stack[object[]]]::new()

        $rootKeys = @($tree.Keys)
        if ($Sort) { $rootKeys = @($rootKeys | Sort-Object) }
        [array]::Reverse($rootKeys)                    # stack is LIFO
        foreach ($rk in $rootKeys) {
            $stack.Push(@([string]$rk, $tree[$rk], '', '', [string]$rk))
        }

        while ($stack.Count -gt 0) {
            $f = $stack.Pop()
            $name = $f[0]; $node = $f[1]; $full = $f[4]

            if ($Collapse) {
                while ($node.Count -eq 1) {
                    $ck = $(foreach ($k in $node.Keys) { $k; break })
                    $cn = $node[$ck]
                    if ($cn.Count -eq 0) { break }     # single child is a leaf, not a folder
                    $name = "$name/$ck"
                    $full = "$full\$ck"
                    $node = $cn
                }
            }

            if ($node.Count -gt 0) {
                $name += '/'   # has children in the result set: definitely a folder
            }
            elseif ([System.IO.Directory]::Exists($full)) {
                # Leaf: only the filesystem can tell folder from file.
                $name += '/'
            }

            $out.Add($f[2] + $name)

            if ($node.Count -gt 0) {
                $keys = @($node.Keys)
                if ($Sort) { $keys = @($keys | Sort-Object) }
                $childPrefix = $f[3]
                $lastIdx = $keys.Count - 1
                for ($i = $lastIdx; $i -ge 0; $i--) {  # reversed: first child pops first
                    # NB: computed before Push -- inside @(...) the comma
                    # binds tighter than '+', which would flatten the frame
                    if ($i -eq $lastIdx) {
                        $lp = $childPrefix + '└── '
                        $cp = $childPrefix + '    '
                    }
                    else {
                        $lp = $childPrefix + '├── '
                        $cp = $childPrefix + '│   '
                    }
                    $stack.Push(@([string]$keys[$i], $node[$keys[$i]], $lp, $cp, "$full\$($keys[$i])"))
                }
            }
        }

        $out
    }
}

Export-ModuleMember -Function @(
    'Show-Tree',
    'Show-TreeFromList'
)
