Import-Module "$PSScriptRoot\Write.psm1" -Force
Import-Module "$PSScriptRoot\GenericClears.psm1" -Force

function Clear-DirectoryServiceDependent
{
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [Parameter(Mandatory)]
        [string]$ServiceName
    )

    if ($PSCmdlet.ShouldProcess($Path, "Stop $ServiceName, clean, restart $ServiceName"))
    {
        $WasRunning = (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue).Status -eq 'Running'
        Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
        try
        {
            Clear-AllDirectoryContents -Path $Path -WhatIf:$WhatIfPreference
        }
        finally
        {
            if ($WasRunning)
            {
                Start-Service -Name $ServiceName -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
            }
        }
    }
}

function Clear-OldLogFiles
{
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [int]$DaysOld = 30,
        [switch]$Optional
    )

    $CutoffDate = (Get-Date).AddDays(-$DaysOld)

    Clear-DirectoryContents `
        -Path $Path `
        -Filter "*.log" `
        -Where { $_.LastWriteTime -lt $CutoffDate } `
        -Optional:$Optional `
        -WhatIf:$WhatIfPreference
}

function Clear-BrowserCache
{
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Browser
    )

    $BrowserName  = $Browser.Name
    $ProcessName  = $Browser.ProcessName
    $UserDataPath = [Environment]::ExpandEnvironmentVariables($Browser.UserDataPath)

    if (-not (Test-Path -LiteralPath $UserDataPath))
    {
        # Browser not installed
        return
    }

    Write-Title "Cleaning $BrowserName Cache..."

    if (Get-Process -Name $ProcessName -ErrorAction SilentlyContinue)
    {
        Write-Warning "$BrowserName is running. Skipping $BrowserName cache cleanup."
        return
    }

    Get-ChildItem -LiteralPath $UserDataPath -Directory -ErrorAction SilentlyContinue |
    Where-Object {
        Test-Path -LiteralPath (Join-Path $_.FullName 'Preferences')
    } |
    ForEach-Object {
        $ProfilePath = $_.FullName
        Clear-AllDirectoryContents -Path (Join-Path $ProfilePath 'Cache') -Optional -WhatIf:$WhatIfPreference
        Clear-AllDirectoryContents -Path (Join-Path $ProfilePath 'Code Cache') -Optional -WhatIf:$WhatIfPreference
        Clear-AllDirectoryContents -Path (Join-Path $ProfilePath 'GPUCache') -Optional -WhatIf:$WhatIfPreference
    }
}

function Clear-BrowsersCache
{
    [CmdletBinding(SupportsShouldProcess)]
    param()

    $Browsers = @(
        @{
            Name         = "Chrome"
            ProcessName  = "chrome"
            UserDataPath = "%LOCALAPPDATA%\Google\Chrome\User Data"
        },
        @{
            Name         = "Edge"
            ProcessName  = "msedge"
            UserDataPath = "%LOCALAPPDATA%\Microsoft\Edge\User Data"
        },
        @{
            Name         = "Brave"
            ProcessName  = "brave"
            UserDataPath = "%LOCALAPPDATA%\BraveSoftware\Brave-Browser\User Data"
        },
        @{
            Name         = "Vivaldi"
            ProcessName  = "vivaldi"
            UserDataPath = "%LOCALAPPDATA%\Vivaldi\User Data"
        },
        @{
            Name         = "Opera"
            ProcessName  = "opera"
            UserDataPath = "%APPDATA%\Opera Software\Opera Stable"
        }
    )

    foreach ($Browser in $Browsers)
    {
        Clear-BrowserCache -Browser $Browser -WhatIf:$WhatIfPreference
    }
}

# Private — call via Clear-TeamsCache only
function Clear-TeamsCacheInstance
{
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$DisplayName,
        [Parameter(Mandatory)]
        [string]$ProcessName,
        [Parameter(Mandatory)]
        [string]$BasePath,
        [string[]]$CachePaths
    )

    if (-not (Test-Path -LiteralPath $BasePath))
    {
        # Teams not installed
        return
    }

    Write-Title "Cleaning $DisplayName Cache..."

    if (Get-Process -Name $ProcessName -ErrorAction SilentlyContinue)
    {
        Write-Warning "$DisplayName is running. Skipping $DisplayName cache cleanup."
        return
    }

    foreach ($Cache in $CachePaths)
    {
        $CacheFull = Join-Path $BasePath $Cache
        Clear-AllDirectoryContents -Path $CacheFull -Optional -WhatIf:$WhatIfPreference
    }
}

function Clear-TeamsCache
{
    [CmdletBinding(SupportsShouldProcess)]
    param()

    $CachePaths = @('Cache', 'blob_storage', 'databases', 'GPUCache', 'IndexedDB', 'tmp')

    Clear-TeamsCacheInstance `
        -DisplayName  "Microsoft Teams" `
        -ProcessName  "Teams" `
        -BasePath     (Join-Path $env:APPDATA 'Microsoft\Teams') `
        -CachePaths   $CachePaths `
        -WhatIf:$WhatIfPreference

    Clear-TeamsCacheInstance `
        -DisplayName  "Microsoft Teams (New)" `
        -ProcessName  "ms-teams" `
        -BasePath     (Join-Path $env:LOCALAPPDATA 'Microsoft\MSTeams') `
        -CachePaths   $CachePaths `
        -WhatIf:$WhatIfPreference
}

function Clear-UWPAppTemp
{
    [CmdletBinding(SupportsShouldProcess)]
    param()

    Write-Title "Cleaning UWP App Temp Files..."

    $PackagesPath = Join-Path $env:LOCALAPPDATA 'Packages'

    if (-not (Test-Path -LiteralPath $PackagesPath))
    {
        Write-Warning "UWP Packages folder not found at $PackagesPath"
        return
    }

    Get-ChildItem -LiteralPath $PackagesPath -Directory -ErrorAction SilentlyContinue |
    ForEach-Object {
        $TempPath = Join-Path $_.FullName 'AC\Temp'
        if ((Test-Path -LiteralPath $TempPath) -and
            (Get-ChildItem -LiteralPath $TempPath -Force -ErrorAction SilentlyContinue | Select-Object -First 1))
        {
            Clear-AllDirectoryContents -Path $TempPath -Optional -WhatIf:$WhatIfPreference
        }
    }
}

function Clear-ClipboardContents
{
    [CmdletBinding(SupportsShouldProcess)]
    param()

    Write-Title "Cleaning Clipboard..."

    if ($PSCmdlet.ShouldProcess("Clipboard", "Clear active content"))
    {
        Set-Clipboard -Value $null
    }

    # Clear persisted clipboard history folder
    $ClipboardPath = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Clipboard\HistoryData'
    Clear-AllDirectoryContents -Path $ClipboardPath -Optional -WhatIf:$WhatIfPreference
}

Export-ModuleMember -Function @(
    'Clear-DirectoryServiceDependent',
    'Clear-OldLogFiles',
    'Clear-BrowserCache',
    'Clear-BrowsersCache',
    'Clear-TeamsCache',
    'Clear-UWPAppTemp',
    'Clear-ClipboardContents'
)
