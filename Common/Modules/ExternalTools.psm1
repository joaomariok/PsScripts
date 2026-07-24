# =============================================================================================
# ExternalTools
#
# Home for integrations with optional external CLI tools that accelerate Common's functions when
# installed, always with a pure-PowerShell fallback. Currently just the Everything CLI ('es.exe',
# https://www.voidtools.com/); if another external tool is wired in later, it belongs here too.
#
# Get-FilesViaEverything and Get-EnumeratedFiles are exported so sibling modules within Common
# can Import-Module this file and call them directly, but neither is part of Common's public
# surface -- they aren't listed in Common.psd1's FunctionsToExport, so consumers of the Common
# module as a whole never see them.
# =============================================================================================

Import-Module "$PSScriptRoot\Guards.psm1" -Force

# ---- enumerate files under -Root using the Everything CLI ('es.exe'), returning objects shaped
# like Get-ChildItem's FileInfo (FullName/Length/LastWriteTime) so callers don't care which
# enumeration path was used.
function Get-FilesViaEverything {
    param([Parameter(Mandatory)][string]$Root)

    $raw = & es.exe -path $Root file: -csv -no-header -full-path-and-name -size -date-modified -date-format 1
    if ($LASTEXITCODE -ne 0) {
        throw "es.exe exited with code $LASTEXITCODE"
    }

    $raw | ConvertFrom-Csv -Header FullName, Length, LastWriteTime | ForEach-Object {
        [PSCustomObject]@{
            FullName      = $_.FullName
            Length        = [int64]$_.Length
            LastWriteTime = [datetime]$_.LastWriteTime
        }
    }
}

# ---- enumerates files under -Root, accelerated via the Everything CLI ('es.exe') when
# installed and running -- it queries a live filesystem index, so even huge trees return
# near-instantly versus a recursive disk walk. Falls back to Get-ChildItem when -UseNative is
# set, 'es' isn't installed, or the query fails for any reason (e.g. the Everything service
# isn't running). Get-ChildItem enumeration errors (permission denied, long paths, ...) are
# collected and reported as a warning rather than thrown, regardless of which path is used.
function Get-EnumeratedFiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [switch]$UseNative
    )

    $everythingAvailable = $false
    if ($UseNative) {
        Write-Verbose "External tools skipped via -UseNative - using Get-ChildItem for enumeration."
    }
    else {
        try {
            Test-ExternalCommand -CommandName 'es'
            $everythingAvailable = $true
        }
        catch {
            Write-Verbose "Everything CLI ('es') not found - using Get-ChildItem for enumeration."
        }
    }

    $allFiles = $null
    if ($everythingAvailable) {
        try {
            $allFiles = @(Get-FilesViaEverything -Root $Root)
            Write-Verbose "Enumerated via Everything CLI ('es')."
        }
        catch {
            Write-Warning "Everything CLI query failed ($($_.Exception.Message)); falling back to Get-ChildItem."
        }
    }

    if ($null -eq $allFiles) {
        # -Force includes hidden and system files. Errors (access denied, path too long, ...)
        # are collected and reported as a warning, not thrown.
        $enumErrors = @()
        $allFiles = @(
            Get-ChildItem -LiteralPath $Root -Recurse -File -Force `
                          -ErrorAction SilentlyContinue -ErrorVariable enumErrors
        )
        if ($enumErrors.Count -gt 0) {
            Write-Warning "$($enumErrors.Count) path(s) could not be read (permissions, long paths, etc.). Re-run with -Verbose to list them."
            foreach ($e in $enumErrors) { Write-Verbose "  Skipped: $($e.TargetObject)" }
        }
    }

    $allFiles
}

Export-ModuleMember -Function @(
    'Get-FilesViaEverything',
    'Get-EnumeratedFiles'
)
