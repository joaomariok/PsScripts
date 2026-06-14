#Requires -Version 7
# mount_mega.ps1

. "$PSScriptRoot\config.ps1"

$rcloneBin = (Get-Command rclone -ErrorAction SilentlyContinue)?.Source
if (-not $rcloneBin) {
    Write-Error 'rclone not found in PATH. Download it from https://rclone.org/downloads/'
    exit 1
}

$winFspService = Get-Service 'WinFsp*' -ErrorAction SilentlyContinue
if (-not $winFspService) {
    Write-Error 'WinFsp is not installed. Download it from https://winfsp.dev'
    exit 1
}
if (-not ($winFspService | Where-Object Status -eq 'Running')) {
    Write-Error 'WinFsp service is not running.'
    exit 1
}

$driveUp = [bool]([System.IO.DriveInfo]::GetDrives() | Where-Object { $_.Name -eq "${DriveLetter}\" })
if ($driveUp) {
    Write-Error "$DriveLetter is already mounted."
    exit 1
}

$rcloneArgs = @(
    'mount', $RemoteName, $DriveLetter,
    '--vfs-cache-mode', 'minimal',
    '--network-mode',
    '--rc',
    '--rc-no-auth',
    '--rc-addr', $RcAddress,
    '--log-file', $LogFile,
    '--log-level', $LogLevel
)

$proc = Start-Process -FilePath $rcloneBin `
                      -ArgumentList $rcloneArgs `
                      -WindowStyle Hidden `
                      -PassThru

Write-Host 'Waiting for drive to appear...'
$timeout = 15
$elapsed = 0
while ($elapsed -lt $timeout) {
    Start-Sleep -Seconds 1
    $elapsed++
    $driveUp = [bool]([System.IO.DriveInfo]::GetDrives() | Where-Object { $_.Name -eq "${DriveLetter}\" })
    if ($driveUp) { break }
}

if ($driveUp) {
    $proc.Id | Set-Content $PidFile
    Write-Host "Drive $DriveLetter is ready. (PID $($proc.Id))"
} else {
    Write-Error "Drive did not appear after $timeout seconds. Check: $LogFile"
    Write-Host "Stopping rclone process (PID $($proc.Id))..."
    $proc | Stop-Process -Force -ErrorAction SilentlyContinue
    exit 1
}
