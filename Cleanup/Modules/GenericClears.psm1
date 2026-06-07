Import-Module "$PSScriptRoot\Write.psm1" -Force

function Clear-DirectoryContents
{
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [string]$Filter = "",
        [scriptblock]$Where = $null,
        [switch]$Optional
    )

    if (-not (Test-Path -LiteralPath $Path))
    {
        if (-not $Optional) { Write-Warning "$Path does not exist!" }
        return
    }

    $item = Get-Item -LiteralPath $Path

    if (-not $item.PSIsContainer)
    {
        Write-Error "$Path is not a directory!"
        return
    }

    $hasFilter = -not [string]::IsNullOrWhiteSpace($Filter)
    $FilterSuffix = if ($hasFilter) { " [$Filter]" } else { "" }
    Write-Text "--- Folder: $Path$FilterSuffix"

    $Items =
        if ($hasFilter)
        {
            Get-ChildItem -LiteralPath $Path -Filter $Filter -File -Recurse -Force -ErrorAction SilentlyContinue
        }
        else
        {
            Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue
        }

    if ($null -ne $Where)
    {
        $Items = $Items | Where-Object $Where
    }

    $Items |
    ForEach-Object {
        if ($PSCmdlet.ShouldProcess($_.FullName, "Remove"))
        {
            try
            {
                Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction Stop
            }
            catch
            {
                Write-Warning "[Skipped] $($_.Exception.Message)"
            }
        }
    }
}

function Clear-AllDirectoryContents
{
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [switch]$Optional
    )

    Clear-DirectoryContents -Path $Path -Optional:$Optional -WhatIf:$WhatIfPreference
}

function Remove-File
{
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [switch]$Optional
    )

    if (-not (Test-Path -LiteralPath $Path))
    {
        if (-not $Optional) { Write-Warning "$Path does not exist!" }
        return
    }

    $item = Get-Item -LiteralPath $Path

    if ($item.PSIsContainer)
    {
        Write-Error "$Path is not a file!"
        return
    }

    Write-Text "--- File: $Path"

    if ($PSCmdlet.ShouldProcess($Path, "Remove"))
    {
        try
        {
            Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
        }
        catch
        {
            Write-Warning "[Skipped] $($_.Exception.Message)"
        }
    }
}

function Remove-RegistryKey
{
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path))
    {
        # Key does not exist — nothing to do
        return
    }

    Write-Text "--- Registry: $Path"

    if ($PSCmdlet.ShouldProcess($Path, "Remove"))
    {
        try
        {
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
        }
        catch
        {
            Write-Warning "[Skipped] $($_.Exception.Message)"
        }
    }
}

Export-ModuleMember -Function @(
    'Clear-DirectoryContents',
    'Clear-AllDirectoryContents',
    'Remove-File',
    'Remove-RegistryKey'
)
