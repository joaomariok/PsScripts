function Write-Text
{
    [CmdletBinding()]
    param(
        [string]$Message,
        [ConsoleColor]$ForegroundColor = [ConsoleColor]::Gray,
        [ConsoleColor]$BackgroundColor = [ConsoleColor]::Black
    )

    Write-Host $Message -ForegroundColor $ForegroundColor -BackgroundColor $BackgroundColor
}

function Write-Title
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Message,
        [ConsoleColor]$ForegroundColor = [ConsoleColor]::Cyan,
        [ConsoleColor]$BackgroundColor = [ConsoleColor]::Black,
        [switch]$NoNewlineBefore
    )

    if (-not $NoNewlineBefore) { Write-Host "" }
    Write-Host $Message -ForegroundColor $ForegroundColor -BackgroundColor $BackgroundColor
}

function Write-MainTitle
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Message,
        [ConsoleColor]$ForegroundColor = [ConsoleColor]::Magenta,
        [ConsoleColor]$BackgroundColor = [ConsoleColor]::Black,
        [switch]$NoNewlineBefore,
        [switch]$NoNewlineAfter
    )

    $Separator = "=" * $Message.Length
    
    if (-not $NoNewlineBefore) { Write-Host "" }
    Write-Text $Separator -ForegroundColor $ForegroundColor -BackgroundColor $BackgroundColor
    Write-Text $Message   -ForegroundColor $ForegroundColor -BackgroundColor $BackgroundColor
    Write-Text $Separator -ForegroundColor $ForegroundColor -BackgroundColor $BackgroundColor
    if (-not $NoNewlineAfter) { Write-Host "" }
}

function Test-Elevated
{
    $CurrentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $Principal = [Security.Principal.WindowsPrincipal]::new($CurrentIdentity)
    $IsAdmin = $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

    if (-not $IsAdmin)
    {
        Write-Warning "Administrator privileges are required. Please run as Administrator."
        Write-Text ""
    }

    return $IsAdmin
}

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
        Clear-AllDirectoryContents -Path $TempPath -Optional -WhatIf:$WhatIfPreference
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

