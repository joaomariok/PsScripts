Import-Module "$PSScriptRoot\Modules\Write.psm1" -Force
Import-Module "$PSScriptRoot\Modules\Helpers.psm1" -Force
Import-Module "$PSScriptRoot\Modules\GenericClears.psm1" -Force
Import-Module "$PSScriptRoot\Modules\SpecificClears.psm1" -Force

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
