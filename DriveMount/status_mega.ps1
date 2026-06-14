#Requires -Version 7
# status_mega.ps1

. "$PSScriptRoot\config.ps1"

$driveUp = [bool]([System.IO.DriveInfo]::GetDrives() | Where-Object { $_.Name -eq "${DriveLetter}\" })
Write-Host "Drive ${DriveLetter}:  $(if ($driveUp) { 'mounted' } else { 'NOT mounted' })"

if (Test-Path $PidFile) {
    $savedPid = Get-Content $PidFile | Select-Object -First 1
    if ($savedPid) {
        $proc = Get-Process -Id $savedPid -ErrorAction SilentlyContinue
        Write-Host "rclone process: $(if ($proc) { "running (PID $savedPid)" } else { "NOT found (stale PID file)" })"
    } else {
        Write-Host 'rclone process: PID file is empty'
    }
} else {
    Write-Host 'rclone process: no PID file found'
}