# Private — call via Clear-System only
function Clear-All
{
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [switch]$CleanDism
    )
    
    # === Titles ===
        
    Write-MainTitle "Cleanup started: $(Get-Date)"

    $WhatIfPrefix = if ($WhatIfPreference) { " ( WHATIF MODE ENABLED )" } else { "" }
    Write-Title "=== STARTING CLEANUP$WhatIfPrefix ==="

    # === Temp files ===

    # User Temp
    Write-Title "Cleaning User Temp..."
    Clear-AllDirectoryContents -Path $env:TEMP -WhatIf:$WhatIfPreference

    # Windows Temp
    Write-Title "Cleaning Windows Temp..."
    Clear-AllDirectoryContents -Path "C:\Windows\Temp" -WhatIf:$WhatIfPreference

    # === Trash files ===

    # Recycle Bin
    Write-Title "Emptying Recycle Bin..."
    if ($PSCmdlet.ShouldProcess("Recycle Bin", "Empty"))
    {
        try
        {
            Clear-RecycleBin -Force -ErrorAction Stop
        }
        catch
        {
            if ($_.Exception.Message -match "No recycling bin" -or
                $_.FullyQualifiedErrorId -match "ItemNotFoundException")
            {
                Write-Text "Recycle Bin is already empty."
            }
            else
            {
                Write-Warning "$($_.Exception.Message)"
            }
        }
    }

    # === LOCALAPPDATA ===

    # Thumbnail Cache
    Write-Title "Cleaning Thumbnail Cache..."
    Clear-DirectoryContents -Path (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Explorer') -Filter "thumbcache*" -WhatIf:$WhatIfPreference

    # Icon Cache
    Write-Title "Cleaning Icon Cache..."
    Clear-DirectoryContents -Path (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Explorer') -Filter "iconcache*" -WhatIf:$WhatIfPreference

    # Windows Error Reporting
    Write-Title "Cleaning Error Reports..."
    Clear-AllDirectoryContents -Path (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\WER') -Optional -WhatIf:$WhatIfPreference

    # Shaders Cache
    Write-Title "Cleaning DirectX and NVIDIA Shader Cache..."
    $CachePaths = @(
        (Join-Path $env:LOCALAPPDATA 'D3DSCache'),
        (Join-Path $env:LOCALAPPDATA 'NVIDIA\DXCache'),
        (Join-Path $env:LOCALAPPDATA 'NVIDIA\GLCache'),
        (Join-Path $env:LOCALAPPDATA 'NVIDIA Corporation\NV_Cache'),
        (Join-Path $env:LOCALAPPDATA 'AMD\DxCache')
    )
    foreach ($Cache in $CachePaths)
    {
        Clear-AllDirectoryContents -Path $Cache -Optional -WhatIf:$WhatIfPreference
    }

    # === APPDATA ===

    # Explorer Recent Files
    Write-Title "Cleaning Recent Files..."
    Clear-AllDirectoryContents -Path (Join-Path $env:APPDATA 'Microsoft\Windows\Recent') -WhatIf:$WhatIfPreference

    # === PROGRAMDATA ===

    # Delivery Optimization Cache
    Write-Title "Cleaning Delivery Optimization Cache..."
    Clear-AllDirectoryContents -Path (Join-Path $env:PROGRAMDATA 'Microsoft\Windows\DeliveryOptimization\Cache') -Optional -WhatIf:$WhatIfPreference

    # Defender Scan History
    Write-Title "Cleaning Defender Scan History..."
    Clear-AllDirectoryContents -Path (Join-Path $env:PROGRAMDATA 'Microsoft\Windows Defender\Scans\History') -Optional -WhatIf:$WhatIfPreference
    
    # === C:\WINDOWS ===

    # Crash Dumps
    Write-Title "Cleaning Crash Dumps..."
    Clear-AllDirectoryContents -Path "C:\Windows\Minidump" -Optional -WhatIf:$WhatIfPreference
    Clear-AllDirectoryContents -Path "C:\Windows\LiveKernelReports" -Optional -WhatIf:$WhatIfPreference
    Remove-File -Path "C:\Windows\MEMORY.DMP" -Optional -WhatIf:$WhatIfPreference

    # Windows Update Cache
    Write-Title "Cleaning Windows Update Cache..."
    Clear-DirectoryServiceDependent `
        -Path "C:\Windows\SoftwareDistribution\Download" `
        -ServiceName "wuauserv" `
        -WhatIf:$WhatIfPreference

    # === PRIVACY ===
    
    Clear-ClipboardContents -WhatIf:$WhatIfPreference

    # Windows Search History
    Write-Title "Cleaning Windows Search History..."
    Remove-RegistryKey `
        -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\WordWheelQuery" `
        -WhatIf:$WhatIfPreference
        
    # Address Bar History
    Write-Title "Cleaning Address Bar History..."
    Remove-RegistryKey `
        -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\TypedPaths" `
        -WhatIf:$WhatIfPreference

    # Open/Save Dialog History
    Write-Title "Cleaning Open/Save Dialog History..."
    Remove-RegistryKey `
        -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\ComDlg32\OpenSavePidlMRU" `
        -WhatIf:$WhatIfPreference
    Remove-RegistryKey `
        -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\ComDlg32\LastVisitedPidlMRU" `
        -WhatIf:$WhatIfPreference
    
    # === LOGS ===

    # Old logs (>30 days)
    Write-Title "Cleaning old Log Files..."
    Clear-OldLogFiles -Path "C:\Windows\Logs" -DaysOld 30 -WhatIf:$WhatIfPreference
    Clear-OldLogFiles -Path (Join-Path $env:PROGRAMDATA 'Microsoft\Windows\WER') -DaysOld 30 -Optional -WhatIf:$WhatIfPreference

    # === APPS ===

    # Chromium based browsers cache
    Clear-BrowsersCache -WhatIf:$WhatIfPreference
        
    # Teams cache
    Clear-TeamsCache -WhatIf:$WhatIfPreference
    
    # UWP App Temp
    Clear-UWPAppTemp -WhatIf:$WhatIfPreference

    # === OTHER ===
    
    # DNS cache
    Write-Title "Cleaning DNS Cache..."
    Clear-DnsClientCache -WhatIf:$WhatIfPreference

    # Windows Component Store Cleanup
    if ($CleanDism)
    {
        if ($PSCmdlet.ShouldProcess("WinSxS component store", "Clean"))
        {
            Write-Title "Running Windows Update Cleanup..."
            DISM.exe /Online /Cleanup-Image /StartComponentCleanup
        }
    }

    Write-Title "=== CLEANUP COMPLETE ==="
}

function Clear-System
{
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [switch]$CleanDism
    )

    if (-not (Test-Elevated))
    {
        throw "Administrator privileges are required."
    }
    
    $ErrorActionPreference = "Continue"

    $TranscriptStarted = $false
    $LogFolder = "C:\Windows\Logs"
    try
    {
        $LogFileName = "Cleanup-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date)
        Start-Transcript -Path (Join-Path $LogFolder $LogFileName) -ErrorAction Stop
        $TranscriptStarted = $true
    }
    catch
    {
        Write-Warning "Could not start transcript logging."
    }

    try
    {
        Clear-All -CleanDism:$CleanDism -WhatIf:$WhatIfPreference
    }
    catch
    {
        Write-Error $($_.Exception.Message)
        throw
    }
    finally
    {
        if ($TranscriptStarted)
        {
            try { Stop-Transcript } catch {}
            
            # Keep only the 5 most recent logs, delete the rest
            Get-ChildItem $LogFolder -Filter "Cleanup-*.log" -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending |
                Select-Object -Skip 5 |
                ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
        }
    }
}

Export-ModuleMember -Function @(
    'Clear-System'
)
