#Requires -Version 7
# unmount_mega.ps1

. "$PSScriptRoot\config.ps1"

$rcloneBin = (Get-Command rclone -ErrorAction SilentlyContinue)?.Source
if (-not $rcloneBin) {
    Write-Error 'rclone not found in PATH.'
    exit 1
}

Write-Host 'Sending quit signal to rclone...'
& $rcloneBin rc --rc-addr $RcAddress --rc-no-auth core/quit
if ($LASTEXITCODE -eq 0) {
    Remove-Item $PidFile -ErrorAction SilentlyContinue
} else {
    Write-Warning "RC quit failed (exit code $LASTEXITCODE). Falling back to targeted Stop-Process."
    $savedPid = if (Test-Path $PidFile) { Get-Content $PidFile | Select-Object -First 1 }
    if ($savedPid) {
        Get-Process -Id $savedPid -ErrorAction SilentlyContinue | Stop-Process -Force
        Remove-Item $PidFile -ErrorAction SilentlyContinue
    } else {
        Write-Error 'No PID file found. Cannot safely stop rclone without killing all instances.'
        exit 1
    }
}

$timeout = 10
$elapsed = 0
while ($elapsed -lt $timeout) {
    Start-Sleep -Seconds 1
    $elapsed++
    $driveUp = [bool]([System.IO.DriveInfo]::GetDrives() | Where-Object { $_.Name -eq "${DriveLetter}\" })
    if (-not $driveUp) { break }
}

$driveUp = [bool]([System.IO.DriveInfo]::GetDrives() | Where-Object { $_.Name -eq "${DriveLetter}\" })
if (-not $driveUp) {
    Write-Host "Drive $DriveLetter unmounted successfully."
} else {
    Write-Warning "$DriveLetter is still present. A file may still be open."
}
